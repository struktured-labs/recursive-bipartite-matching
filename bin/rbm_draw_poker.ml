(* Option (b), VIABLE GAME: simplified DRAW POKER.

   The strategic act is a type-dependent DRAW decision (pat vs draw). A hand's
   value has TWO independent axes:
     - current strength  (its pat showdown rank), and
     - draw potential    (the distribution it draws to).
   A scalar equity statistic can only see ONE axis:
     - "naive" equity   = current-strength win/tie/lose vs the field (sees base,
                          blind to draw potential), and
     - "potential-aware"= draw-outcome win/tie/lose distribution (sees the draw,
                          blind to the pat value of standing).
   Each single statistic is forced to MERGE types that differ on the axis it
   cannot see — and merged types are forced to share a draw policy even when they
   want OPPOSITE decisions (a made hand should stand, a drawing hand should draw),
   which a full-information best-responder exploits.

   RBM clusters over the type's GAME SUBTREE, which contains BOTH the pat branch
   and the draw branch, so it captures the joint (strength x potential) structure
   automatically — no hand-crafted 2-D feature. We race RBM vs both single-axis
   baselines on TRUE full-game exploitability across cluster counts k.

   Usage: rbm-draw-poker [cfr_iters] *)

open Rbm

(* ---------- type family: 3 strengths x 2 draw kinds = 6 hands ---------- *)
let base = [| 2; 5; 8; 2; 5; 8 |]
(* improving draws (types 0..2) draw to a strong spread; bricking draws (3..5)
   draw to a weak spread. equal-weight 2-point distributions. *)
let draw_outcomes t = if t < 3 then [ 6; 9 ] else [ 1; 3 ]
let type_names = [| "Lo+"; "Mid+"; "Hi+"; "Lo-"; "Mid-"; "Hi-" |]
let n_types = Array.length base
let ante = 1

let sd a b = if a > b then Float.of_int ante else if a < b then Float.of_int (-ante) else 0.0

type gnode =
  | Term of float
  | Chance of (float * gnode) list
  | Dec of { player : int; tag : string; actions : (string * gnode) list }

(* showdown after both draw decisions are fixed by realized strengths *)
let build_game ~t0 ~t1 =
  let d0 = draw_outcomes t0 and d1 = draw_outcomes t1 in
  let w = 1.0 /. Float.of_int (List.length d0 * List.length d1) in
  let branches =
    List.concat_map d0 ~f:(fun r0 ->
      List.map d1 ~f:(fun r1 ->
        let p1_after s0 =
          Dec { player = 1; tag = "draw1"; actions = [
            ("pat",  Term (sd s0 base.(t1)));
            ("draw", Term (sd s0 r1));
          ]}
        in
        let node =
          Dec { player = 0; tag = "draw0"; actions = [
            ("pat",  p1_after base.(t0));
            ("draw", p1_after r0);
          ]}
        in
        (w, node)))
  in
  Chance branches

let all_deals =
  List.concat_map (List.init n_types ~f:Fn.id) ~f:(fun t0 ->
    List.init n_types ~f:(fun t1 -> (t0, t1)))
let deal_games = List.map all_deals ~f:(fun (t0, t1) -> (t0, t1, build_game ~t0 ~t1))

(* ----------------------------- CFR core ----------------------------- *)
type cstate = {
  regret : (string, float array) Hashtbl.t;
  strat_sum : (string, float array) Hashtbl.t;
}
let mk_state () =
  { regret = Hashtbl.create (module String); strat_sum = Hashtbl.create (module String) }
let get_or_create tbl key m =
  match Hashtbl.find tbl key with
  | Some a -> a
  | None -> let a = Array.create ~len:m 0.0 in Hashtbl.set tbl ~key ~data:a; a
let strategy_from_regret st key m =
  let r = get_or_create st.regret key m in
  let pos = Array.map r ~f:(fun x -> Float.max 0.0 x) in
  let s = Array.fold pos ~init:0.0 ~f:( +. ) in
  if Float.( > ) s 0.0 then Array.map pos ~f:(fun x -> x /. s)
  else Array.create ~len:m (1.0 /. Float.of_int m)
let accumulate st key strat reach =
  let m = Array.length strat in
  let acc = get_or_create st.strat_sum key m in
  Array.iteri strat ~f:(fun i p -> acc.(i) <- acc.(i) +. reach *. p)

