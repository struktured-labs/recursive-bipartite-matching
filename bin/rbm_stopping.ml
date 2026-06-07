(* Option (b), TRAP STRESS-TEST: optimal STOPPING (when to close a trade).

   Each state offers a binary choice: CLOSE now (realize deterministic value c) or
   HOLD (realize the continuation distribution D). Risk-sensitive objective
   (entropic CE). Optimal action = CLOSE if c > CE(D) else HOLD.

   The permutation-invariance TRAP is built in: pairs of states
     lock = (c HIGH, D low)   should CLOSE
     ride = (c LOW,  D high)  should HOLD
   have the SAME optimal value V*=max(c,CE(D)) yet OPPOSITE optimal actions, and
   their forward trees are cross-matchable (a lock close-leaf ~ ride hold-leaves,
   lock hold-leaves ~ a ride close-leaf). RBM, matching children permutation-
   invariantly, should judge lock ~ ride SIMILAR and merge them, so the bucket
   must commit to ONE action and one state plays the opposite of optimal.

   Baselines:
     RBM-raw / RBM-util : tree distance (raw / utility units)
     value (Vstar)      : abs(Vstar diff)     value fn, blind to the policy split
     close-only (c)     : abs(c diff)
     policy (c, CE(D))  : respects the close-vs-hold boundary, should win

   Usage: rbm-stopping [gamma] *)

open Rbm

let gamma = match Sys.get_argv () with [| _; g |] -> Float.of_string g | _ -> 0.6
let ce xs =
  let nn = Float.of_int (Array.length xs) in
  let s = Array.fold xs ~init:0.0 ~f:(fun a x -> a +. Float.exp (-. gamma *. x)) in
  -. (1.0 /. gamma) *. Float.log (s /. nn)

(* states: (name, close value c, continuation scenarios D) *)
let states =
  [ "lock1",  1.00, [| 0.00; 0.10; 0.10; 0.20 |];   (* c high, D low  -> CLOSE *)
    "ride1",  0.10, [| 0.60; 1.00; 1.00; 1.40 |];   (* c low,  D high -> HOLD  *)
    "lock2",  0.80, [| -0.10; 0.00; 0.00; 0.10 |];  (* CLOSE *)
    "ride2",  0.00, [| 0.50; 0.80; 0.80; 1.10 |];   (* HOLD  *)
    "shut",   1.50, [| -0.20; 0.00; 0.00; 0.20 |];  (* clearly CLOSE *)
    "run",    0.00, [| 1.00; 1.50; 1.50; 2.00 |];   (* clearly HOLD  *)
    "marg1",  0.50, [| 0.30; 0.45; 0.55; 0.70 |];   (* ~indifferent  *)
    "marg2",  0.45, [| 0.20; 0.35; 0.45; 0.60 |];   (* ~indifferent  *)
  ]
let names = Array.of_list (List.map states ~f:(fun (n, _, _) -> n))
let cval  = Array.of_list (List.map states ~f:(fun (_, c, _) -> c))
let cont  = Array.of_list (List.map states ~f:(fun (_, _, d) -> d))
let n = Array.length names

let ce_hold i = ce cont.(i)
let vstar i = Float.max cval.(i) (ce_hold i)
let opt_close i = Float.( > ) cval.(i) (ce_hold i)
(* value to a state of committing bucket action [close?] *)
let val_of i ~close = if close then cval.(i) else ce_hold i

let best_action_bucket members =
  let close_v = List.fold members ~init:0.0 ~f:(fun a i -> a +. cval.(i)) in
  let hold_v = List.fold members ~init:0.0 ~f:(fun a i -> a +. ce_hold i) in
  Float.( >= ) close_v hold_v   (* true => bucket CLOSES *)

let regret_of clustering =
  List.fold clustering ~init:0.0 ~f:(fun acc members ->
    let close = best_action_bucket members in
    List.fold members ~init:acc ~f:(fun a i -> a +. (vstar i -. val_of i ~close)))
  /. Float.of_int n

(* ---- descriptors / distances ---- *)
let rbm_desc ~util i =
  let tx v = if util then -. (Float.exp (-. gamma *. v)) else v in
  let close_branch = Tree.node ~label:() ~children:[ Tree.leaf ~label:() ~value:(tx cval.(i)) ] in
  let hold_branch =
    Tree.node ~label:() ~children:(Array.to_list (Array.map cont.(i)
      ~f:(fun x -> Tree.leaf ~label:() ~value:(tx x)))) in
  Tree.node ~label:() ~children:[ close_branch; hold_branch ]
let rbm_raw a b = Distance.compute (rbm_desc ~util:false a) (rbm_desc ~util:false b)
let rbm_util a b = Distance.compute (rbm_desc ~util:true a) (rbm_desc ~util:true b)
(* structural-cue-removed: represent CLOSE as a degenerate distribution with the
   SAME arity as HOLD (4 copies of c), so the close/hold branches are cross-
   matchable. This is where the permutation-invariance trap can actually bite. *)
let rbm_flat_desc i =
  let m = Array.length cont.(i) in
  let close_branch = Tree.node ~label:() ~children:(List.init m ~f:(fun _ -> Tree.leaf ~label:() ~value:cval.(i))) in
  let hold_branch = Tree.node ~label:() ~children:(Array.to_list (Array.map cont.(i) ~f:(fun x -> Tree.leaf ~label:() ~value:x))) in
  Tree.node ~label:() ~children:[ close_branch; hold_branch ]
let rbm_flat a b = Distance.compute (rbm_flat_desc a) (rbm_flat_desc b)
let value_dist a b = Float.abs (vstar a -. vstar b)
let close_dist a b = Float.abs (cval.(a) -. cval.(b))
let policy_dist a b =
  Float.sqrt ((cval.(a) -. cval.(b)) ** 2. +. (ce_hold a -. ce_hold b) ** 2.)

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

let clusters_str clustering =
  List.map clustering ~f:(fun g ->
    "{" ^ String.concat ~sep:"," (List.map g ~f:(fun i -> names.(i))) ^ "}")
  |> String.concat ~sep:" "

let () =
  printf "=== RBM trap stress-test: optimal STOPPING (close vs hold) ===\n";
  printf "  gamma=%.2f   states=%d\n\n%!" gamma n;
  printf "  %-6s %6s %8s %8s | %s\n%!" "state" "c" "CE(D)" "V*" "optimal";
  for i = 0 to n - 1 do
    printf "  %-6s %6.2f %8.3f %8.3f | %s\n%!"
      names.(i) cval.(i) (ce_hold i) (vstar i) (if opt_close i then "CLOSE" else "HOLD")
  done;

  let methods = [ "RBM-raw (struct cue)", rbm_raw;
                  "RBM-flat (no struct cue)", rbm_flat;
                  "RBM-util (decision-aware)", rbm_util;
                  "value (V*)", value_dist;
                  "close-only (c)", close_dist;
                  "policy (c,CE(D))", policy_dist ] in
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
  List.iter summary ~f:(fun (name, m) -> printf "    %-26s %.5f\n%!" name m);
  let (best_name, _) =
    List.min_elt summary ~compare:(fun (_, a) (_, b) -> Float.compare a b) |> Option.value_exn in
  let flat_m = List.Assoc.find_exn summary ~equal:String.equal "RBM-flat (no struct cue)" in
  let policy_m = List.Assoc.find_exn summary ~equal:String.equal "policy (c,CE(D))" in
  printf "  => best: %s   (RBM-flat=%.5f vs policy-feature=%.5f)\n%!" best_name flat_m policy_m;
  printf "\nDone.\n%!"
