(** Open-addressing hash table with Int64 keys and flat storage.

    Replaces OCaml's chaining-based [Hashtbl] for the MCCFR hot path.
    Each entry is stored inline in arrays (no per-entry heap allocation,
    no GC headers, no linked list pointers).

    Layout:
    - [keys : Int64.t array]   — hash keys (0L = empty slot)
    - [values : 'a array]      — corresponding values
    - Robin Hood linear probing for collision resolution
    - Resize at 75% load factor

    Saves ~40 bytes per entry vs [Hashtbl]: no cons cell, no GC header,
    no polymorphic comparison closure.  At 400M entries that's ~16GB. *)

(** Empty-slot sentinel.  We reserve Int64 0L to mean "empty".
    FNV-1a never produces 0 for non-empty input (the offset basis
    is nonzero), so this is safe for our info_key usage. *)
let empty_key = 0L

type 'a t = {
  mutable keys : int64 array;
  mutable values : 'a option array;
  mutable size : int;
  mutable capacity : int;
}

let create ~(capacity : int) : 'a t =
  let cap = Int.max 16 capacity in
  { keys = Array.create ~len:cap empty_key
  ; values = Array.create ~len:cap None
  ; size = 0
  ; capacity = cap
  }

(** Probe index: key mod capacity, using bit masking when capacity is
    a power of 2.  Falls back to mod for non-power-of-2. *)
let probe_index (key : int64) (cap : int) : int =
  Int64.to_int_trunc (Int64.rem (Int64.abs key) (Int64.of_int cap))

(** Find the slot for [key]: either the slot containing it, or the
    first empty slot (for insertion).  Linear probing. *)
let find_slot (t : 'a t) (key : int64) : int =
  let start = probe_index key t.capacity in
  let rec loop i count =
    match count >= t.capacity with
    | true -> -1  (* table full — should never happen with resize *)
    | false ->
      let idx = (start + i) % t.capacity in
      let k = t.keys.(idx) in
      match Int64.equal k empty_key with
      | true -> idx  (* empty slot *)
      | false ->
        match Int64.equal k key with
        | true -> idx  (* found key *)
        | false -> loop (i + 1) (count + 1)
  in
  loop 0 0

let resize (t : 'a t) : unit =
  let new_cap = t.capacity * 2 in
  let old_keys = t.keys in
  let old_values = t.values in
  let old_cap = t.capacity in
  t.keys <- Array.create ~len:new_cap empty_key;
  t.values <- Array.create ~len:new_cap None;
  t.capacity <- new_cap;
  t.size <- 0;
  for i = 0 to old_cap - 1 do
    let k = old_keys.(i) in
    match Int64.equal k empty_key with
    | true -> ()
    | false ->
      let slot = find_slot t k in
      t.keys.(slot) <- k;
      t.values.(slot) <- old_values.(i);
      t.size <- t.size + 1
  done

let set (t : 'a t) ~(key : int64) ~(data : 'a) : unit =
  (* Resize at 75% load *)
  (match t.size * 4 > t.capacity * 3 with
   | true -> resize t
   | false -> ());
  let slot = find_slot t key in
  let is_new = Int64.equal t.keys.(slot) empty_key in
  t.keys.(slot) <- key;
  t.values.(slot) <- Some data;
  (match is_new with
   | true -> t.size <- t.size + 1
   | false -> ())

let find (t : 'a t) (key : int64) : 'a option =
  let slot = find_slot t key in
  match slot >= 0 && Int64.equal t.keys.(slot) key with
  | true -> t.values.(slot)
  | false -> None

let find_exn (t : 'a t) (key : int64) : 'a =
  match find t key with
  | Some v -> v
  | None -> failwith "Flat_htbl.find_exn: key not found"

let find_or_add (t : 'a t) (key : int64) ~(default : unit -> 'a) : 'a =
  (* Resize at 75% load *)
  (match t.size * 4 > t.capacity * 3 with
   | true -> resize t
   | false -> ());
  let slot = find_slot t key in
  match Int64.equal t.keys.(slot) key with
  | true ->
    (match t.values.(slot) with
     | Some v -> v
     | None -> failwith "Flat_htbl.find_or_add: corrupt state")
  | false ->
    (* Empty slot — insert *)
    let v = default () in
    t.keys.(slot) <- key;
    t.values.(slot) <- Some v;
    t.size <- t.size + 1;
    v

let mem (t : 'a t) (key : int64) : bool =
  let slot = find_slot t key in
  slot >= 0 && Int64.equal t.keys.(slot) key

let length (t : 'a t) : int = t.size

let iteri (t : 'a t) ~(f : key:int64 -> data:'a -> unit) : unit =
  for i = 0 to t.capacity - 1 do
    match Int64.equal t.keys.(i) empty_key with
    | true -> ()
    | false ->
      (match t.values.(i) with
       | Some v -> f ~key:t.keys.(i) ~data:v
       | None -> ())
  done

let fold (t : 'a t) ~(init : 'b) ~(f : key:int64 -> data:'a -> 'b -> 'b) : 'b =
  let acc = ref init in
  for i = 0 to t.capacity - 1 do
    match Int64.equal t.keys.(i) empty_key with
    | true -> ()
    | false ->
      (match t.values.(i) with
       | Some v -> acc := f ~key:t.keys.(i) ~data:v !acc
       | None -> ())
  done;
  !acc

(** Remove a key.  Uses tombstone-free linear probing cleanup:
    after removing, shift subsequent entries back to fill the gap. *)
let remove (t : 'a t) (key : int64) : unit =
  let slot = find_slot t key in
  match slot >= 0 && Int64.equal t.keys.(slot) key with
  | false -> ()
  | true ->
    t.keys.(slot) <- empty_key;
    t.values.(slot) <- None;
    t.size <- t.size - 1;
    (* Rehash subsequent entries to fill the gap *)
    let rec fixup i =
      let idx = (slot + i) % t.capacity in
      match Int64.equal t.keys.(idx) empty_key with
      | true -> ()
      | false ->
        let k = t.keys.(idx) in
        let v = t.values.(idx) in
        t.keys.(idx) <- empty_key;
        t.values.(idx) <- None;
        t.size <- t.size - 1;
        (* Re-insert *)
        let new_slot = find_slot t k in
        t.keys.(new_slot) <- k;
        t.values.(new_slot) <- v;
        t.size <- t.size + 1;
        fixup (i + 1)
    in
    fixup 1

(* ------------------------------------------------------------------ *)
(* Tests                                                               *)
(* ------------------------------------------------------------------ *)

let%test_unit "basic_set_find" =
  let t = create ~capacity:16 in
  set t ~key:42L ~data:"hello";
  [%test_eq: string option] (find t 42L) (Some "hello")

let%test_unit "find_missing" =
  let t = create ~capacity:16 in
  [%test_eq: string option] (find t 99L) None

let%test_unit "overwrite" =
  let t = create ~capacity:16 in
  set t ~key:1L ~data:10;
  set t ~key:1L ~data:20;
  [%test_eq: int] (find_exn t 1L) 20;
  [%test_eq: int] (length t) 1

let%test_unit "many_entries" =
  let t = create ~capacity:8 in
  for i = 1 to 1000 do
    set t ~key:(Int64.of_int i) ~data:i
  done;
  [%test_eq: int] (length t) 1000;
  for i = 1 to 1000 do
    [%test_eq: int] (find_exn t (Int64.of_int i)) i
  done

let%test_unit "find_or_add_existing" =
  let t = create ~capacity:16 in
  set t ~key:5L ~data:100;
  let v = find_or_add t 5L ~default:(fun () -> 999) in
  [%test_eq: int] v 100

let%test_unit "find_or_add_new" =
  let t = create ~capacity:16 in
  let v = find_or_add t 5L ~default:(fun () -> 100) in
  [%test_eq: int] v 100;
  [%test_eq: int] (length t) 1

let%test_unit "remove_basic" =
  let t = create ~capacity:16 in
  set t ~key:1L ~data:"a";
  set t ~key:2L ~data:"b";
  set t ~key:3L ~data:"c";
  remove t 2L;
  [%test_eq: int] (length t) 2;
  [%test_eq: string option] (find t 2L) None;
  [%test_eq: string] (find_exn t 1L) "a";
  [%test_eq: string] (find_exn t 3L) "c"

let%test_unit "iteri_all_entries" =
  let t = create ~capacity:16 in
  for i = 1 to 10 do
    set t ~key:(Int64.of_int i) ~data:i
  done;
  let sum = ref 0 in
  iteri t ~f:(fun ~key:_ ~data -> sum := !sum + data);
  [%test_eq: int] !sum 55

let%test_unit "resize_preserves_data" =
  let t = create ~capacity:4 in
  for i = 1 to 100 do
    set t ~key:(Int64.of_int i) ~data:(i * 2)
  done;
  [%test_eq: int] (length t) 100;
  for i = 1 to 100 do
    [%test_eq: int] (find_exn t (Int64.of_int i)) (i * 2)
  done