let rec cfr node ~t0 ~t1 ~p0r ~p1r ~trav ~st ~keyfn =
  match node with
  | Term v -> (match trav with 0 -> v | _ -> -.v)
  | Chance ch ->
    List.fold ch ~init:0.0 ~f:(fun acc (w, c) ->
      acc +. w *. cfr c ~t0 ~t1 ~p0r:(p0r *. w) ~p1r:(p1r *. w) ~trav ~st ~keyfn)
  | Dec { player; tag; actions } ->
    let typ = if player = 0 then t0 else t1 in
    let key = keyfn player typ tag in
    let m = List.length actions in
    let strat = strategy_from_regret st.(player) key m in
    let myr = if player = 0 then p0r else p1r in
    accumulate st.(player) key strat myr;
    let arr = Array.of_list actions in
    let avs = Array.init m ~f:(fun i ->
      let (_, ch) = arr.(i) in
      let (np0, np1) =
        if player = 0 then (p0r *. strat.(i), p1r) else (p0r, p1r *. strat.(i)) in
      cfr ch ~t0 ~t1 ~p0r:np0 ~p1r:np1 ~trav ~st ~keyfn) in
    let nodev = Array.foldi avs ~init:0.0 ~f:(fun i acc v -> acc +. strat.(i) *. v) in
    (if player = trav then begin
       let oppr = if player = 0 then p1r else p0r in
       let r = get_or_create st.(player).regret key m in
       Array.iteri avs ~f:(fun i v -> r.(i) <- Float.max 0.0 (r.(i) +. oppr *. (v -. nodev)))
     end);
    nodev

let average_strategy st =
  let out = Hashtbl.create (module String) in
  Hashtbl.iteri st.strat_sum ~f:(fun ~key ~data ->
    let s = Array.fold data ~init:0.0 ~f:( +. ) in
    let m = Array.length data in
    let avg = if Float.( > ) s 0.0 then Array.map data ~f:(fun x -> x /. s)
              else Array.create ~len:m (1.0 /. Float.of_int m) in
    Hashtbl.set out ~key ~data:avg);
  out

let train ~keyfn ~iters =
  let st = [| mk_state (); mk_state () |] in
  for _ = 1 to iters do
    List.iter deal_games ~f:(fun (t0, t1, g) ->
      ignore (cfr g ~t0 ~t1 ~p0r:1.0 ~p1r:1.0 ~trav:0 ~st ~keyfn : float);
      ignore (cfr g ~t0 ~t1 ~p0r:1.0 ~p1r:1.0 ~trav:1 ~st ~keyfn : float))
  done;
  (average_strategy st.(0), average_strategy st.(1))

(* ----------------------- evaluation / exploitability ----------------------- *)
let lookup strat key m =
  match Hashtbl.find strat key with
  | Some s -> s | None -> Array.create ~len:m (1.0 /. Float.of_int m)

let rec eval node ~t0 ~t1 ~s0 ~s1 ~k0 ~k1 =
  match node with
  | Term v -> v
  | Chance ch -> List.fold ch ~init:0.0 ~f:(fun acc (w, c) -> acc +. w *. eval c ~t0 ~t1 ~s0 ~s1 ~k0 ~k1)
  | Dec { player; tag; actions } ->
    let typ = if player = 0 then t0 else t1 in
    let m = List.length actions in
    let (strat, keyf) = if player = 0 then (s0, k0) else (s1, k1) in
    let s = lookup strat (keyf player typ tag) m in
    let arr = Array.of_list actions in
    Array.foldi (Array.create ~len:m 0.0) ~init:0.0 ~f:(fun i acc _ ->
      let (_, c) = arr.(i) in acc +. s.(i) *. eval c ~t0 ~t1 ~s0 ~s1 ~k0 ~k1)

