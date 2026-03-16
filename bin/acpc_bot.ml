(** ACPC bot for Limit Hold'em.

    Reads MATCHSTATE lines from stdin, outputs actions to stdout.
    Uses MCCFR-trained strategy with equity-based card abstraction.

    Usage:
      echo "MATCHSTATE:0:0::|AhKd" | ./acpc_bot.exe --train 10000
      ./acpc_bot.exe --strategy strategy.bin < matchstates.txt *)

open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(** Serialize a strategy table to a list of sexp lines. *)
let strategy_to_sexp (strat : Cfr_abstract.strategy) : Sexp.t =
  let entries =
    Hashtbl.fold strat ~init:[] ~f:(fun ~key ~data acc ->
      let probs = List.map (Array.to_list data) ~f:(fun f -> Sexp.Atom (Float.to_string f)) in
      Sexp.List [ Sexp.Atom key; Sexp.List probs ] :: acc)
  in
  Sexp.List entries

let strategy_of_sexp (sexp : Sexp.t) : Cfr_abstract.strategy =
  let table = Hashtbl.Poly.create () in
  (match sexp with
   | Sexp.List entries ->
     List.iter entries ~f:(fun entry ->
       match entry with
       | Sexp.List [ Sexp.Atom key; Sexp.List probs ] ->
         let arr = Array.of_list
           (List.map probs ~f:(fun p ->
              match p with
              | Sexp.Atom s -> Float.of_string s
              | _ -> failwith "strategy_of_sexp: expected float")) in
         Hashtbl.set table ~key ~data:arr
       | _ -> failwith "strategy_of_sexp: malformed entry")
   | _ -> failwith "strategy_of_sexp: expected list");
  table

(** Serialize a strategy pair to file. *)
let save_strategy ~filename (p0 : Cfr_abstract.strategy) (p1 : Cfr_abstract.strategy) =
  let sexp = Sexp.List [ strategy_to_sexp p0; strategy_to_sexp p1 ] in
  Out_channel.write_all filename ~data:(Sexp.to_string sexp)

(** Deserialize a strategy pair from file. *)
let load_strategy ~filename : Cfr_abstract.strategy * Cfr_abstract.strategy =
  let sexp = Sexp.load_sexp filename in
  match sexp with
  | Sexp.List [ p0_sexp; p1_sexp ] ->
    (strategy_of_sexp p0_sexp, strategy_of_sexp p1_sexp)
  | _ -> failwith "load_strategy: expected pair of tables"

(** Run the bot in stdin/stdout mode.

    For each line on stdin:
    1. Parse as MATCHSTATE
    2. If it's our turn, look up strategy and emit an action
    3. Otherwise, skip (the dealer doesn't expect a response) *)
let run_bot ~(p0_strat : Cfr_abstract.strategy) ~(p1_strat : Cfr_abstract.strategy)
    ~(abstraction : Abstraction.abstraction_partial) =
  In_channel.iter_lines In_channel.stdin ~f:(fun line ->
    let line = String.rstrip line in
    match String.length line > 0 with
    | false -> ()
    | true ->
      (try
         let ms = Acpc_protocol.parse_matchstate line in
         match ms.is_our_turn with
         | false -> ()
         | true ->
           (* Build the info key matching Cfr_abstract's format *)
           let buckets = Cfr_abstract.precompute_buckets
               ~abstraction
               ~hole_cards:ms.hole_cards
               ~board:ms.board
           in
           let round_idx = ms.current_street in
           let internal_history = Acpc_protocol.acpc_to_internal_history ms.betting in
           let key = Cfr_abstract.make_info_key ~buckets ~round_idx ~history:internal_history in
           (* Use position-appropriate strategy *)
           let strategy =
             match ms.position with
             | 0 -> p0_strat
             | _ -> p1_strat
           in
           let actions = Acpc_protocol.valid_actions ms in
           let n_actions = List.length actions in
           let probs =
             match Hashtbl.find strategy key with
             | Some p ->
               (match Array.length p = n_actions with
                | true -> p
                | false -> Array.create ~len:n_actions (1.0 /. Float.of_int n_actions))
             | None ->
               Array.create ~len:n_actions (1.0 /. Float.of_int n_actions)
           in
           (* Sample an action *)
           let r = Random.float 1.0 in
           let cumulative = ref 0.0 in
           let chosen = ref (List.last_exn actions) in
           let found = ref false in
           List.iteri actions ~f:(fun i action ->
             match !found with
             | true -> ()
             | false ->
               cumulative := !cumulative +. probs.(i);
               match Float.( >= ) !cumulative r with
               | true -> chosen := action; found := true
               | false -> ());
           let action_str = Acpc_protocol.format_action !chosen in
           (* Output: echo the matchstate line followed by the action *)
           printf "%s:%s\n%!" line action_str
       with
       | exn ->
         eprintf "[bot] Error parsing %S: %s\n%!" line (Exn.to_string exn)))

let () =
  let train_iters = ref 0 in
  let strategy_file = ref "" in
  let n_buckets = ref 10 in
  let save_file = ref "" in

  let args = [
    ("--train", Arg.Set_int train_iters,
     "N  Train for N MCCFR iterations before playing");
    ("--strategy", Arg.Set_string strategy_file,
     "FILE  Load pre-trained strategy from FILE");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Number of preflop abstraction buckets (default: 10)");
    ("--save", Arg.Set_string save_file,
     "FILE  Save trained strategy to FILE");
  ] in
  Arg.parse args (fun _ -> ()) "acpc_bot.exe [--train N | --strategy FILE] < matchstates";

  let config = Limit_holdem.standard_config in

  eprintf "[bot] Building %d-bucket preflop abstraction...\n%!" !n_buckets;
  let (preflop_abs, abs_wall) = time (fun () ->
    Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets)
  in
  eprintf "[bot] Abstraction built in %.2fs\n%!" abs_wall;

  let (p0_strat, p1_strat) =
    match String.length !strategy_file > 0 with
    | true ->
      eprintf "[bot] Loading strategy from %s\n%!" !strategy_file;
      load_strategy ~filename:!strategy_file
    | false ->
      match !train_iters > 0 with
      | true ->
        eprintf "[bot] Training MCCFR for %d iterations (%d buckets)...\n%!"
          !train_iters !n_buckets;
        let ((p0, p1), wall) =
          time (fun () ->
            Cfr_abstract.train_mccfr ~config ~abstraction:preflop_abs
              ~iterations:!train_iters ~report_every:10_000 ())
        in
        eprintf "[bot] Training complete in %.2fs. P0 infosets: %d, P1 infosets: %d\n%!"
          wall (Hashtbl.length p0) (Hashtbl.length p1);
        (match String.length !save_file > 0 with
         | true ->
           save_strategy ~filename:!save_file p0 p1;
           eprintf "[bot] Strategy saved to %s\n%!" !save_file
         | false -> ());
        (p0, p1)
      | false ->
        eprintf "[bot] No strategy or training specified. Using uniform random.\n%!";
        (Hashtbl.Poly.create (), Hashtbl.Poly.create ())
  in

  run_bot ~p0_strat ~p1_strat ~abstraction:preflop_abs
