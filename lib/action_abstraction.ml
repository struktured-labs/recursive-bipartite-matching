(** Action abstraction via RBM distance on bet-response subtrees.

    Clusters candidate bet sizes by computing pairwise RBM distances
    on their response subtrees and merging the closest pairs until
    the merge distance exceeds epsilon.  The surviving cluster centroids
    become the optimal bet sizes for a given game context.

    The error bound from Theorem 9.2 applies identically: merging two
    actions with RBM distance d introduces at most d/2 EV error.  This
    composes additively with state abstraction error:
    total per-step error ≤ (ε_state + ε_action) / 2. *)

(** A cluster of bet sizes that are strategically equivalent within epsilon. *)
type action_cluster = {
  centroid_frac : float;
  member_fracs : float list;
  representative : Nolimit_holdem.Node_label.t Tree.t;
  diameter : float;  (** max intra-cluster distance *)
}

(** Game context that determines the optimal bet size discretization.
    Different contexts may need different bet sizes. *)
type action_context = {
  street : int;           (** 0=preflop, 1=flop, 2=turn, 3=river *)
  pot_bucket : int;       (** discretized pot size *)
  stack_bucket : int;     (** discretized effective stack *)
  raise_count : int;      (** number of prior raises this round *)
}

(** Full action abstraction: maps contexts to optimal bet fractions. *)
type t = {
  table : (string, float list) Hashtbl.t;
  epsilon : float;
  candidate_fracs : float list;
} [@@warning "-69"]

(** Discretize pot size into a bucket index (log-scale). *)
let pot_to_bucket ~(big_blind : int) (pot : int) : int =
  let ratio = Float.of_int pot /. Float.of_int (Int.max 1 big_blind) in
  Float.to_int (Float.log2 (Float.max 1.0 ratio))

(** Discretize effective stack into a bucket index (log-scale). *)
let stack_to_bucket ~(big_blind : int) (stack : int) : int =
  let ratio = Float.of_int stack /. Float.of_int (Int.max 1 big_blind) in
  Float.to_int (Float.log2 (Float.max 1.0 ratio))

(** Serialize an action context to a string key for hash table lookup. *)
let context_key (ctx : action_context) : string =
  sprintf "s%d:p%d:k%d:r%d" ctx.street ctx.pot_bucket ctx.stack_bucket ctx.raise_count

(** Cluster candidate bet sizes for a given game context using RBM distance.

    Algorithm:
    1. Build response subtrees for each candidate bet size (averaged over
       sample hands)
    2. Compute pairwise RBM distances
    3. Agglomeratively merge closest pairs until distance > epsilon
    4. Return surviving clusters with centroid fractions

    [sample_hands] should include representative hands across equity range
    (e.g., one from each decile of preflop equity). *)
let cluster_bet_sizes
    ~(pot : int)
    ~(effective_stack : int)
    ~(candidate_fracs : float list)
    ~(epsilon : float)
    ~(sample_hands : (Card.t * Card.t) list)
    ~(board_visible : Card.t list)
    ?(distance_config = Distance.default_config)
    ()
  : action_cluster list =
  (* Step 1: Build averaged response subtrees for each candidate *)
  let frac_trees =
    Action_subtree.build_averaged_response_trees
      ~pot ~effective_stack ~candidate_fracs
      ~sample_hands ~board_visible ()
  in
  let n = List.length frac_trees in
  let fracs_arr = Array.of_list (List.map frac_trees ~f:fst) in
  let trees_arr = Array.of_list (List.map frac_trees ~f:snd) in

  (* Step 2: Compute pairwise RBM distance matrix *)
  let dist_matrix = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      match i < j with
      | true ->
        let (d, _depth) =
          Distance.compute_progressive ~config:distance_config
            ~threshold:epsilon trees_arr.(i) trees_arr.(j)
        in
        d
      | false -> 0.0))
  in
  (* Symmetrize *)
  for i = 0 to n - 1 do
    for j = 0 to i - 1 do
      dist_matrix.(i).(j) <- dist_matrix.(j).(i)
    done
  done;

  (* Step 3: Agglomerative clustering (single-linkage, merge closest pair) *)
  (* Each element starts as its own cluster *)
  let cluster_id = Array.init n ~f:Fun.id in  (* which cluster each element belongs to *)
  let active = Array.create ~len:n true in
  let merged_fracs = Array.init n ~f:(fun i -> [ fracs_arr.(i) ]) in
  let merged_trees = Array.init n ~f:(fun i -> trees_arr.(i)) in
  let diameters = Array.create ~len:n 0.0 in

  let continue = ref true in
  while !continue do
    (* Find closest pair of active clusters *)
    let best_i = ref (-1) in
    let best_j = ref (-1) in
    let best_d = ref Float.infinity in
    for i = 0 to n - 1 do
      match active.(i) with
      | false -> ()
      | true ->
        for j = i + 1 to n - 1 do
          match active.(j) with
          | false -> ()
          | true ->
            let ci = cluster_id.(i) in
            let cj = cluster_id.(j) in
            match ci = cj with
            | true -> ()  (* same cluster *)
            | false ->
              let d = dist_matrix.(i).(j) in
              (match Float.( < ) d !best_d with
               | true -> best_i := i; best_j := j; best_d := d
               | false -> ())
        done
    done;
    match !best_i < 0 || Float.( > ) !best_d epsilon with
    | true -> continue := false  (* no more merges below epsilon *)
    | false ->
      let ci = cluster_id.(!best_i) in
      let cj = cluster_id.(!best_j) in
      (* Merge cj into ci *)
      merged_fracs.(ci) <- merged_fracs.(ci) @ merged_fracs.(cj);
      merged_trees.(ci) <- Merge.merge ~config:Merge.default_config merged_trees.(ci) merged_trees.(cj);
      diameters.(ci) <- Float.max diameters.(ci) (Float.max diameters.(cj) !best_d);
      (* Redirect all elements of cj to ci *)
      for k = 0 to n - 1 do
        match cluster_id.(k) = cj with
        | true -> cluster_id.(k) <- ci
        | false -> ()
      done;
      active.(cj) <- false
  done;

  (* Step 4: Collect surviving clusters *)
  let seen = Hashtbl.Poly.create ~size:n () in
  let clusters = ref [] in
  for i = 0 to n - 1 do
    let ci = cluster_id.(i) in
    match Hashtbl.mem seen ci with
    | true -> ()
    | false ->
      Hashtbl.set seen ~key:ci ~data:();
      let members = merged_fracs.(ci) in
      let centroid =
        List.fold members ~init:0.0 ~f:( +. ) /. Float.of_int (List.length members)
      in
      clusters := {
        centroid_frac = centroid;
        member_fracs = List.sort members ~compare:Float.compare;
        representative = merged_trees.(ci);
        diameter = diameters.(ci);
      } :: !clusters
  done;
  List.sort !clusters ~compare:(fun a b -> Float.compare a.centroid_frac b.centroid_frac)

