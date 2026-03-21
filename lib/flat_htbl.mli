(** Open-addressing hash table with Int64 keys and flat storage.

    Drop-in replacement for [(Int64.t, 'a) Hashtbl.t] on the MCCFR hot path.
    Uses linear probing with inline key/value arrays — no per-entry heap
    allocation, no GC headers, no linked list pointers.

    Saves ~40 bytes per entry vs [Hashtbl].  At 400M entries: ~16GB. *)

type 'a t

val create : capacity:int -> 'a t
val set : 'a t -> key:int64 -> data:'a -> unit
val find : 'a t -> int64 -> 'a option
val find_exn : 'a t -> int64 -> 'a
val find_or_add : 'a t -> int64 -> default:(unit -> 'a) -> 'a
val mem : 'a t -> int64 -> bool
val length : 'a t -> int
val remove : 'a t -> int64 -> unit
val iteri : 'a t -> f:(key:int64 -> data:'a -> unit) -> unit
val fold : 'a t -> init:'b -> f:(key:int64 -> data:'a -> 'b -> 'b) -> 'b
