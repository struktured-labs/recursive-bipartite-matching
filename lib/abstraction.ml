(** Per-street card abstraction for Limit Hold'em.

    Implements equity-based and (placeholder) RBM-based hand clustering
    for reducing the information set space of Texas Hold'em. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type street = Preflop | Flop | Turn | River [@@deriving sexp, compare]

type bucket_map = (string, int) Hashtbl.Poly.t

type abstraction_partial = {
  street : street;
  n_buckets : int;
  assignments : (int, int) Hashtbl.Poly.t;
  centroids : float array;
}

type abstraction = {
  preflop_buckets : int;
  flop_buckets : int;
  turn_buckets : int;
  river_buckets : int;
  bucket_map : bucket_map;
}

type holdem_config = {
  deck : Card.t list;
  ante : int;
  small_bet : int;
  big_bet : int;
  max_raises : int;
} [@@deriving sexp]

let default_holdem_config =
  { deck = Card.full_deck
  ; ante = 1
  ; small_bet = 2
  ; big_bet = 4
  ; max_raises = 4
  }

(* ------------------------------------------------------------------ *)
(* EMD between histograms                                              *)
(* ------------------------------------------------------------------ *)

let emd_histograms h1 h2 =
  let n = Array.length h1 in
  let cdf_diff = ref 0.0 in
  let cdf1 = ref 0.0 in
  let cdf2 = ref 0.0 in
  for i = 0 to n - 1 do
    cdf1 := !cdf1 +. h1.(i);
    cdf2 := !cdf2 +. h2.(i);
    cdf_diff := !cdf_diff +. Float.abs (!cdf1 -. !cdf2)
  done;
  !cdf_diff /. Float.of_int n

(* ------------------------------------------------------------------ *)
(* Quantile-based bucketing                                            *)
(* ------------------------------------------------------------------ *)

(** Sort canonical hands by equity and assign to buckets by quantile. *)
let quantile_bucketing ~n_buckets (equities : float array) =
  let n = Array.length equities in
  (* Create (index, equity) pairs and sort by equity *)
  let indexed =
    Array.init n ~f:(fun i -> (i, equities.(i)))
  in
  Array.sort indexed ~compare:(fun (_, e1) (_, e2) -> Float.compare e1 e2);
  let assignments = Hashtbl.Poly.create () in
  let centroids = Array.create ~len:n_buckets 0.0 in
  let bucket_counts = Array.create ~len:n_buckets 0 in
  let bucket_sums = Array.create ~len:n_buckets 0.0 in
  Array.iteri indexed ~f:(fun rank (hand_id, equity) ->
    let bucket =
      Int.min (n_buckets - 1)
        (rank * n_buckets / n)
    in
    Hashtbl.set assignments ~key:hand_id ~data:bucket;
    bucket_sums.(bucket) <- bucket_sums.(bucket) +. equity;
    bucket_counts.(bucket) <- bucket_counts.(bucket) + 1);
  (* Compute centroids *)
  Array.iteri bucket_counts ~f:(fun i count ->
    match count > 0 with
    | true -> centroids.(i) <- bucket_sums.(i) /. Float.of_int count
    | false -> centroids.(i) <- 0.0);
  (assignments, centroids)

(* ------------------------------------------------------------------ *)
(* K-means bucketing (used for RBM placeholder)                        *)
(* ------------------------------------------------------------------ *)

let kmeans_bucketing ~n_buckets ~max_iters (equities : float array) =
  let n = Array.length equities in
  (* Initialize centroids with quantile-spaced values *)
  let centroids = Array.init n_buckets ~f:(fun i ->
    let frac = (Float.of_int i +. 0.5) /. Float.of_int n_buckets in
    frac)
  in
  let assignments = Array.create ~len:n 0 in
  for _iter = 1 to max_iters do
    (* Assignment step: each hand goes to nearest centroid *)
    Array.iteri equities ~f:(fun i eq ->
      let best_bucket = ref 0 in
      let best_dist = ref Float.infinity in
      Array.iteri centroids ~f:(fun b c ->
        let d = Float.abs (eq -. c) in
        match Float.( < ) d !best_dist with
        | true -> best_bucket := b; best_dist := d
        | false -> ());
      assignments.(i) <- !best_bucket);
    (* Update step: recompute centroids *)
    let sums = Array.create ~len:n_buckets 0.0 in
    let counts = Array.create ~len:n_buckets 0 in
    Array.iteri assignments ~f:(fun i b ->
      sums.(b) <- sums.(b) +. equities.(i);
      counts.(b) <- counts.(b) + 1);
    Array.iteri counts ~f:(fun b c ->
      match c > 0 with
      | true -> centroids.(b) <- sums.(b) /. Float.of_int c
      | false -> ())
  done;
  let result = Hashtbl.Poly.create () in
  Array.iteri assignments ~f:(fun i b ->
    Hashtbl.set result ~key:i ~data:b);
  (result, centroids)

(* ------------------------------------------------------------------ *)
(* Preflop abstraction: equity-based                                   *)
(* ------------------------------------------------------------------ *)

let abstract_preflop_equity ~n_buckets =
  let equities = Equity.preflop_equities () in
  let assignments, centroids = quantile_bucketing ~n_buckets equities in
  { street = Preflop; n_buckets; assignments; centroids }

(* ------------------------------------------------------------------ *)
(* Preflop abstraction: RBM-based (placeholder)                        *)
(* ------------------------------------------------------------------ *)

let abstract_preflop_rbm ~n_buckets ~config:_ =
  (* TODO: When limit_holdem.ml exists, build IS trees for each
     canonical hand and cluster by RBM distance.  For now, fall back
     to k-means on equity as a placeholder. *)
  let equities = Equity.preflop_equities () in
  let assignments, centroids = kmeans_bucketing ~n_buckets ~max_iters:20 equities in
  { street = Preflop; n_buckets; assignments; centroids }

(* ------------------------------------------------------------------ *)
(* Bucket lookup                                                       *)
(* ------------------------------------------------------------------ *)

let get_bucket abstraction ~hole_cards =
  let canonical = Equity.to_canonical hole_cards in
  match Hashtbl.find abstraction.assignments canonical.id with
  | Some bucket -> bucket
  | None -> 0  (* Default to bucket 0 for unknown hands *)

(* ------------------------------------------------------------------ *)
(* Multi-street abstraction builder                                    *)
(* ------------------------------------------------------------------ *)

let build_abstraction ~preflop_buckets ~flop_buckets ~turn_buckets ~river_buckets =
  let bucket_map = Hashtbl.Poly.create () in
  (* Build preflop bucket assignments *)
  let preflop = abstract_preflop_equity ~n_buckets:preflop_buckets in
  List.iter Equity.all_canonical_hands ~f:(fun hand ->
    match Hashtbl.find preflop.assignments hand.id with
    | Some bucket ->
      let key = sprintf "preflop:%s" hand.name in
      Hashtbl.set bucket_map ~key ~data:bucket
    | None -> ());
  (* Flop/turn/river abstractions would be built incrementally here
     once the full game tree and equity distribution machinery
     is wired in.  For now, we return placeholders. *)
  { preflop_buckets
  ; flop_buckets
  ; turn_buckets
  ; river_buckets
  ; bucket_map
  }
