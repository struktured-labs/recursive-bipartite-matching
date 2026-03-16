(** Quick verification tests for Equity and Abstraction modules. *)

open Rbm

let () =
  printf "=== Equity & Abstraction Tests ===\n\n";

  (* ---------------------------------------------------------------- *)
  (* Test 1: Canonical hand enumeration                               *)
  (* ---------------------------------------------------------------- *)
  printf "--- Test 1: Canonical hands ---\n";
  let n_canonical = List.length Equity.all_canonical_hands in
  printf "Total canonical hands: %d (expected 169)\n" n_canonical;
  assert (n_canonical = 169);

  (* Check some specific hands exist *)
  let find_by_name name =
    List.find_exn Equity.all_canonical_hands ~f:(fun h ->
      String.equal h.name name)
  in
  let aa = find_by_name "AA" in
  let aks = find_by_name "AKs" in
  let seven_two_o = find_by_name "72o" in
  printf "  AA: id=%d\n" aa.id;
  printf "  AKs: id=%d\n" aks.id;
  printf "  72o: id=%d\n" seven_two_o.id;

  (* ---------------------------------------------------------------- *)
  (* Test 2: Canonical hand mapping                                   *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 2: Canonical hand mapping ---\n";
  let ah = { Card.rank = Card.Rank.Ace; suit = Card.Suit.Hearts } in
  let as_ = { Card.rank = Card.Rank.Ace; suit = Card.Suit.Spades } in
  let kh = { Card.rank = Card.Rank.King; suit = Card.Suit.Hearts } in
  let kd = { Card.rank = Card.Rank.King; suit = Card.Suit.Diamonds } in
  let seven_c = { Card.rank = Card.Rank.Seven; suit = Card.Suit.Clubs } in
  let two_d = { Card.rank = Card.Rank.Two; suit = Card.Suit.Diamonds } in

  let aa_mapped = Equity.to_canonical (ah, as_) in
  printf "  AhAs -> %s (expected AA)\n" aa_mapped.name;
  assert (String.equal aa_mapped.name "AA");

  let aks_mapped = Equity.to_canonical (ah, kh) in
  printf "  AhKh -> %s (expected AKs)\n" aks_mapped.name;
  assert (String.equal aks_mapped.name "AKs");

  let ako_mapped = Equity.to_canonical (ah, kd) in
  printf "  AhKd -> %s (expected AKo)\n" ako_mapped.name;
  assert (String.equal ako_mapped.name "AKo");

  let seven_two_mapped = Equity.to_canonical (seven_c, two_d) in
  printf "  7c2d -> %s (expected 72o)\n" seven_two_mapped.name;
  assert (String.equal seven_two_mapped.name "72o");

  (* ---------------------------------------------------------------- *)
  (* Test 3: 7-card evaluation                                        *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 3: 7-card hand comparison ---\n";
  (* AA vs KK with a neutral board *)
  let ac = { Card.rank = Card.Rank.Ace; suit = Card.Suit.Clubs } in
  let ad = { Card.rank = Card.Rank.Ace; suit = Card.Suit.Diamonds } in
  let kc = { Card.rank = Card.Rank.King; suit = Card.Suit.Clubs } in
  let ks = { Card.rank = Card.Rank.King; suit = Card.Suit.Spades } in
  let b1 = { Card.rank = Card.Rank.Five; suit = Card.Suit.Hearts } in
  let b2 = { Card.rank = Card.Rank.Eight; suit = Card.Suit.Diamonds } in
  let b3 = { Card.rank = Card.Rank.Ten; suit = Card.Suit.Spades } in
  let b4 = { Card.rank = Card.Rank.Three; suit = Card.Suit.Clubs } in
  let b5 = { Card.rank = Card.Rank.Jack; suit = Card.Suit.Hearts } in

  let cmp = Equity.compare_7card
      (ac, ad, b1, b2, b3, b4, b5)
      (kc, ks, b1, b2, b3, b4, b5)
  in
  printf "  AA vs KK on 5h8dTs3cJh: %s (expected Win)\n"
    (match cmp > 0 with true -> "Win" | false ->
       match cmp < 0 with true -> "Lose" | false -> "Draw");
  assert (cmp > 0);

  (* ---------------------------------------------------------------- *)
  (* Test 4: Hand strength (river)                                     *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 4: River hand strength ---\n";
  let board = [ b1; b2; b3; b4; b5 ] in
  let aa_str = Equity.hand_strength ~hole_cards:(ac, ad) ~board in
  let kk_str = Equity.hand_strength ~hole_cards:(kc, ks) ~board in
  printf "  AA on 5h8dTs3cJh: %.4f (should be high)\n" aa_str;
  printf "  KK on 5h8dTs3cJh: %.4f (should be lower than AA)\n" kk_str;
  assert (Float.( > ) aa_str kk_str);
  assert (Float.( > ) aa_str 0.8);

  (* ---------------------------------------------------------------- *)
  (* Test 5: Matchup result                                           *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 5: Matchup result ---\n";
  let result = Equity.matchup_result
      ~p1_cards:(ac, ad)
      ~p2_cards:(kc, ks)
      ~board
  in
  printf "  AA vs KK on 5h8dTs3cJh: %s (expected Win)\n"
    (match result with `Win -> "Win" | `Lose -> "Lose" | `Draw -> "Draw");
  (match result with
   | `Win -> ()
   | _ -> assert false);

  (* ---------------------------------------------------------------- *)
  (* Test 6: Equity distribution (river)                               *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 6: Equity distribution (river) ---\n";
  let dist = Equity.equity_distribution
      ~hole_cards:(ac, ad)
      ~board
      ~n_bins:10
  in
  printf "  AA distribution (10 bins): [";
  Array.iter dist ~f:(fun v -> printf "%.3f " v);
  printf "]\n";
  (* AA on a neutral board should have most mass in high bins *)
  let sum = Array.fold dist ~init:0.0 ~f:( +. ) in
  printf "  Sum of bins: %.4f (should be ~1.0)\n" sum;
  assert (Float.( > ) sum 0.99 && Float.( < ) sum 1.01);

  (* ---------------------------------------------------------------- *)
  (* Test 7: Preflop equities (spot checks)                           *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 7: Preflop equities ---\n";
  printf "  Computing preflop equities for all 169 hands...\n";
  printf "  (This enumerates C(50,2) opponents per suit combo -- may take a moment)\n%!";
  let equities = Equity.preflop_equities () in
  let n_eq = Array.length equities in
  printf "  Got %d equities\n" n_eq;
  assert (n_eq = 169);

  let aa_eq = equities.(aa.id) in
  let seven_two_eq = equities.(seven_two_o.id) in
  let aks_eq = equities.(aks.id) in
  printf "  AA equity:  %.4f (expected ~0.85)\n" aa_eq;
  printf "  AKs equity: %.4f (expected ~0.67)\n" aks_eq;
  printf "  72o equity: %.4f (expected ~0.35)\n" seven_two_eq;

  (* AA should be the strongest, range roughly 0.82-0.87 *)
  assert (Float.( > ) aa_eq 0.80);
  assert (Float.( < ) aa_eq 0.90);
  (* 72o should be weak, range roughly 0.30-0.40 *)
  assert (Float.( > ) seven_two_eq 0.25);
  assert (Float.( < ) seven_two_eq 0.45);
  (* AKs stronger than 72o *)
  assert (Float.( > ) aks_eq seven_two_eq);
  (* AA stronger than AKs *)
  assert (Float.( > ) aa_eq aks_eq);

  (* ---------------------------------------------------------------- *)
  (* Test 8: Preflop abstraction (equity-based)                        *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 8: Preflop abstraction (10 buckets) ---\n";
  let abs_partial = Abstraction.abstract_preflop_equity ~n_buckets:10 in
  printf "  Created %d-bucket preflop abstraction\n" abs_partial.n_buckets;

  (* Look up bucket for AA and 72o *)
  let aa_bucket = Abstraction.get_bucket abs_partial ~hole_cards:(ac, ad) in
  let seven_two_bucket = Abstraction.get_bucket abs_partial ~hole_cards:(seven_c, two_d) in
  let aks_bucket = Abstraction.get_bucket abs_partial ~hole_cards:(ah, kh) in
  printf "  AA bucket:  %d\n" aa_bucket;
  printf "  AKs bucket: %d\n" aks_bucket;
  printf "  72o bucket: %d\n" seven_two_bucket;

  (* AA and 72o should be in very different buckets *)
  assert (aa_bucket <> seven_two_bucket);
  printf "  AA and 72o in different buckets: PASS\n";

  (* AA should be in a higher bucket (sorted by equity ascending) *)
  assert (aa_bucket > seven_two_bucket);
  printf "  AA in higher bucket than 72o: PASS\n";

  (* Print bucket distribution *)
  printf "  Bucket centroids: [";
  Array.iter abs_partial.centroids ~f:(fun v -> printf "%.3f " v);
  printf "]\n";

  (* Verify centroids are monotonically increasing *)
  let monotonic = ref true in
  for i = 1 to Array.length abs_partial.centroids - 1 do
    match Float.( >= ) abs_partial.centroids.(i) abs_partial.centroids.(i - 1) with
    | true -> ()
    | false -> monotonic := false
  done;
  printf "  Centroids monotonically increasing: %s\n"
    (match !monotonic with true -> "PASS" | false -> "FAIL");
  assert !monotonic;

  (* ---------------------------------------------------------------- *)
  (* Test 9: EMD distance                                             *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 9: EMD distance ---\n";
  let h1 = [| 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 1.0 |] in
  let h2 = [| 1.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0; 0.0 |] in
  let h3 = [| 0.1; 0.1; 0.1; 0.1; 0.1; 0.1; 0.1; 0.1; 0.1; 0.1 |] in
  let emd_12 = Abstraction.emd_histograms h1 h2 in
  let emd_11 = Abstraction.emd_histograms h1 h1 in
  let emd_13 = Abstraction.emd_histograms h1 h3 in
  printf "  EMD(all-high, all-low): %.4f (should be large)\n" emd_12;
  printf "  EMD(all-high, all-high): %.4f (should be 0.0)\n" emd_11;
  printf "  EMD(all-high, uniform):  %.4f (should be moderate)\n" emd_13;
  assert (Float.( > ) emd_12 0.0);
  assert (Float.( < ) emd_11 0.001);
  assert (Float.( > ) emd_12 emd_13);

  (* ---------------------------------------------------------------- *)
  (* Test 10: Multi-street abstraction builder                        *)
  (* ---------------------------------------------------------------- *)
  printf "\n--- Test 10: Multi-street abstraction ---\n";
  let full_abs = Abstraction.build_abstraction
      ~preflop_buckets:10
      ~flop_buckets:50
      ~turn_buckets:50
      ~river_buckets:50
  in
  printf "  Preflop buckets: %d\n" full_abs.preflop_buckets;
  printf "  Flop buckets: %d\n" full_abs.flop_buckets;
  printf "  Bucket map size: %d entries\n" (Hashtbl.length full_abs.bucket_map);
  assert (full_abs.preflop_buckets = 10);
  assert (Hashtbl.length full_abs.bucket_map > 0);

  (* Check that AA is in the bucket map *)
  let aa_key = "preflop:AA" in
  (match Hashtbl.find full_abs.bucket_map aa_key with
   | Some bucket -> printf "  preflop:AA -> bucket %d: PASS\n" bucket
   | None -> printf "  preflop:AA -> NOT FOUND: FAIL\n"; assert false);

  printf "\n=== All tests passed! ===\n"
