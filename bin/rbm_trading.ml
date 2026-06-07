(* Option (b), VIABLE DOMAIN: episodic risk-sensitive trading (position sizing).

   An episode = open a position in some market STATE, choose a position SIZE, hold
   to close, realize PnL. The objective is RISK-SENSITIVE (entropic / exponential
   utility), so the scalar expected PnL is NOT a sufficient statistic — the whole
   return DISTRIBUTION matters (variance, skew, tail). This is exactly the regime
   where a distributional metric should beat value-based abstraction.

   We abstract market states (cluster them, then commit to ONE size per cluster)
   and measure REGRET in the risk-adjusted objective vs the per-state optimum.
   We race four abstractions:
     - RBM            : distance over the forward PnL-outcome tree (= full dist)
     - value (mean)   : |E[R]| difference                 (1 statistic)
     - moments-2      : (mean, std)                        (2 statistics)
     - moments-3      : (mean, std, skew)                  (3 statistics)
   RBM captures the full distribution automatically; each fixed-moment baseline
   must fail once the decision-relevant structure exceeds its moment budget.

   Entropic certainty equivalent: CE_g(X) = -(1/g) log E[exp(-g X)].  It is
   additive across independent states, so the problem is exactly solvable.

   Usage: rbm-trading [gamma] *)

open Rbm

let gamma = match Sys.get_argv () with [| _; g |] -> Float.of_string g | _ -> 0.6

(* ---- market states: each is a set of equally-likely close-PnL scenarios ----
   Built as (drift + spread * shape). Two mean levels x {tight, right-tail,
   left-tail}. right-tail and left-tail share mean AND variance but have opposite
   skew/tail, so (mean) and (mean,std) abstractions cannot tell them apart even
   though a risk-sensitive sizer treats a crash-tail very differently. *)
