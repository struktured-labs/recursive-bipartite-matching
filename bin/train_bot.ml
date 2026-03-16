(** MCCFR training for abstract Limit Hold'em.

    Builds a 10-bucket preflop abstraction (equity-based), runs 100K
    iterations of external-sampling MCCFR, and saves/displays the
    trained strategy. *)

open Rbm

(** Fast preflop equity: fewer MC samples per hand since we only need
    rough ordering for quantile bucketing into 10 buckets. *)
let fast_preflop_equities ~n_samples =
  let n = List.length Equity.all_canonical_hands in
  let equities = Array.create ~len:n 0.0 in
  let deck = Array.of_list Card.full_deck in
  List.iter Equity.all_canonical_hands ~f:(fun (hand : Equity.canonical_hand) ->
    let h1, h2 =
      match Card.Rank.equal hand.rank1 hand.rank2 with
      | true ->
        ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
         { Card.rank = hand.rank2; suit = Card.Suit.Spades })
      | false ->
        match hand.suited with
        | true ->
          ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
           { Card.rank = hand.rank2; suit = Card.Suit.Hearts })
        | false ->
          ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
           { Card.rank = hand.rank2; suit = Card.Suit.Diamonds })
    in
    (* Build deck without hole cards *)
    let remaining =
      Array.filter deck ~f:(fun c ->
        not (Card.equal c h1) && not (Card.equal c h2))
    in
    let n_rem = Array.length remaining in
    let wins = ref 0.0 in
    let total = ref 0 in
    for _ = 1 to n_samples do
      (* Fisher-Yates shuffle of remaining *)
      for i = n_rem - 1 downto 1 do
        let j = Random.int (i + 1) in
        let tmp = remaining.(i) in
        remaining.(i) <- remaining.(j);
        remaining.(j) <- tmp
      done;
      (* 5 board cards + 2 opponent cards *)
      let b0 = remaining.(0) in
      let b1 = remaining.(1) in
      let b2 = remaining.(2) in
      let b3 = remaining.(3) in
      let b4 = remaining.(4) in
      let o1 = remaining.(5) in
      let o2 = remaining.(6) in
      let cmp = Equity.compare_7card
          (h1, h2, b0, b1, b2, b3, b4)
          (o1, o2, b0, b1, b2, b3, b4)
      in
      Int.incr total;
      match cmp > 0 with
      | true -> wins := !wins +. 1.0
      | false ->
        match cmp = 0 with
        | true -> wins := !wins +. 0.5
        | false -> ()
    done;
    equities.(hand.id) <- !wins /. Float.of_int !total);
  equities

(** Quantile bucketing: sort by equity, assign equal-sized groups. *)
let quantile_bucketing ~n_buckets (equities : float array) =
  let n = Array.length equities in
  let indexed = Array.init n ~f:(fun i -> (i, equities.(i))) in
  Array.sort indexed ~compare:(fun (_, e1) (_, e2) -> Float.compare e1 e2);
  let assignments = Hashtbl.Poly.create () in
  let centroids = Array.create ~len:n_buckets 0.0 in
  let bucket_counts = Array.create ~len:n_buckets 0 in
  let bucket_sums = Array.create ~len:n_buckets 0.0 in
  Array.iteri indexed ~f:(fun rank (hand_id, equity) ->
    let bucket = Int.min (n_buckets - 1) (rank * n_buckets / n) in
    Hashtbl.set assignments ~key:hand_id ~data:bucket;
    bucket_sums.(bucket) <- bucket_sums.(bucket) +. equity;
    bucket_counts.(bucket) <- bucket_counts.(bucket) + 1);
  Array.iteri bucket_counts ~f:(fun i count ->
    match count > 0 with
    | true -> centroids.(i) <- bucket_sums.(i) /. Float.of_int count
    | false -> centroids.(i) <- 0.0);
  (assignments, centroids)

(** Build a fast preflop abstraction with reduced MC samples. *)
let fast_preflop_abstraction ~n_buckets ~n_samples =
  let equities = fast_preflop_equities ~n_samples in
  let assignments, centroids = quantile_bucketing ~n_buckets equities in
  ({ Abstraction.street = Preflop; n_buckets; assignments; centroids }
    : Abstraction.abstraction_partial)

