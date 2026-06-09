(* REAL-DATA 15-minute bar test of the conditional-structure thesis on BTC returns.

   This harness addresses the microstructure/irregular tick-spacing caveat of the
   original real-data test by using regular 15-minute binned, forward-filled bars
   and a longer holding horizon (2 bars = 30 min per step, 1 hour total trade length).

   State: trend = sign of trailing-W mean return (up/down) x vol = tercile of trailing-W
   stdev (lo/mid/hi) => up to 6 regimes on 15m bars.
   Episode: enter, observe 30-min return r1, choose HOLD (realize r1+r2) or CLOSE
   (realize r1) where r2 is the subsequent 30-min return.
   Objective: entropic utility, out-of-sample temporal split (first 60% train). *)

open Rbm

let argv = Sys.get_argv ()
let arg i d = if Array.length argv > i then argv.(i) else d
let gamma = Float.of_string (arg 1 "0.7")
let csv_path = arg 2 "/home/struktured/projects/recursive-bipartite-matching/tmp/btc_15m_prices.csv"
let window = Int.of_string (arg 3 "16") (* 4 hours *)

let ce xs =
  let nn = Float.of_int (Array.length xs) in
  if Float.( <= ) nn 0.0 then 0.0
  else
    let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
    -. (1.0 /. gamma) *. Float.log (s /. nn)

(* Load prices and compute log returns *)
let load_returns path =
  let lines = In_channel.read_lines path in
  match lines with
  | [] | [ _ ] -> [||]
  | _ :: rows ->
    let prices = List.filter_map rows ~f:(fun line ->
      match String.split line ~on:',' with
      | [_; p_str] -> (try Some (Float.of_string (String.strip p_str)) with _ -> None)
      | _ -> None) in
    let m = Array.of_list prices in
    Array.init (Array.length m - 1) ~f:(fun i ->
      if Float.( > ) m.(i) 0.0 && Float.( > ) m.(i+1) 0.0 then Float.log (m.(i+1) /. m.(i)) else 0.0)

let raw_rets = load_returns csv_path
let nret = Array.length raw_rets

(* Z-score using TRAIN portion (first 60%) *)
let split = Float.to_int (Float.of_int nret *. 0.6)
let mean a lo hi = let s = ref 0.0 in for i = lo to hi - 1 do s := !s +. a.(i) done; !s /. Float.of_int (hi - lo)
let std a lo hi m = let s = ref 0.0 in for i = lo to hi - 1 do s := !s +. (a.(i) -. m) ** 2. done;
  Float.sqrt (!s /. Float.of_int (hi - lo))
let mu0 = mean raw_rets 0 split
let sd0 = Float.max 1e-12 (std raw_rets 0 split mu0)
let rets = Array.map raw_rets ~f:(fun r -> (r -. mu0) /. sd0)

(* State signal *)
let trail_mean t = mean rets (t - window) t
let trail_std t = std rets (t - window) t (trail_mean t)

let train_vols =
  Array.filter_map (Array.init split ~f:Fn.id) ~f:(fun t ->
    if t >= window then Some (trail_std t) else None)
let () = Array.sort train_vols ~compare:Float.compare
let q33 = train_vols.(Array.length train_vols / 3)
let q66 = train_vols.(2 * Array.length train_vols / 3)
let state_of t =
  let tr = if Float.( >= ) (trail_mean t) 0.0 then 0 else 1 in
  let v = trail_std t in
  let vb = if Float.( < ) v q33 then 0 else if Float.( < ) v q66 then 1 else 2 in
  (tr * 3) + vb
let nstates = 6
let state_names = [| "up/lo"; "up/mid"; "up/hi"; "dn/lo"; "dn/mid"; "dn/hi" |]

(* Episode sampling: step-1 (r1) = next 2 bars, step-2 (r2) = following 2 bars *)
let samples_for ~lo ~hi state =
  let acc = ref [] in
  for t = Int.max window lo to Int.min (hi - 5) (nret - 5) do
    if state_of t = state then begin
      let r1 = rets.(t) +. rets.(t+1) in
      let r2 = rets.(t+2) +. rets.(t+3) in
      acc := ((if Float.( >= ) r1 0.0 then 0 else 1), r1, r2) :: !acc
    end
  done;
  Array.of_list !acc