(** Precompute action abstraction for all relevant game contexts.

    Iterates over a grid of (street, pot_bucket, stack_bucket, raise_count)
    and clusters the candidate bet sizes for each.  Returns a lookup table
    mapping context keys to optimal bet fractions.

    [big_blind] is used for pot/stack discretization.
    [candidate_fracs] is the full set of candidate bet sizes (e.g.,
    [0.1; 0.25; 0.33; 0.5; 0.67; 0.75; 1.0; 1.25; 1.5; 2.0; 2.5; 3.0]).
    [sample_hands] are representative hands for averaging subtrees. *)
let precompute
    ~(big_blind : int)
    ~(epsilon : float)
    ~(candidate_fracs : float list)
    ~(sample_hands : (Card.t * Card.t) list)
    ~(pot_values : int list)
    ~(stack_values : int list)
    ()
  : t =
  let table = Hashtbl.create (module String) in
  let n_contexts = ref 0 in
  List.iter [ 1; 2; 3 ] ~f:(fun street ->  (* post-flop only *)
    List.iter pot_values ~f:(fun pot ->
      List.iter stack_values ~f:(fun effective_stack ->
        List.iter [ 0; 1; 2 ] ~f:(fun raise_count ->
          let ctx = {
            street;
            pot_bucket = pot_to_bucket ~big_blind pot;
            stack_bucket = stack_to_bucket ~big_blind effective_stack;
            raise_count;
          } in
          let key = context_key ctx in
          match Hashtbl.mem table key with
          | true -> ()  (* already computed for this bucket *)
          | false ->
            (* Generate a simple board for this street *)
            let board_visible = List.take Card.full_deck
              (match street with 1 -> 3 | 2 -> 4 | _ -> 5)
            in
            let clusters = cluster_bet_sizes
              ~pot ~effective_stack ~candidate_fracs ~epsilon
              ~sample_hands ~board_visible ()
            in
            let fracs = List.map clusters ~f:(fun c -> c.centroid_frac) in
            Hashtbl.set table ~key ~data:fracs;
            Int.incr n_contexts))));
  printf "[action_abstraction] Precomputed %d contexts, %d candidate → %s avg surviving\n%!"
    !n_contexts (List.length candidate_fracs)
    (let total = Hashtbl.fold table ~init:0 ~f:(fun ~key:_ ~data acc ->
       acc + List.length data) in
     sprintf "%.1f" (Float.of_int total /. Float.of_int (Int.max 1 !n_contexts)));
  { table; epsilon; candidate_fracs }

(** Look up optimal bet fractions for a given game context.
    Falls back to full candidate list if context not found. *)
let lookup (t : t) ~(big_blind : int)
    ~(street : int) ~(pot : int)
    ~(effective_stack : int) ~(raise_count : int)
  : float list =
  let ctx = {
    street;
    pot_bucket = pot_to_bucket ~big_blind pot;
    stack_bucket = stack_to_bucket ~big_blind effective_stack;
    raise_count;
  } in
  match Hashtbl.find t.table (context_key ctx) with
  | Some fracs -> fracs
  | None -> t.candidate_fracs  (* fallback *)

(** Number of unique contexts in the table. *)
let num_contexts (t : t) : int = Hashtbl.length t.table

(** Summary statistics: average number of surviving bet sizes per context. *)
let avg_actions_per_context (t : t) : float =
  let total = Hashtbl.fold t.table ~init:0 ~f:(fun ~key:_ ~data acc ->
    acc + List.length data) in
  Float.of_int total /. Float.of_int (Int.max 1 (Hashtbl.length t.table))
