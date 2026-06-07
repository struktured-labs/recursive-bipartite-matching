(* Option (b) extension: MULTI-STEP path structure — does RBM's tree-sensitivity
   add value beyond the terminal return distribution?

   Episode = open, observe a step-1 move, choose HOLD or CLOSE, then (if held) a
   step-2 move resolves; realize PnL. Risk-sensitive (entropic) objective. The
   regimes differ in CONDITIONAL structure (step2 | step1): MOMENTUM (a down step1
   predicts more down => cut losses / CLOSE after down) vs MEAN-REVERSION (a down
   step1 predicts a bounce => HOLD after down). The optimal intermediate policy
   depends on this conditional structure, which the TERMINAL return MARGINAL cannot
   express.

   We abstract regimes (cluster, commit to ONE intermediate policy per cluster) and
   measure risk-adjusted REGRET. The decisive internal control:
     RBM-cond : RBM over the CONDITIONAL tree  root->[up->{...}, down->{...}]
     RBM-flat : RBM over the SAME leaves with NO step-1 grouping (marginal only)
   Identical leaf multiset; the ONLY difference is whether path/conditional
   structure is preserved. If RBM-cond < RBM-flat, preserving multi-step structure
   demonstrably helps. We also race terminal moments and value(mean).

   Usage: rbm-trading-path [gamma] *)

open Rbm

let gamma = match Sys.get_argv () with [| _; g |] -> Float.of_string g | _ -> 0.7
let ce xs =
  let nn = Float.of_int (Array.length xs) in
  let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
  -. (1.0 /. gamma) *. Float.log (s /. nn)

(* a path = (sig, m1, m2): sig=0 up / 1 down at step 1; m1 step-1 PnL; m2 step-2 PnL.
   each regime has 4 equally-likely paths (2 up, 2 down). *)
(* step1 is fixed (+1 up / -1 down); terminal = m1+m2. Regimes I..IV all share the
   SAME terminal multiset {+2,0,0,-2} (identical mean/std/skew/ALL moments) but
   distribute it across up/down differently => terminal-moment abstraction is BLIND
   among them, yet they need different intermediate policies. drift/calm have
   distinct marginals (sanity anchors the moment baselines can resolve). *)
let regimes =
  [ (* momentum: up->{+2,0} (hold if up), down->{0,-2} (cut if down) *)
    "momentum", [| (0, 1.0, 1.0); (0, 1.0, -1.0); (1, -1.0, 1.0); (1, -1.0, -1.0) |];
    (* reversion: up->{0,-2} (cut if up), down->{+2,0} (hold if down) *)
    "reversion",[| (0, 1.0, -1.0); (0, 1.0, -3.0); (1, -1.0, 3.0); (1, -1.0, 1.0) |];
    (* vol-up: up->{+2,-2} (risky if up=>cut), down->{0,0} (safe=>hold) *)
    "vol-up",   [| (0, 1.0, 1.0); (0, 1.0, -3.0); (1, -1.0, 1.0); (1, -1.0, 1.0) |];
    (* vol-down: up->{0,0} (cut), down->{+2,-2} (risky if down) *)
    "vol-down", [| (0, 1.0, -1.0); (0, 1.0, -1.0); (1, -1.0, 3.0); (1, -1.0, -1.0) |];
    (* distinct marginals: positive drift / low vol *)
    "drift",    [| (0, 1.0, 1.5); (0, 1.0, -0.5); (1, -1.0, 1.5); (1, -1.0, -0.5) |];
    "calm",     [| (0, 1.0, -0.5); (0, 1.0, -0.7); (1, -1.0, 0.7); (1, -1.0, 0.5) |];
  ]
let names = Array.of_list (List.map regimes ~f:fst)
let paths = Array.of_list (List.map regimes ~f:snd)
let n = Array.length names

(* a policy maps step-1 signal (0/1) to action: true = CLOSE, false = HOLD *)
let policies = [| [| true; true |]; [| true; false |]; [| false; true |]; [| false; false |] |]
let realized policy (sg, m1, m2) = if policy.(sg) then m1 else m1 +. m2
let j i policy = ce (Array.map paths.(i) ~f:(realized policy))
let jstar i = Array.fold policies ~init:Float.neg_infinity ~f:(fun b p -> Float.max b (j i p))
let opt_policy_str i =
  let bp = Array.fold policies ~init:policies.(0) ~f:(fun bp p ->
    if Float.( > ) (j i p) (j i bp) then p else bp) in
  sprintf "up:%s down:%s" (if bp.(0) then "C" else "H") (if bp.(1) then "C" else "H")

let best_policy_bucket members =
  Array.fold policies ~init:policies.(0) ~f:(fun bp p ->
    let v q = List.fold members ~init:0.0 ~f:(fun a i -> a +. j i q) in
    if Float.( > ) (v p) (v bp) then p else bp)