let () =
  printf "=== MCCFR Trainer for Abstract Limit Hold'em ===\n%!";
  let config = Limit_holdem.standard_config in
  printf "Config: SB=%d BB=%d small_bet=%d big_bet=%d max_raises=%d\n%!"
    config.small_blind config.big_blind config.small_bet config.big_bet
    config.max_raises;

  (* Build 10-bucket preflop abstraction with fast MC (2K samples) *)
  printf "\nBuilding 10-bucket preflop abstraction (fast equity, 2K samples)...\n%!";
  let t0 = Core_unix.gettimeofday () in
  let abstraction = fast_preflop_abstraction ~n_buckets:10 ~n_samples:2_000 in
  let t1 = Core_unix.gettimeofday () in
  printf "  Abstraction built in %.2fs  (%d buckets)\n%!" (t1 -. t0) abstraction.n_buckets;

  (* Show some canonical hand -> bucket assignments *)
  printf "\nSample bucket assignments:\n%!";
  let show_hand name hole_cards =
    let bucket = Abstraction.get_bucket abstraction ~hole_cards in
    printf "  %-5s -> bucket %d\n%!" name bucket
  in
  let card r s = { Card.rank = r; suit = s } in
  show_hand "AA" (card Ace Hearts, card Ace Spades);
  show_hand "KK" (card King Hearts, card King Spades);
  show_hand "AKs" (card Ace Hearts, card King Hearts);
  show_hand "AKo" (card Ace Hearts, card King Diamonds);
  show_hand "72o" (card Seven Hearts, card Two Diamonds);
  show_hand "32o" (card Three Hearts, card Two Diamonds);
  show_hand "QJs" (card Queen Hearts, card Jack Hearts);
  show_hand "TT" (card Ten Hearts, card Ten Spades);
  show_hand "55" (card Five Hearts, card Five Spades);

  (* Helper to display preflop strategy *)
  let show_preflop_strategy label strat =
    printf "\n--- %s: P0 (SB) Preflop Opening ---\n%!" label;
    printf "  (Facing BB's opening bet: fold / call / raise)\n%!";
    for bucket = 0 to 9 do
      let key = sprintf "B%d|" bucket in
      match Hashtbl.find strat key with
      | Some probs ->
        let action_names =
          match Array.length probs with
          | 3 -> [| "fold"; "call"; "raise" |]
          | 2 -> [| "fold"; "call" |]
          | _ -> Array.init (Array.length probs) ~f:(fun i -> sprintf "a%d" i)
        in
        printf "  Bucket %d: " bucket;
        Array.iteri probs ~f:(fun i p ->
          printf "%s=%.1f%%" action_names.(i) (p *. 100.0);
          match i < Array.length probs - 1 with
          | true  -> printf "  "
          | false -> ());
        printf "\n%!"
      | None ->
        printf "  Bucket %d: (no data)\n%!" bucket
    done
  in

  let iterations = 100_000 in

  (* -------------------------------------------------------------- *)
  (* 1. Train with EQUITY-based bucketing (baseline)                 *)
  (* -------------------------------------------------------------- *)
  printf "\n========================================\n%!";
  printf "  Training with EQUITY-based post-flop bucketing\n%!";
  printf "========================================\n%!";
  let t2 = Core_unix.gettimeofday () in
  let (eq_p0, eq_p1) =
    Cfr_abstract.train_mccfr ~config ~abstraction ~iterations
      ~report_every:25_000
      ~bucket_method:Equity_based ()
  in
  let t3 = Core_unix.gettimeofday () in
  let eq_time = t3 -. t2 in
  let eq_n0 = Hashtbl.length eq_p0 in
  let eq_n1 = Hashtbl.length eq_p1 in
  printf "\nEquity training: %.2fs (%.0f iter/s), P0=%d P1=%d infosets\n%!"
    eq_time (Float.of_int iterations /. eq_time) eq_n0 eq_n1;
  show_preflop_strategy "Equity" eq_p0;

  (* -------------------------------------------------------------- *)
  (* 2. Train with RBM-based bucketing (preserves error bounds)      *)
  (* -------------------------------------------------------------- *)
  printf "\n========================================\n%!";
  printf "  Training with RBM-based post-flop bucketing\n%!";
  printf "  (preserves Theorem 9.2 error bounds)\n%!";
  printf "========================================\n%!";
  let rbm_epsilon = 50.0 in
  let rbm_bucket_method =
    Cfr_abstract.Rbm_based
      { epsilon = rbm_epsilon
      ; distance_config = Distance.default_config
      }
  in
  let t4 = Core_unix.gettimeofday () in
  let (rbm_p0, rbm_p1) =
    Cfr_abstract.train_mccfr ~config ~abstraction ~iterations
      ~report_every:25_000
      ~bucket_method:rbm_bucket_method ()
  in
  let t5 = Core_unix.gettimeofday () in
  let rbm_time = t5 -. t4 in
  let rbm_n0 = Hashtbl.length rbm_p0 in
  let rbm_n1 = Hashtbl.length rbm_p1 in
  printf "\nRBM training: %.2fs (%.0f iter/s), P0=%d P1=%d infosets\n%!"
    rbm_time (Float.of_int iterations /. rbm_time) rbm_n0 rbm_n1;
  show_preflop_strategy "RBM" rbm_p0;

  (* -------------------------------------------------------------- *)
  (* 3. Comparison summary                                           *)
  (* -------------------------------------------------------------- *)
  printf "\n========================================\n%!";
  printf "  COMPARISON SUMMARY\n%!";
  printf "========================================\n%!";
  printf "  Equity postflop: P0=%d P1=%d infosets  (%.2fs)\n%!"
    eq_n0 eq_n1 eq_time;
  printf "  RBM postflop:    P0=%d P1=%d infosets  (%.2fs, eps=%.1f)\n%!"
    rbm_n0 rbm_n1 rbm_time rbm_epsilon;
  printf "  RBM/equity ratio: P0=%.2fx P1=%.2fx infosets, %.2fx time\n%!"
    (Float.of_int rbm_n0 /. Float.of_int (Int.max 1 eq_n0))
    (Float.of_int rbm_n1 /. Float.of_int (Int.max 1 eq_n1))
    (rbm_time /. Float.max 0.001 eq_time);

  (* Save equity strategy (primary output) *)
  let out_file = "strategy_mccfr_100k.dat" in
  printf "\nSaving equity strategies to %s...\n%!" out_file;
  let oc = Out_channel.create out_file in
  Marshal.to_channel oc (eq_p0, eq_p1) [ Marshal.Closures ];
  Out_channel.close oc;
  printf "Done. File size: %d bytes\n%!"
    (Int64.to_int_exn (Core_unix.stat out_file).st_size);

  (* Save RBM strategy *)
  let rbm_file = "strategy_mccfr_rbm_100k.dat" in
  printf "Saving RBM strategies to %s...\n%!" rbm_file;
  let oc2 = Out_channel.create rbm_file in
  Marshal.to_channel oc2 (rbm_p0, rbm_p1) [ Marshal.Closures ];
  Out_channel.close oc2;
  printf "Done. File size: %d bytes\n%!"
    (Int64.to_int_exn (Core_unix.stat rbm_file).st_size);

  printf "\n=== Training Complete ===\n%!"
