(** Hungarian algorithm for minimum-cost bipartite matching.

    Solves the linear assignment problem: given an n x m cost matrix,
    find the minimum-cost perfect matching. Pads with phantom rows/columns
    at a given penalty cost when dimensions differ. *)

(** Result of a matching: list of (row, col) pairs and total cost *)
type result = {
  assignments : (int * int) list;
  cost : float;
} [@@deriving sexp]

(** [solve cost_matrix] finds the minimum-cost perfect matching.
    Cost matrix is row-major: cost_matrix.(i).(j) = cost of assigning row i to col j.
    Matrix must be square; use [solve_rectangular] for non-square inputs. *)
val solve : float array array -> result

(** [solve_rectangular cost_matrix ~phantom_cost] handles non-square matrices
    by padding the smaller dimension with phantom entries at the given cost.
    [phantom_cost.(i)] is the cost of leaving real entry i unmatched. *)
val solve_rectangular
  :  float array array
  -> phantom_cost_row:(int -> float)
  -> phantom_cost_col:(int -> float)
  -> result
