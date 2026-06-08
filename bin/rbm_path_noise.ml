(* Noise-robustness stress test for the multi-step conditional-structure result.

   The exact toy (rbm_trading_path) showed RBM over the conditional tree beats
   terminal-moment / value abstraction when regimes share a terminal marginal but
   differ in conditional structure. That used EXACT distributions. A real domain
   must ESTIMATE each state's outcome distribution from finite data, and a
   full-distribution (tree/Wasserstein) metric may overfit sampling noise where a
   3-moment estimator is low-variance. This harness asks: does RBM's advantage
   SURVIVE finite-sample estimation?

   Protocol: draw M samples per state from its true path distribution (plus small
   Gaussian observation noise), summarise each state from the SAME samples
   (RBM: Q-quantile sketch of the conditional tree; moments: 3 moments of the
   terminal marginal; value: mean; policy-feature: empirical CE under each policy
   -- the decision-aligned SUFFICIENT baseline). Cluster with the noisy distances,
   then score the resulting abstraction against the TRUE objective. Average over
   seeds, sweep M; report mean +/- 95% CI.

   Usage: rbm-path-noise [gamma] *)

open Rbm

let gamma = match Sys.get_argv () with [| _; g |] -> Float.of_string g | _ -> 0.7
let ce xs =
  let nn = Float.of_int (Array.length xs) in
  let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
  -. (1.0 /. gamma) *. Float.log (s /. nn)

(* same 6 regimes as rbm_trading_path: 4 share terminal marginal {+2,0,0,-2} *)
let regimes =
  [ "momentum", [| (0, 1.0, 1.0); (0, 1.0, -1.0); (1, -1.0, 1.0); (1, -1.0, -1.0) |];
    "reversion",[| (0, 1.0, -1.0); (0, 1.0, -3.0); (1, -1.0, 3.0); (1, -1.0, 1.0) |];
    "vol-up",   [| (0, 1.0, 1.0); (0, 1.0, -3.0); (1, -1.0, 1.0); (1, -1.0, 1.0) |];
    "vol-down", [| (0, 1.0, -1.0); (0, 1.0, -1.0); (1, -1.0, 3.0); (1, -1.0, -1.0) |];
    "drift",    [| (0, 1.0, 1.5); (0, 1.0, -0.5); (1, -1.0, 1.5); (1, -1.0, -0.5) |];
    "calm",     [| (0, 1.0, -0.5); (0, 1.0, -0.7); (1, -1.0, 0.7); (1, -1.0, 0.5) |];
  ]
let names = Array.of_list (List.map regimes ~f:fst)
let paths = Array.of_list (List.map regimes ~f:snd)
let n = Array.length names

let policies = [| [| true; true |]; [| true; false |]; [| false; true |]; [| false; false |] |]
let realized policy (sg, m1, m2) = if policy.(sg) then m1 else m1 +. m2
let j_true i policy = ce (Array.map paths.(i) ~f:(realized policy))
let jstar i = Array.fold policies ~init:Float.neg_infinity ~f:(fun b p -> Float.max b (j_true i p))
let best_policy_bucket members =
  Array.fold policies ~init:policies.(0) ~f:(fun bp p ->
    let v q = List.fold members ~init:0.0 ~f:(fun a i -> a +. j_true i q) in
    if Float.( > ) (v p) (v bp) then p else bp)
(* regret of a clustering evaluated against the TRUE objective *)
let regret_of clustering =
  List.fold clustering ~init:0.0 ~f:(fun acc members ->
    let p = best_policy_bucket members in
    List.fold members ~init:acc ~f:(fun a i -> a +. (jstar i -. j_true i p)))
  /. Float.of_int n

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
    clusters := (arr.(!bi) @ arr.(!bj))
      :: List.filteri (Array.to_list arr) ~f:(fun idx _ -> idx <> !bi && idx <> !bj)
  done;
  !clusters
let mean_regret_over_k ~dist =
  let tot = ref 0.0 and c = ref 0 in
  for k = n - 1 downto 1 do tot := !tot +. regret_of (cluster ~dist ~k); Int.incr c done;
  !tot /. Float.of_int !c

(* ---- sampling + estimation ---- *)
let gauss st =
  let u1 = Float.max 1e-12 (Random.State.float st 1.0) in
  let u2 = Random.State.float st 1.0 in
  Float.sqrt (-2.0 *. Float.log u1) *. Float.cos (2.0 *. Float.pi *. u2)
let sample_state st i ~m ~sigma =
  Array.init m ~f:(fun _ ->
    let (sg, m1, m2) = paths.(i).(Random.State.int st 4) in
    (sg, m1 +. (sigma *. gauss st), m2 +. (sigma *. gauss st)))

let quantiles q xs =
  if Array.length xs = 0 then []
  else
    let s = Array.sorted_copy xs ~compare:Float.compare in
    let nn = Array.length s in
    List.init q ~f:(fun i ->
      let p = (Float.of_int i +. 0.5) /. Float.of_int q in
      s.(Int.min (nn - 1) (Int.of_float (p *. Float.of_int nn))))