let regret_of clustering =
  List.fold clustering ~init:0.0 ~f:(fun acc members ->
    let p = best_policy_bucket members in
    List.fold members ~init:acc ~f:(fun a i -> a +. (jstar i -. j i p)))
  /. Float.of_int n

(* ---- descriptors ---- *)
let tx v = -. (Float.exp (-. gamma *. v))   (* decision-aware utility units *)
(* leaves under each step-1 signal: the CLOSE option (m1) and the two HOLD
   continuations (m1+m2); preserves the per-signal decision structure. *)
let sig_leaves i sg =
  Array.to_list paths.(i)
  |> List.filter ~f:(fun (s, _, _) -> s = sg)
  |> List.concat_map ~f:(fun (_, m1, m2) -> [ m1; m1 +. m2 ])
  |> List.dedup_and_sort ~compare:Float.compare
let rbm_cond_desc i =
  Tree.node ~label:() ~children:(List.map [ 0; 1 ] ~f:(fun sg ->
    Tree.node ~label:() ~children:(List.map (sig_leaves i sg)
      ~f:(fun v -> Tree.leaf ~label:() ~value:(tx v)))))
let rbm_flat_desc i =
  let all = List.concat_map [ 0; 1 ] ~f:(sig_leaves i) in
  Tree.node ~label:() ~children:(List.map all ~f:(fun v -> Tree.leaf ~label:() ~value:(tx v)))
let rbm_cond a b = Distance.compute (rbm_cond_desc a) (rbm_cond_desc b)
let rbm_flat a b = Distance.compute (rbm_flat_desc a) (rbm_flat_desc b)

let terminals i = Array.map paths.(i) ~f:(fun (_, m1, m2) -> m1 +. m2)
let mean xs = Array.fold xs ~init:0.0 ~f:( +. ) /. Float.of_int (Array.length xs)
let std xs = let m = mean xs in
  Float.sqrt (Array.fold xs ~init:0.0 ~f:(fun a x -> a +. (x -. m) ** 2.) /. Float.of_int (Array.length xs))
let skew xs = let m = mean xs and s = std xs in
  if Float.( <= ) s 1e-9 then 0.0
  else Array.fold xs ~init:0.0 ~f:(fun a x -> a +. ((x -. m) /. s) ** 3.) /. Float.of_int (Array.length xs)
let term_mom a b =
  let x = terminals a and y = terminals b in
  Float.sqrt ((mean x -. mean y) ** 2. +. (std x -. std y) ** 2. +. (skew x -. skew y) ** 2.)
let value_dist a b = Float.abs (mean (terminals a) -. mean (terminals b))

let cluster ~dist ~k =
  let clusters = ref (List.init n ~f:(fun t -> [ t ])) in
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
  !clusters
let clusters_str cl =
  List.map cl ~f:(fun g -> "{" ^ String.concat ~sep:"," (List.map g ~f:(fun i -> names.(i))) ^ "}")
  |> String.concat ~sep:" "

let () =
  printf "=== RBM multi-step: conditional path structure (momentum vs mean-reversion) ===\n";
  printf "  gamma=%.2f   regimes=%d   (intermediate HOLD/CLOSE after step 1)\n\n%!" gamma n;
  printf "  %-7s %8s %8s | %s\n%!" "regime" "term-mu" "term-sd" "opt policy";
  for i = 0 to n - 1 do
    printf "  %-7s %8.3f %8.3f | %s\n%!"
      names.(i) (mean (terminals i)) (std (terminals i)) (opt_policy_str i)
  done;
  let methods = [ "RBM-cond (path tree)", rbm_cond;
                  "RBM-flat (marginal)", rbm_flat;
                  "terminal-moments (3)", term_mom;
                  "value (term mean)", value_dist ] in
  let summary =
    List.map methods ~f:(fun (name, dist) ->
      printf "\n  --- %s ---\n%!" name;
      printf "    %3s | %10s | clusters\n%!" "k" "regret";
      let total = ref 0.0 and cnt = ref 0 in
      for k = n - 1 downto 1 do
        let cl = cluster ~dist ~k in
        let r = regret_of cl in
        total := !total +. r; Int.incr cnt;
        printf "    %3d | %10.5f | %s\n%!" k r (clusters_str cl)
      done;
      (name, !total /. Float.of_int !cnt)) in
  printf "\n  mean regret over k=1..%d (LOWER is better):\n" (n - 1);
  List.iter summary ~f:(fun (nm, m) -> printf "    %-22s %.5f\n%!" nm m);
  let cond = List.Assoc.find_exn summary ~equal:String.equal "RBM-cond (path tree)" in
  let flat = List.Assoc.find_exn summary ~equal:String.equal "RBM-flat (marginal)" in
  printf "  value of preserving path structure: RBM-cond=%.5f vs RBM-flat=%.5f (%s)\n%!"
    cond flat (if Float.( < ) cond flat then "path structure HELPS" else "no gain from path");
  printf "\nDone.\n%!"