let br_value ~br ~opp_strat ~key_self ~key_opp =
  let n = Float.of_int n_types in
  let total =
    List.fold (List.init n_types ~f:Fn.id) ~init:0.0 ~f:(fun acc my_t ->
      let action_ev = Hashtbl.create (module String) in
      let rec walk node ~t0 ~t1 =
        match node with
        | Term v -> (match br with 0 -> v | _ -> -.v)
        | Chance ch -> List.fold ch ~init:0.0 ~f:(fun a (w, c) -> a +. w *. walk c ~t0 ~t1)
        | Dec { player; tag; actions } ->
          let typ = if player = 0 then t0 else t1 in
          let arr = Array.of_list actions in
          let m = List.length actions in
          (if player = br then begin
             let vals = Array.init m ~f:(fun i -> let (_, c) = arr.(i) in walk c ~t0 ~t1) in
             let key = key_self player typ tag in
             let a = get_or_create action_ev key m in
             Array.iteri vals ~f:(fun i v -> a.(i) <- a.(i) +. v);
             Array.fold vals ~init:Float.neg_infinity ~f:Float.max
           end else begin
             let s = lookup opp_strat (key_opp player typ tag) m in
             Array.foldi (Array.create ~len:m 0.0) ~init:0.0 ~f:(fun i a _ ->
               let (_, c) = arr.(i) in a +. s.(i) *. walk c ~t0 ~t1)
           end)
      in
      List.iter (List.init n_types ~f:Fn.id) ~f:(fun opp_t ->
        let (t0, t1) = if br = 0 then (my_t, opp_t) else (opp_t, my_t) in
        ignore (walk (build_game ~t0 ~t1) ~t0 ~t1 : float));
      let br_strat = Hashtbl.create (module String) in
      Hashtbl.iteri action_ev ~f:(fun ~key ~data ->
        let bi = ref 0 in
        Array.iteri data ~f:(fun i v -> if Float.( > ) v data.(!bi) then bi := i);
        let s = Array.create ~len:(Array.length data) 0.0 in
        s.(!bi) <- 1.0;
        Hashtbl.set br_strat ~key ~data:s);
      let ev =
        List.fold (List.init n_types ~f:Fn.id) ~init:0.0 ~f:(fun a opp_t ->
          let (t0, t1) = if br = 0 then (my_t, opp_t) else (opp_t, my_t) in
          let (s0, s1, k0, k1) =
            if br = 0 then (br_strat, opp_strat, key_self, key_opp)
            else (opp_strat, br_strat, key_opp, key_self) in
          let v = eval (build_game ~t0 ~t1) ~t0 ~t1 ~s0 ~s1 ~k0 ~k1 in
          a +. (match br with 0 -> v | _ -> -.v)) /. n in
      acc +. ev) in
  total /. n

let game_value ~p0 ~p1 ~key =
  let n = Float.of_int (List.length deal_games) in
  List.fold deal_games ~init:0.0 ~f:(fun acc (t0, t1, g) ->
    acc +. eval g ~t0 ~t1 ~s0:p0 ~s1:p1 ~k0:key ~k1:key) /. n

let exploitability ~p0 ~p1 ~key_abstract =
  let key_full _player typ tag = sprintf "T%d|%s" typ tag in
  let gv = game_value ~p0 ~p1 ~key:key_abstract in
  let br0 = br_value ~br:0 ~opp_strat:p1 ~key_self:key_full ~key_opp:key_abstract in
  let br1 = br_value ~br:1 ~opp_strat:p0 ~key_self:key_full ~key_opp:key_abstract in
  Float.max 0.0 ((br0 -. gv) +. (br1 +. gv))

(* ----------------------------- abstractions ----------------------------- *)
(* outcome of strength s vs the FIELD of opponent types (each at its pat base) *)
let field = Array.to_list base

(* RBM descriptor: the type's game subtree — pat branch AND draw branch, each as
   outcome-nodes vs the field. Captures the joint (strength x potential). *)
let rbm_descriptor t =
  let leaves_for s =
    Tree.node ~label:() ~children:(
      List.map field ~f:(fun b -> Tree.leaf ~label:() ~value:(sd s b))) in
  let pat_group = Tree.node ~label:() ~children:[ leaves_for base.(t) ] in
  let draw_group =
    Tree.node ~label:() ~children:(List.map (draw_outcomes t) ~f:leaves_for) in
  Tree.node ~label:() ~children:[ pat_group; draw_group ]

let hist_of outcomes =
  let lose = ref 0.0 and tie = ref 0.0 and win = ref 0.0 in
  List.iter outcomes ~f:(fun o ->
    if Float.( > ) o 0.0 then win := !win +. 1.0
    else if Float.( < ) o 0.0 then lose := !lose +. 1.0
    else tie := !tie +. 1.0);
  let z = !lose +. !tie +. !win in
  [| !lose /. z; !tie /. z; !win /. z |]

(* naive: pat-strength outcome vs field (blind to draw potential) *)
let naive_hist t = hist_of (List.map field ~f:(fun b -> sd base.(t) b))
(* potential-aware: draw-outcome distribution vs field (blind to pat value) *)
let pa_hist t =
  hist_of (List.concat_map (draw_outcomes t) ~f:(fun r -> List.map field ~f:(fun b -> sd r b)))

let l1 (x : float array) (y : float array) =
  Float.abs (x.(0) -. y.(0)) +. Float.abs (x.(0) +. x.(1) -. (y.(0) +. y.(1)))
let rbm_dist a b = Distance.compute (rbm_descriptor a) (rbm_descriptor b)
let naive_dist a b = l1 (naive_hist a) (naive_hist b)
let pa_dist a b = l1 (pa_hist a) (pa_hist b)

