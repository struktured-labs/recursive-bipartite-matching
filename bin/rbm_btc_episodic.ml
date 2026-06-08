(* REAL-DATA test of the conditional-structure thesis on BTC returns.

   The toys showed RBM over the conditional tree beats terminal-moment abstraction
   when an intermediate hold/close decision makes the optimal policy depend on
   conditional structure (momentum vs mean-reversion) that the terminal marginal
   cannot express. Here we replay that exactly on real BTC mid-price returns, with
   a proper OUT-OF-SAMPLE temporal split.

   State (from PAST only, no lookahead): trend = sign of trailing-W mean return
   (up/down) x vol = tercile of trailing-W stdev (lo/mid/hi)  => up to 6 regimes.
   Episode at t: observe state, enter; observe step-1 return r_t and its sign;
   decide HOLD (realize r_t + r_{t+1}) or CLOSE (realize r_t). Risk-sensitive
   entropic objective, fixed unit size. Returns are z-scored using TRAIN stats.

   Abstraction = cluster the 6 regimes to k, commit ONE hold/close policy per
   cluster (chosen on TRAIN), evaluate risk-adjusted regret on TEST against the
   per-regime TEST optimum. Methods differ only in the clustering metric:
   RBM-cond (conditional tree), RBM-flat (marginal), moments-3, value, and
   policy-feat (the decision-aligned sufficient baseline). A null result here is
   informative: it would say real BTC mids lack conditional structure orthogonal
   to the terminal moments at this horizon.

   Usage: rbm-btc-episodic [gamma] [csv_path] [window] *)

open Rbm

let argv = Sys.get_argv ()
let arg i d = if Array.length argv > i then argv.(i) else d
let gamma = Float.of_string (arg 1 "0.7")
let csv_path = arg 2 "/home/struktured/projects/fluxit/tmp/mm_trades_btcusd.csv"
let window = Int.of_string (arg 3 "20")

let ce xs =
  let nn = Float.of_int (Array.length xs) in
  if Float.( <= ) nn 0.0 then 0.0
  else
    let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
    -. (1.0 /. gamma) *. Float.log (s /. nn)

(* ---- load mid-price series, compute log returns ---- *)
let load_returns path =
  let lines = In_channel.read_lines path in
  match lines with
  | [] | [ _ ] -> [||]
  | header :: rows ->
    let cols = String.split header ~on:',' in
    let idx name = List.findi cols ~f:(fun _ c -> String.equal c name) |> Option.map ~f:fst in
    let col = match idx "mid" with Some i -> i | None -> (match idx "price" with Some i -> i | None -> 2) in
    let mids = List.filter_map rows ~f:(fun line ->
      let fs = Array.of_list (String.split line ~on:',') in
      if Array.length fs > col then
        (try Some (Float.of_string (String.strip ~drop:(fun c -> Char.equal c '"') fs.(col))) with _ -> None)
      else None) in
    let m = Array.of_list mids in
    Array.init (Array.length m - 1) ~f:(fun i ->
      if Float.( > ) m.(i) 0.0 && Float.( > ) m.(i + 1) 0.0 then Float.log (m.(i + 1) /. m.(i)) else 0.0)

let raw_rets = load_returns csv_path
let nret = Array.length raw_rets

(* ---- z-score using TRAIN portion (first 60%) ---- *)
let split = Float.to_int (Float.of_int nret *. 0.6)
let mean a lo hi = let s = ref 0.0 in for i = lo to hi - 1 do s := !s +. a.(i) done; !s /. Float.of_int (hi - lo)
let std a lo hi m = let s = ref 0.0 in for i = lo to hi - 1 do s := !s +. (a.(i) -. m) ** 2. done;
  Float.sqrt (!s /. Float.of_int (hi - lo))
let mu0 = mean raw_rets 0 split
let sd0 = Float.max 1e-12 (std raw_rets 0 split mu0)
let rets = Array.map raw_rets ~f:(fun r -> (r -. mu0) /. sd0)

(* ---- state signal from trailing window [t-window, t-1] ---- *)
let trail_mean t = mean rets (t - window) t
let trail_std t = std rets (t - window) t (trail_mean t)
(* vol terciles from TRAIN trailing stds *)
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
  (tr * 3) + vb   (* 0..5 *)
let nstates = 6
let state_names = [| "up/lo"; "up/mid"; "up/hi"; "dn/lo"; "dn/mid"; "dn/hi" |]

(* episode samples per state, restricted to a [lo,hi) index range *)
let samples_for ~lo ~hi state =
  let acc = ref [] in
  for t = Int.max window lo to Int.min (hi - 2) (nret - 2) do
    if state_of t = state then begin
      let s1 = rets.(t) and s2 = rets.(t + 1) in
      acc := ((if Float.( >= ) s1 0.0 then 0 else 1), s1, s2) :: !acc
    end
  done;
  Array.of_list !acc

(* ---- policy machinery (identical structure to the toy) ---- *)
let policies = [| [| true; true |]; [| true; false |]; [| false; true |]; [| false; false |] |]
let realized policy (sg, s1, s2) = if policy.(sg) then s1 else s1 +. s2
let j samples policy = ce (Array.map samples ~f:(realized policy))
let jstar samples = Array.fold policies ~init:Float.neg_infinity ~f:(fun b p -> Float.max b (j samples p))
let best_policy members samples_of =   (* choose one policy maximising summed train-CE *)
  Array.fold policies ~init:policies.(0) ~f:(fun bp p ->
    let v q = List.fold members ~init:0.0 ~f:(fun a i -> a +. j (samples_of i) q) in
    if Float.( > ) (v p) (v bp) then p else bp)

(* ---- abstraction descriptors (built from TRAIN samples) ---- *)
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
      qnode q (Array.map sub ~f:(fun (_, s1, _) -> s1));
      qnode q (Array.map sub ~f:(fun (_, s1, s2) -> s1 +. s2)) ]))
let desc_flat samples =
  Tree.node ~label:() ~children:[
    qnode (2 * q) (Array.map samples ~f:(fun (_, s1, _) -> s1));
    qnode (2 * q) (Array.map samples ~f:(fun (_, s1, s2) -> s1 +. s2)) ]
let terms samples = Array.map samples ~f:(fun (_, s1, s2) -> s1 +. s2)
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
  printf "=== REAL-DATA conditional-structure test on BTC returns ===\n";
  printf "  file=%s\n  gamma=%.2f window=%d  steps=%d (train=%d test=%d)  Q=%d\n%!"
    csv_path gamma window nret split (nret - split) q;
  let train = Array.init nstates ~f:(fun s -> samples_for ~lo:0 ~hi:split s) in
  let test  = Array.init nstates ~f:(fun s -> samples_for ~lo:split ~hi:nret s) in
  printf "  per-state sample counts (train/test):";
  for s = 0 to nstates - 1 do printf " %s=%d/%d" state_names.(s) (Array.length train.(s)) (Array.length test.(s)) done;
  printf "\n\n%!";
  (* OOS regret: cluster+policy from TRAIN, evaluate against TEST optimum *)
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
