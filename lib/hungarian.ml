(** Hungarian algorithm (Kuhn-Munkres) for minimum-cost perfect matching.

    Classic O(n^3) implementation via potential reduction. *)

type result = {
  assignments : (int * int) list;
  cost : float;
} [@@deriving sexp]

let solve (cost : float array array) : result =
  let n = Array.length cost in
  match n with
  | 0 -> { assignments = []; cost = 0.0 }
  | _ ->
    let u = Array.create ~len:(n + 1) 0.0 in
    let v = Array.create ~len:(n + 1) 0.0 in
    let assignment = Array.create ~len:(n + 1) 0 in
    for i = 1 to n do
      let links = Array.create ~len:(n + 1) 0 in
      let mins = Array.create ~len:(n + 1) Float.infinity in
      let visited = Array.create ~len:(n + 1) false in
      assignment.(0) <- i;
      let j0 = ref 0 in
      let continue = ref true in
      while !continue do
        visited.(!j0) <- true;
        let i0 = assignment.(!j0) in
        let delta = ref Float.infinity in
        let j1 = ref 0 in
        for j = 1 to n do
          match visited.(j) with
          | true -> ()
          | false ->
            let cur = cost.(i0 - 1).(j - 1) -. u.(i0) -. v.(j) in
            (match Float.( < ) cur mins.(j) with
             | true ->
               mins.(j) <- cur;
               links.(j) <- !j0
             | false -> ());
            (match Float.( < ) mins.(j) !delta with
             | true ->
               delta := mins.(j);
               j1 := j
             | false -> ())
        done;
        for j = 0 to n do
          match visited.(j) with
          | true ->
            u.(assignment.(j)) <- u.(assignment.(j)) +. !delta;
            v.(j) <- v.(j) -. !delta
          | false ->
            mins.(j) <- mins.(j) -. !delta
        done;
        j0 := !j1;
        (match assignment.(!j0) with
         | 0 -> continue := false
         | _ -> ())
      done;
      let j = ref !j0 in
      while !j <> 0 do
        let prev = links.(!j) in
        assignment.(!j) <- assignment.(prev);
        j := prev
      done
    done;
    let assignments =
      List.init n ~f:(fun j ->
        let col = j + 1 in
        (assignment.(col) - 1, j))
    in
    let cost =
      List.sum (module Float) assignments ~f:(fun (r, c) -> cost.(r).(c))
    in
    { assignments; cost }

let solve_rectangular
    (cost : float array array)
    ~(phantom_cost_row : int -> float)
    ~(phantom_cost_col : int -> float)
  : result =
  let n_rows = Array.length cost in
  match n_rows with
  | 0 -> { assignments = []; cost = 0.0 }
  | _ ->
    let n_cols = Array.length cost.(0) in
    let n = Int.max n_rows n_cols in
    let padded = Array.init n ~f:(fun i ->
      Array.init n ~f:(fun j ->
        match i < n_rows, j < n_cols with
        | true, true -> cost.(i).(j)
        | true, false -> phantom_cost_row i
        | false, true -> phantom_cost_col j
        | false, false -> 0.0))
    in
    let raw = solve padded in
    let assignments =
      List.filter raw.assignments ~f:(fun (r, c) -> r < n_rows && c < n_cols)
    in
    { assignments; cost = raw.cost }