let cluster ~dist ~k =
  let clusters = ref (List.init n_types ~f:(fun t -> [ t ])) in
  let linkage a b =
    let sum = List.fold a ~init:0.0 ~f:(fun acc x ->
      List.fold b ~init:acc ~f:(fun acc2 y -> acc2 +. dist x y)) in
    sum /. Float.of_int (List.length a * List.length b) in
  while List.length !clusters > k do
    let arr = Array.of_list !clusters in
    let bi = ref 0 and bj = ref 1 and bd = ref Float.infinity in
    for i = 0 to Array.length arr - 1 do
      for j = i + 1 to Array.length arr - 1 do
        let d = linkage arr.(i) arr.(j) in
        if Float.( < ) d !bd then (bd := d; bi := i; bj := j)
      done
    done;
    let merged = arr.(!bi) @ arr.(!bj) in
    clusters := merged :: List.filteri (Array.to_list arr) ~f:(fun idx _ -> idx <> !bi && idx <> !bj)
  done;
  let bucket = Array.create ~len:n_types 0 in
  List.iteri !clusters ~f:(fun ci members -> List.iter members ~f:(fun t -> bucket.(t) <- ci));
  bucket

let bucket_str bucket =
  let groups = Hashtbl.create (module Int) in
  Array.iteri bucket ~f:(fun t c -> Hashtbl.add_multi groups ~key:c ~data:type_names.(t));
  Hashtbl.data groups
  |> List.map ~f:(fun g -> "{" ^ String.concat ~sep:"," (List.rev g) ^ "}")
  |> String.concat ~sep:" "

(* ----------------------------- main ----------------------------- *)
let () =
  let iters = match Sys.get_argv () with [| _; s |] -> Int.of_string s | _ -> 6000 in
  printf "=== RBM vs equity baselines: DRAW POKER exploitability ===\n";
  printf "  hands (base strength, draw->): %s\n%!"
    (String.concat ~sep:"  " (List.init n_types ~f:(fun t ->
       sprintf "%s[b=%d,d->%s]" type_names.(t) base.(t)
         (String.concat ~sep:"/" (List.map (draw_outcomes t) ~f:Int.to_string)))));
  printf "  ante=%d  cfr_iters=%d\n%!" ante iters;

  printf "\n  what each statistic sees (win/tie/lose):\n%!";
  List.iter (List.init n_types ~f:Fn.id) ~f:(fun t ->
    let n = naive_hist t and p = pa_hist t in
    printf "    %-5s naive[L%.2f T%.2f W%.2f]  pot-aware[L%.2f T%.2f W%.2f]\n%!"
      type_names.(t) n.(0) n.(1) n.(2) p.(0) p.(1) p.(2));

  let key_full _player typ tag = sprintf "T%d|%s" typ tag in
  let (fp0, fp1) = train ~keyfn:key_full ~iters in
  let full = exploitability ~p0:fp0 ~p1:fp1 ~key_abstract:key_full in
  printf "\n  full-game (k=%d, no merge) exploitability = %.5f\n%!" n_types full;

  let run name dist =
    printf "\n  --- %s ---\n%!" name;
    printf "    %3s | %11s | clusters\n%!" "k" "exploit";
    let sum = ref 0.0 and cnt = ref 0 in
    for k = n_types - 1 downto 1 do
      let bucket = cluster ~dist ~k in
      let keyfn _player typ tag = sprintf "B%d|%s" bucket.(typ) tag in
      let (p0, p1) = train ~keyfn ~iters in
      let e = exploitability ~p0 ~p1 ~key_abstract:keyfn in
      sum := !sum +. e; Int.incr cnt;
      printf "    %3d | %11.5f | %s\n%!" k e (bucket_str bucket)
    done;
    !sum /. Float.of_int !cnt
  in
  let m_rbm = run "RBM (joint tree)" rbm_dist in
  let m_naive = run "naive equity (current strength)" naive_dist in
  let m_pa = run "potential-aware equity (draw dist)" pa_dist in
  printf "\n  mean exploitability over k=1..%d:\n" (n_types - 1);
  printf "    RBM=%.5f   naive=%.5f   potential-aware=%.5f\n%!" m_rbm m_naive m_pa;
  let winner =
    if Float.(m_rbm < m_naive) && Float.(m_rbm < m_pa) then "RBM beats BOTH baselines"
    else if Float.(m_rbm < m_naive) || Float.(m_rbm < m_pa) then "RBM beats one baseline"
    else "RBM does not win" in
  printf "  => %s\n%!" winner;
  printf "\nDone.\n%!"