let tx v = -. (Float.exp (-. gamma *. v))
let q_leaves q xs = Tree.node ~label:() ~children:(List.map (quantiles q xs) ~f:(fun v -> Tree.leaf ~label:() ~value:(tx v)))

(* RBM conditional tree: root -> [up -> (close-quantiles, hold-quantiles), down -> ...] *)
let desc_cond ~q samples =
  Tree.node ~label:() ~children:(List.map [ 0; 1 ] ~f:(fun sg ->
    let sub = Array.filter samples ~f:(fun (s, _, _) -> s = sg) in
    let closes = Array.map sub ~f:(fun (_, m1, _) -> m1) in
    let holds = Array.map sub ~f:(fun (_, m1, m2) -> m1 +. m2) in
    Tree.node ~label:() ~children:[ q_leaves q closes; q_leaves q holds ]))
(* RBM flat: same close/hold split but conditional (sig) grouping removed *)
let desc_flat ~q samples =
  let closes = Array.map samples ~f:(fun (_, m1, _) -> m1) in
  let holds = Array.map samples ~f:(fun (_, m1, m2) -> m1 +. m2) in
  Tree.node ~label:() ~children:[ q_leaves (2 * q) closes; q_leaves (2 * q) holds ]

let mean xs = Array.fold xs ~init:0.0 ~f:( +. ) /. Float.of_int (Array.length xs)
let std xs = let m = mean xs in
  Float.sqrt (Array.fold xs ~init:0.0 ~f:(fun a x -> a +. (x -. m) ** 2.) /. Float.of_int (Array.length xs))
let skew xs = let m = mean xs and s = std xs in
  if Float.( <= ) s 1e-9 then 0.0
  else Array.fold xs ~init:0.0 ~f:(fun a x -> a +. ((x -. m) /. s) ** 3.) /. Float.of_int (Array.length xs)
let terminals samples = Array.map samples ~f:(fun (_, m1, m2) -> m1 +. m2)
let policy_feat samples = Array.map policies ~f:(fun p -> ce (Array.map samples ~f:(realized p)))

let euclid a b = Float.sqrt (Array.fold2_exn a b ~init:0.0 ~f:(fun s x y -> s +. (x -. y) ** 2.))

(* methods: each builds, from the sampled states, a pairwise distance closure *)
let q = 8
let methods =
  [ "RBM-cond",  (fun s ->
      let d = Array.init n ~f:(fun i -> desc_cond ~q s.(i)) in
      fun a b -> Distance.compute d.(a) d.(b));
    "RBM-flat",  (fun s ->
      let d = Array.init n ~f:(fun i -> desc_flat ~q s.(i)) in
      fun a b -> Distance.compute d.(a) d.(b));
    "moments-3", (fun s ->
      let f = Array.init n ~f:(fun i -> let t = terminals s.(i) in [| mean t; std t; skew t |]) in
      fun a b -> euclid f.(a) f.(b));
    "value",     (fun s ->
      let f = Array.init n ~f:(fun i -> mean (terminals s.(i))) in
      fun a b -> Float.abs (f.(a) -. f.(b)));
    "policy-feat (sufficient)", (fun s ->
      let f = Array.init n ~f:(fun i -> policy_feat s.(i)) in
      fun a b -> euclid f.(a) f.(b));
  ]

let () =
  let sigma = match Sys.get_argv () with [| _; _; s |] -> Float.of_string s | _ -> 0.15 in
  let seeds = 60 in
  let ms = [ 20; 50; 150; 600 ] in
  printf "=== Noise-robustness: conditional-structure abstraction under finite samples ===\n";
  printf "  gamma=%.2f  Q=%d  obs-noise sigma=%.2f  seeds=%d  (TRUE-objective regret, lower better)\n\n%!"
    gamma q sigma seeds;
  printf "  %-26s" "method \\ M samples/state";
  List.iter ms ~f:(fun m -> printf " %13s" (sprintf "M=%d" m));
  printf " %13s\n%!" "exact";
  (* exact reference: descriptors from the true 4 paths (each once), no noise *)
  let exact_dist =
    List.map methods ~f:(fun (nm, mk) ->
      let s = Array.init n ~f:(fun i -> paths.(i)) in
      (nm, mean_regret_over_k ~dist:(mk s))) in
  List.iter methods ~f:(fun (nm, mk) ->
    printf "  %-26s" nm;
    List.iter ms ~f:(fun m ->
      let rs = Array.init seeds ~f:(fun seed ->
        let st = Random.State.make [| seed; m |] in
        let s = Array.init n ~f:(fun i -> sample_state st i ~m ~sigma) in
        mean_regret_over_k ~dist:(mk s)) in
      let mu = mean rs and sd = std rs in
      let ci = 1.96 *. sd /. Float.sqrt (Float.of_int seeds) in
      printf " %6.4f+-%.4f" mu ci);
    printf " %13.4f\n%!" (List.Assoc.find_exn exact_dist ~equal:String.equal nm));
  printf "\nDone.\n%!"