(* Policy and clustering *)
let policies = [| [| true; true |]; [| true; false |]; [| false; true |]; [| false; false |] |]
let realized policy (sg, r1, r2) = if policy.(sg) then r1 else r1 +. r2
let j samples policy = ce (Array.map samples ~f:(realized policy))
let jstar samples = Array.fold policies ~init:Float.neg_infinity ~f:(fun b p -> Float.max b (j samples p))
let best_policy members samples_of =
  Array.fold policies ~init:policies.(0) ~f:(fun bp p ->
    let v q = List.fold members ~init:0.0 ~f:(fun a i -> a +. j (samples_of i) q) in
    if Float.( > ) (v p) (v bp) then p else bp)

(* Descriptors *)
let q = 6
let quantiles qq xs =
  if Array.length xs = 0 then [ 0.0 ]
  else
    let s = Array.sorted_copy xs ~compare:Float.compare in
    let nn = Array.length s in
    List.init qq ~f:(fun i -> s.(Int.min (nn - 1) (Int.of_float (((Float.of_int i +. 0.5) /. Float.of_int qq) *. Float.of_int nn))))
let tx v = -. (Float.exp (-. gamma *. v))
let qnode qq xs = Tree.node ~label:() ~children:(List.map (quantiles qq xs) ~f:(fun v -> Tree.leaf ~label:() ~value:(tx v)))
let desc_cond samples =
  Tree.node ~label:() ~children:(List.map [ 0; 1 ] ~f:(fun sg ->
    let sub = Array.filter samples ~f:(fun (s, _, _) -> s = sg) in
    Tree.node ~label:() ~children:[
      qnode q (Array.map sub ~f:(fun (_, r1, _) -> r1));
      qnode q (Array.map sub ~f:(fun (_, r1, r2) -> r1 +. r2)) ]))
let desc_flat samples =
  Tree.node ~label:() ~children:[
    qnode (2 * q) (Array.map samples ~f:(fun (_, r1, _) -> r1));
    qnode (2 * q) (Array.map samples ~f:(fun (_, r1, r2) -> r1 +. r2)) ]
let terms samples = Array.map samples ~f:(fun (_, r1, r2) -> r1 +. r2)
let smean a = if Array.length a = 0 then 0.0 else Array.fold a ~init:0.0 ~f:( +. ) /. Float.of_int (Array.length a)
let sstd a = let m = smean a in if Array.length a = 0 then 0.0 else Float.sqrt (Array.fold a ~init:0.0 ~f:(fun s x -> s +. (x -. m) ** 2.) /. Float.of_int (Array.length a))
let sskew a = let m = smean a and s = sstd a in if Float.( <= ) s 1e-9 then 0.0 else Array.fold a ~init:0.0 ~f:(fun acc x -> acc +. ((x -. m) /. s) ** 3.) /. Float.of_int (Array.length a)
let euclid a b = Float.sqrt (Array.fold2_exn a b ~init:0.0 ~f:(fun s x y -> s +. (x -. y) ** 2.))

let methods =
  [ "RBM-cond", (fun tr ->
      let d = Array.map tr ~f:desc_cond in fun a b -> Distance.compute d.(a) d.(b));
    "RBM-flat", (fun tr ->
      let d = Array.map tr ~f:desc_flat in fun a b -> Distance.compute d.(a) d.(b));
    "moments-3", (fun tr ->
      let f = Array.map tr ~f:(fun s -> let t = terms s in [| smean t; sstd t; sskew t |]) in
      fun a b -> euclid f.(a) f.(b));
    "value", (fun tr ->
      let f = Array.map tr ~f:(fun s -> smean (terms s)) in fun a b -> Float.abs (f.(a) -. f.(b)));
    "policy-feat", (fun tr ->
      let f = Array.map tr ~f:(fun s -> Array.map policies ~f:(j s)) in
      fun a b -> euclid f.(a) f.(b)) ]