let mk ~m ~base = Array.map base ~f:(fun d -> m +. d)
let tight  = [| -0.20; -0.14; -0.08; -0.03; 0.03; 0.08; 0.14; 0.20 |]
let rtail  = [| -0.30; -0.30; -0.30; -0.30; -0.30; -0.30; -0.30; 2.10 |] (* rare big WIN *)
let ltail  = [|  0.30;  0.30;  0.30;  0.30;  0.30;  0.30;  0.30; -2.10 |] (* rare big LOSS *)
(* symmetric pair: SAME mean, std, AND skew(=0); differ only in KURTOSIS. A
   moments-3 baseline literally cannot separate them, but the entropic sizer must
   (fat tails => size down). This is structure beyond 3 moments => RBM's test. *)
let bimod  = [| -0.794; -0.794; -0.794; -0.794; 0.794; 0.794; 0.794; 0.794 |] (* platykurtic *)
let fat    = [|  0.0;  0.0;  0.0;  0.0;  0.0;  0.0; -1.587; 1.587 |]          (* leptokurtic *)

let states =
  [ "Lo-tight",  mk ~m:0.20 ~base:tight;
    "Lo-rtail",  mk ~m:0.20 ~base:rtail;
    "Lo-ltail",  mk ~m:0.20 ~base:ltail;
    "Hi-tight",  mk ~m:0.55 ~base:tight;
    "Hi-rtail",  mk ~m:0.55 ~base:rtail;
    "Hi-ltail",  mk ~m:0.55 ~base:ltail;
    "Hi-bimod",  mk ~m:0.55 ~base:bimod;
    "Hi-fat",    mk ~m:0.55 ~base:fat;
  ]
let names = Array.of_list (List.map states ~f:fst)
let dists = Array.of_list (List.map states ~f:snd)
let n = Array.length dists

(* ---- statistics ---- *)
let mean xs = Array.fold xs ~init:0.0 ~f:( +. ) /. Float.of_int (Array.length xs)
let std xs =
  let m = mean xs in
  Float.sqrt (Array.fold xs ~init:0.0 ~f:(fun a x -> a +. (x -. m) ** 2.) /. Float.of_int (Array.length xs))
let skew xs =
  let m = mean xs and s = std xs in
  if Float.( <= ) s 1e-9 then 0.0
  else Array.fold xs ~init:0.0 ~f:(fun a x -> a +. ((x -. m) /. s) ** 3.) /. Float.of_int (Array.length xs)

(* ---- risk-sensitive objective ---- *)
let ce xs =
  let nn = Float.of_int (Array.length xs) in
  let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
  -. (1.0 /. gamma) *. Float.log (s /. nn)

let sizes = Array.init 11 ~f:(fun i -> 0.2 *. Float.of_int i)  (* 0.0 .. 2.0 *)
let scale f xs = Array.map xs ~f:(fun x -> f *. x)
let ce_at i f = ce (scale f dists.(i))
let best_f_state i =
  Array.fold sizes ~init:(0.0, Float.neg_infinity) ~f:(fun (bf, bv) f ->
    let v = ce_at i f in if Float.( > ) v bv then (f, v) else (bf, bv)) |> fst
let vstar i = ce_at i (best_f_state i)

(* best single size for a bucket of states (maximize summed CE) *)
let best_f_bucket members =
  Array.fold sizes ~init:(0.0, Float.neg_infinity) ~f:(fun (bf, bv) f ->
    let v = List.fold members ~init:0.0 ~f:(fun a i -> a +. ce_at i f) in
    if Float.( > ) v bv then (f, v) else (bf, bv)) |> fst

(* ---- distances ---- *)
let rbm_desc i =
  Tree.node ~label:() ~children:(Array.to_list (Array.map dists.(i) ~f:(fun r -> Tree.leaf ~label:() ~value:r)))
let rbm_dist a b = Distance.compute (rbm_desc a) (rbm_desc b)
(* decision-aware RBM: match in UTILITY units u(r) = -exp(-gamma r), so the metric
   is aligned with the entropic objective (downside weighted exponentially). *)
let rbm_util_desc i =
  Tree.node ~label:() ~children:(Array.to_list (Array.map dists.(i)
    ~f:(fun r -> Tree.leaf ~label:() ~value:(-. (Float.exp (-. gamma *. r))))))
let rbm_util_dist a b = Distance.compute (rbm_util_desc a) (rbm_util_desc b)
let value_dist a b = Float.abs (mean dists.(a) -. mean dists.(b))
let m2_dist a b =
  Float.sqrt ((mean dists.(a) -. mean dists.(b)) ** 2. +. (std dists.(a) -. std dists.(b)) ** 2.)
let m3_dist a b =
  Float.sqrt ((mean dists.(a) -. mean dists.(b)) ** 2.
              +. (std dists.(a) -. std dists.(b)) ** 2.
              +. (0.1 *. (skew dists.(a) -. skew dists.(b))) ** 2.)

(* ---- agglomerative average-linkage clustering ---- *)
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

let regret_of clustering =
  List.fold clustering ~init:0.0 ~f:(fun acc members ->
    let fb = best_f_bucket members in
    List.fold members ~init:acc ~f:(fun a i -> a +. (vstar i -. ce_at i fb)))
  /. Float.of_int n

let clusters_str clustering =
  List.map clustering ~f:(fun g ->
    "{" ^ String.concat ~sep:"," (List.map g ~f:(fun i -> names.(i))) ^ "}")
  |> String.concat ~sep:" "

let () =
  printf "=== RBM vs equity/moment abstraction: risk-sensitive position sizing ===\n";
  printf "  gamma(risk aversion)=%.2f   states=%d   sizes=0..2.0\n\n%!" gamma n;
  printf "  %-9s %7s %7s %7s | %7s %7s\n%!" "state" "mean" "std" "skew" "opt_f" "CE*";
  for i = 0 to n - 1 do
    printf "  %-9s %7.3f %7.3f %7.3f | %7.2f %7.4f\n%!"
      names.(i) (mean dists.(i)) (std dists.(i)) (skew dists.(i)) (best_f_state i) (vstar i)
  done;

  let methods = [ "RBM (raw returns)", rbm_dist;
                  "RBM-util (decision-aware)", rbm_util_dist;
                  "value (mean)", value_dist;
                  "moments-2 (mean,std)", m2_dist;
                  "moments-3 (+skew)", m3_dist ] in
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
      (name, !total /. Float.of_int !cnt))
  in
  printf "\n  mean regret over k=1..%d (LOWER is better):\n" (n - 1);
  List.iter summary ~f:(fun (name, m) -> printf "    %-22s %.5f\n%!" name m);
  let (best_name, _) =
    List.min_elt summary ~compare:(fun (_, a) (_, b) -> Float.compare a b) |> Option.value_exn in
  printf "  => best abstraction: %s\n%!" best_name;
  printf "\nDone.\n%!"
