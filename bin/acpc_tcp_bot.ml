(** ACPC TCP bot for Limit Hold'em.

    Connects to an ACPC dealer server over TCP and plays using MCCFR-trained
    strategy with equity-based card abstraction.

    The ACPC protocol is line-oriented over TCP:
    - Dealer sends MATCHSTATE lines terminated by '\r\n'
    - Client responds with the echoed MATCHSTATE plus ':' plus the action
    - Only respond when it is our turn to act

    Usage:
      ./acpc_tcp_bot.exe --host localhost --port 20000 --train 50000
      ./acpc_tcp_bot.exe --host 192.168.1.10 --port 20000 --strategy strat.bin
      ./acpc_tcp_bot.exe --host localhost --port 20000 --strategy strat.bin --save strat.bin *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Timing                                                              *)
(* ------------------------------------------------------------------ *)

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(* ------------------------------------------------------------------ *)
(* Strategy serialization (shared with acpc_bot.ml)                    *)
(* ------------------------------------------------------------------ *)

let strategy_to_sexp (strat : Cfr_abstract.strategy) : Sexp.t =
  let entries =
    Hashtbl.fold strat ~init:[] ~f:(fun ~key ~data acc ->
      let probs = List.map (Array.to_list data) ~f:(fun f ->
        Sexp.Atom (Float.to_string f)) in
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

let save_strategy ~filename (p0 : Cfr_abstract.strategy) (p1 : Cfr_abstract.strategy) =
  let sexp = Sexp.List [ strategy_to_sexp p0; strategy_to_sexp p1 ] in
  Out_channel.write_all filename ~data:(Sexp.to_string sexp)

let load_strategy ~filename : Cfr_abstract.strategy * Cfr_abstract.strategy =
  let sexp = Sexp.load_sexp filename in
  match sexp with
  | Sexp.List [ p0_sexp; p1_sexp ] ->
    (strategy_of_sexp p0_sexp, strategy_of_sexp p1_sexp)
  | _ -> failwith "load_strategy: expected pair of tables"

(* ------------------------------------------------------------------ *)
(* Action selection                                                    *)
(* ------------------------------------------------------------------ *)

(** Given a matchstate, select an action by sampling from the trained strategy. *)
let select_action
    ~(p0_strat : Cfr_abstract.strategy)
    ~(p1_strat : Cfr_abstract.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    (ms : Acpc_protocol.matchstate)
  =
  let buckets = Cfr_abstract.precompute_buckets
      ~abstraction
      ~hole_cards:ms.hole_cards
      ~board:ms.board
  in
  let round_idx = ms.current_street in
  let internal_history = Acpc_protocol.acpc_to_internal_history ms.betting in
  let key = Cfr_abstract.make_info_key ~buckets ~round_idx ~history:internal_history in
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
  (!chosen, key, probs)

(* ------------------------------------------------------------------ *)
(* TCP connection                                                      *)
(* ------------------------------------------------------------------ *)

(** Read a single line from a file descriptor, terminated by '\n'.

    The ACPC dealer sends '\r\n'-terminated lines.  We strip both
    '\r' and '\n' from the result. *)
let read_line_from_fd fd =
  let buf = Buffer.create 256 in
  let byte = Bytes.create 1 in
  let rec loop () =
    let n = Core_unix.read fd ~buf:byte ~pos:0 ~len:1 in
    match n with
    | 0 -> (* EOF *)
      (match Buffer.length buf > 0 with
       | true -> Some (Buffer.contents buf)
       | false -> None)
    | _ ->
      let c = Bytes.get byte 0 in
      (match Char.equal c '\n' with
       | true ->
         let s = Buffer.contents buf in
         Some (String.rstrip s)
       | false ->
         Buffer.add_char buf c;
         loop ())
  in
  loop ()

(** Write a line to a file descriptor, terminated by '\r\n'. *)
let write_line_to_fd fd line =
  let data = line ^ "\r\n" in
  let bytes = Bytes.of_string data in
  let len = Bytes.length bytes in
  let written = ref 0 in
  while !written < len do
    let n = Core_unix.write fd ~buf:bytes ~pos:!written ~len:(len - !written) in
    written := !written + n
  done

(** Connect to the ACPC dealer at [host]:[port] and play hands.

    Protocol loop:
    1. Read a MATCHSTATE line from the dealer
    2. Parse it
    3. If it is our turn, select an action and send the response
    4. Otherwise, do nothing (dealer does not expect a response)
    5. Repeat until the dealer closes the connection *)
let run_tcp_bot
    ~host
    ~port
    ~(p0_strat : Cfr_abstract.strategy)
    ~(p1_strat : Cfr_abstract.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~verbose
  =
  let addr = Core_unix.ADDR_INET (
    Core_unix.Inet_addr.of_string_or_getbyname host,
    port)
  in
  let fd = Core_unix.socket ~domain:PF_INET ~kind:SOCK_STREAM ~protocol:0 () in
  (try
     Core_unix.connect fd ~addr;
     eprintf "[tcp-bot] Connected to %s:%d\n%!" host port
   with
   | exn ->
     eprintf "[tcp-bot] Failed to connect to %s:%d: %s\n%!"
       host port (Exn.to_string exn);
     Core_unix.close fd;
     failwithf "Connection failed to %s:%d" host port ());
  let hands_played = ref 0 in
  let actions_taken = ref 0 in
  let unknown_keys = ref 0 in
  let rec loop () =
    match read_line_from_fd fd with
    | None ->
      eprintf "[tcp-bot] Dealer closed connection after %d hands (%d actions, %d unknown keys)\n%!"
        !hands_played !actions_taken !unknown_keys
    | Some line ->
      (match String.length line > 0 with
       | false -> loop ()
       | true ->
         (try
            let ms = Acpc_protocol.parse_matchstate line in
            (* Track hand transitions *)
            (match ms.hand_number > !hands_played with
             | true -> hands_played := ms.hand_number
             | false -> ());
            (match ms.is_our_turn with
             | false ->
               (match verbose with
                | true -> eprintf "[tcp-bot] Recv (not our turn): %s\n%!" line
                | false -> ());
               loop ()
             | true ->
               let (action, key, _probs) =
                 select_action ~p0_strat ~p1_strat ~abstraction ms
               in
               let action_str = Acpc_protocol.format_action action in
               let response = sprintf "%s:%s" line action_str in
               (match verbose with
                | true ->
                  eprintf "[tcp-bot] %s -> %s (key=%s)\n%!" line action_str key
                | false ->
                  (match !actions_taken mod 1000 = 0 && !actions_taken > 0 with
                   | true ->
                     eprintf "[tcp-bot] %d actions taken, hand #%d\n%!"
                       !actions_taken !hands_played
                   | false -> ()));
               write_line_to_fd fd response;
               Int.incr actions_taken;
               loop ())
          with
          | exn ->
            eprintf "[tcp-bot] Error on line %S: %s\n%!" line (Exn.to_string exn);
            loop ()))
  in
  (try loop ()
   with exn ->
     eprintf "[tcp-bot] Connection error: %s\n%!" (Exn.to_string exn));
  Core_unix.close fd;
  let _ = unknown_keys in
  eprintf "[tcp-bot] Session complete. %d hands, %d actions.\n%!"
    !hands_played !actions_taken

(* ------------------------------------------------------------------ *)
(* Entry point                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let host = ref "localhost" in
  let port = ref 20000 in
  let train_iters = ref 0 in
  let strategy_file = ref "" in
  let n_buckets = ref 10 in
  let save_file = ref "" in
  let verbose = ref false in

  let args = [
    ("--host", Arg.Set_string host,
     "HOST  ACPC dealer hostname (default: localhost)");
    ("--port", Arg.Set_int port,
     "PORT  ACPC dealer port (default: 20000)");
    ("--train", Arg.Set_int train_iters,
     "N  Train for N MCCFR iterations before connecting");
    ("--strategy", Arg.Set_string strategy_file,
     "FILE  Load pre-trained strategy from FILE");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Number of preflop abstraction buckets (default: 10)");
    ("--save", Arg.Set_string save_file,
     "FILE  Save trained strategy to FILE after training");
    ("--verbose", Arg.Set verbose,
     "  Log every action (default: summary only)");
  ] in
  Arg.parse args (fun _ -> ())
    "acpc_tcp_bot.exe --host HOST --port PORT [--train N | --strategy FILE]";

  let config = Limit_holdem.standard_config in

  eprintf "[tcp-bot] Building %d-bucket preflop abstraction...\n%!" !n_buckets;
  let (preflop_abs, abs_wall) = time (fun () ->
    Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets)
  in
  eprintf "[tcp-bot] Abstraction built in %.2fs\n%!" abs_wall;

  let (p0_strat, p1_strat) =
    match String.length !strategy_file > 0 with
    | true ->
      eprintf "[tcp-bot] Loading strategy from %s\n%!" !strategy_file;
      load_strategy ~filename:!strategy_file
    | false ->
      match !train_iters > 0 with
      | true ->
        eprintf "[tcp-bot] Training MCCFR for %d iterations (%d buckets)...\n%!"
          !train_iters !n_buckets;
        let ((p0, p1), wall) =
          time (fun () ->
            Cfr_abstract.train_mccfr ~config ~abstraction:preflop_abs
              ~iterations:!train_iters ~report_every:10_000 ())
        in
        eprintf "[tcp-bot] Training complete in %.2fs. P0: %d infosets, P1: %d infosets\n%!"
          wall (Hashtbl.length p0) (Hashtbl.length p1);
        (match String.length !save_file > 0 with
         | true ->
           save_strategy ~filename:!save_file p0 p1;
           eprintf "[tcp-bot] Strategy saved to %s\n%!" !save_file
         | false -> ());
        (p0, p1)
      | false ->
        eprintf "[tcp-bot] No strategy or training specified. Using uniform random.\n%!";
        (Hashtbl.Poly.create (), Hashtbl.Poly.create ())
  in

  eprintf "[tcp-bot] Connecting to %s:%d...\n%!" !host !port;
  run_tcp_bot
    ~host:!host
    ~port:!port
    ~p0_strat
    ~p1_strat
    ~abstraction:preflop_abs
    ~verbose:!verbose