let cluster ~dist ~k =
  let cl = ref (List.init nstates ~f:(fun t -> [ t ])) in
  let linkage a b =
    let s = List.fold a ~init:0.0 ~f:(fun acc x -> List.fold b ~init:acc ~f:(fun a2 y -> a2 +. dist x y)) in
    s /. Float.of_int (List.length a * List.length b) in
  while List.length !cl > k do
    let arr = Array.of_list !cl in
    let bi = ref 0 and bj = ref 1 and bd = ref Float.infinity in
    for i = 0 to Array.length arr - 1 do
      for jx = i + 1 to Array.length arr - 1 do
        let d = linkage arr.(i) arr.(jx) in
        if Float.( < ) d !bd then (bd := d; bi := i; bj := jx)
      done
    done;
    cl := (arr.(!bi) @ arr.(!bj)) :: List.filteri (Array.to_list arr) ~f:(fun idx _ -> idx <> !bi && idx <> !bj)
  done;
  !cl

let () =
  printf "=== REAL-DATA 15m-bar conditional-structure test on BTC ===\n";
  printf "  file=%s\n  gamma=%.2f window=%d  steps=%d (train=%d test=%d)  Q=%d\n%!"
    csv_path gamma window nret split (nret - split) q;
  let train = Array.init nstates ~f:(fun s -> samples_for ~lo:0 ~hi:split s) in
  let test  = Array.init nstates ~f:(fun s -> samples_for ~lo:split ~hi:nret s) in
  printf "  per-state sample counts (train/test):";
  for s = 0 to nstates - 1 do printf " %s=%d/%d" state_names.(s) (Array.length train.(s)) (Array.length test.(s)) done;
  printf "\n\n%!";

  let policy_str p = sprintf "up:%s_dn:%s" (if p.(0) then "C" else "H") (if p.(1) then "C" else "H") in
  printf "  --- DIAGNOSTICS: True optimal policies and utilities on train/test ---\n";
  for s = 0 to nstates - 1 do
    let train_opt_val = ref Float.neg_infinity in
    let train_opt_pol = ref policies.(0) in
    let test_opt_val = ref Float.neg_infinity in
    let test_opt_pol = ref policies.(0) in
    Array.iter policies ~f:(fun p ->
      let tr_v = j train.(s) p in
      let te_v = j test.(s) p in
      if Float.( > ) tr_v !train_opt_val then (train_opt_val := tr_v; train_opt_pol := p);
      if Float.( > ) te_v !test_opt_val then (test_opt_val := te_v; test_opt_pol := p)
    );
    printf "    State %-7s | Train opt: %s (val: %.4f) | Test opt: %s (val: %.4f)\n%!"
      state_names.(s) (policy_str !train_opt_pol) !train_opt_val (policy_str !test_opt_pol) !test_opt_val;
    Array.iter policies ~f:(fun p ->
      printf "      policy: %-11s | train val: %7.4f | test val: %7.4f\n%!"
        (policy_str p) (j train.(s) p) (j test.(s) p))
  done;
  printf "\n%!";

  let test_opt = Array.map test ~f:jstar in
  let oos_regret clustering =
    List.fold clustering ~init:0.0 ~f:(fun acc members ->
      let p = best_policy members (fun i -> train.(i)) in
      List.fold members ~init:acc ~f:(fun a i -> a +. (test_opt.(i) -. j test.(i) p)))
    /. Float.of_int nstates in
  let summary = List.map methods ~f:(fun (name, build) ->
    let dist = build train in
    printf "  --- %s ---\n%!" name;
    let tot = ref 0.0 and c = ref 0 in
    for k = nstates - 1 downto 1 do
      let cl = cluster ~dist ~k in
      let r = oos_regret cl in
      tot := !tot +. r; Int.incr c;
      printf "    k=%d  OOS-regret=%.5f  %s\n%!" k r
        (String.concat ~sep:" " (List.map cl ~f:(fun g -> "{" ^ String.concat ~sep:"," (List.map g ~f:(fun i -> state_names.(i))) ^ "}")))
    done;
    (name, !tot /. Float.of_int !c)) in
  printf "\n  mean OOS regret over k=1..%d (LOWER is better):\n" (nstates - 1);
  List.iter summary ~f:(fun (nm, m) -> printf "    %-14s %.5f\n%!" nm m);
  let best = List.min_elt summary ~compare:(fun (_, a) (_, b) -> Float.compare a b) |> Option.value_exn |> fst in
  printf "  => best: %s\n%!" best;
  printf "\nDone.\n%!"
