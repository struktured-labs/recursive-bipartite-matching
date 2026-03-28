/// Hungarian algorithm (Kuhn-Munkres) for minimum-cost perfect matching.
///
/// Classic O(n^3) implementation via potential reduction.
/// Ported exactly from OCaml's lib/hungarian.ml.

/// Find minimum-cost perfect matching for an n x n square cost matrix.
///
/// `cost` is an n x n matrix where `cost[i][j]` is the cost of assigning
/// row i to column j.
///
/// Returns the total cost of the optimal matching.
///
/// # Panics
/// Panics if the matrix is not square or empty rows have different lengths.
pub fn min_cost_matching(cost: &[Vec<f64>]) -> f64 {
    min_cost_matching_with_assignments(cost).0
}

/// Like `min_cost_matching` but also returns the assignment pairs (row, col).
pub fn min_cost_matching_with_assignments(cost: &[Vec<f64>]) -> (f64, Vec<(usize, usize)>) {
    let n = cost.len();
    if n == 0 {
        return (0.0, vec![]);
    }

    // Potentials (1-indexed; index 0 is a sentinel)
    let mut u = vec![0.0f64; n + 1];
    let mut v = vec![0.0f64; n + 1];
    // assignment[j] = row assigned to column j (1-indexed)
    let mut assignment = vec![0usize; n + 1];

    for i in 1..=n {
        let mut links = vec![0usize; n + 1];
        let mut mins = vec![f64::INFINITY; n + 1];
        let mut visited = vec![false; n + 1];

        assignment[0] = i;
        let mut j0: usize = 0;

        loop {
            visited[j0] = true;
            let i0 = assignment[j0];
            let mut delta = f64::INFINITY;
            let mut j1: usize = 0;

            for j in 1..=n {
                if visited[j] {
                    continue;
                }
                let cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
                if cur < mins[j] {
                    mins[j] = cur;
                    links[j] = j0;
                }
                if mins[j] < delta {
                    delta = mins[j];
                    j1 = j;
                }
            }

            for j in 0..=n {
                if visited[j] {
                    u[assignment[j]] += delta;
                    v[j] -= delta;
                } else {
                    mins[j] -= delta;
                }
            }

            j0 = j1;
            if assignment[j0] == 0 {
                break;
            }
        }

        // Trace back the augmenting path
        let mut j = j0;
        while j != 0 {
            let prev = links[j];
            assignment[j] = assignment[prev];
            j = prev;
        }
    }

    // Build assignment list and compute cost
    let mut assignments = Vec::with_capacity(n);
    let mut total_cost = 0.0;
    for col in 1..=n {
        let row = assignment[col] - 1; // convert to 0-indexed
        let c = col - 1;
        assignments.push((row, c));
        total_cost += cost[row][c];
    }

    (total_cost, assignments)
}

/// Minimum-cost matching for rectangular matrices.
///
/// Pads the smaller dimension with phantom rows/columns so the matrix becomes
/// square. Phantom costs are provided by the caller.
///
/// - `phantom_cost_row(i)`: cost of leaving real row i unmatched
/// - `phantom_cost_col(j)`: cost of leaving real column j unmatched
/// - Phantom-to-phantom matches cost 0.
///
/// Returns total cost (including phantom penalties for unmatched items).
pub fn min_cost_matching_rectangular(
    cost: &[Vec<f64>],
    phantom_cost_row: &dyn Fn(usize) -> f64,
    phantom_cost_col: &dyn Fn(usize) -> f64,
) -> f64 {
    min_cost_matching_rectangular_with_assignments(cost, phantom_cost_row, phantom_cost_col).0
}

/// Like `min_cost_matching_rectangular` but also returns the real assignment
/// pairs (row, col) — phantom matches are excluded.
pub fn min_cost_matching_rectangular_with_assignments(
    cost: &[Vec<f64>],
    phantom_cost_row: &dyn Fn(usize) -> f64,
    phantom_cost_col: &dyn Fn(usize) -> f64,
) -> (f64, Vec<(usize, usize)>) {
    let n_rows = cost.len();
    if n_rows == 0 {
        return (0.0, vec![]);
    }
    let n_cols = cost[0].len();
    let n = n_rows.max(n_cols);

    // Build padded square matrix
    let padded: Vec<Vec<f64>> = (0..n)
        .map(|i| {
            (0..n)
                .map(|j| {
                    match (i < n_rows, j < n_cols) {
                        (true, true) => cost[i][j],
                        (true, false) => phantom_cost_row(i),
                        (false, true) => phantom_cost_col(j),
                        (false, false) => 0.0,
                    }
                })
                .collect()
        })
        .collect();

    let (total_cost, raw_assignments) = min_cost_matching_with_assignments(&padded);

    // Filter to real (non-phantom) assignments
    let assignments: Vec<(usize, usize)> = raw_assignments
        .into_iter()
        .filter(|&(r, c)| r < n_rows && c < n_cols)
        .collect();

    (total_cost, assignments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_matrix() {
        let cost: Vec<Vec<f64>> = vec![];
        let (c, a) = min_cost_matching_with_assignments(&cost);
        assert_eq!(c, 0.0);
        assert!(a.is_empty());
    }

    #[test]
    fn test_1x1() {
        let cost = vec![vec![5.0]];
        let (c, a) = min_cost_matching_with_assignments(&cost);
        assert!((c - 5.0).abs() < 1e-10);
        assert_eq!(a, vec![(0, 0)]);
    }

    #[test]
    fn test_2x2_identity() {
        // Optimal matching: (0,0)=1, (1,1)=1 -> cost 2
        // vs (0,1)=10, (1,0)=10 -> cost 20
        let cost = vec![vec![1.0, 10.0], vec![10.0, 1.0]];
        let (c, _) = min_cost_matching_with_assignments(&cost);
        assert!((c - 2.0).abs() < 1e-10);
    }

    #[test]
    fn test_3x3_known() {
        // Classic Hungarian example
        let cost = vec![
            vec![4.0, 1.0, 3.0],
            vec![2.0, 0.0, 5.0],
            vec![3.0, 2.0, 2.0],
        ];
        let (c, _) = min_cost_matching_with_assignments(&cost);
        // Optimal: (0,1)=1, (1,0)=2, (2,2)=2 -> cost 5
        assert!((c - 5.0).abs() < 1e-10);
    }

    #[test]
    fn test_rectangular_more_rows() {
        // 3 rows, 2 columns -> one row will be unmatched (phantom)
        let cost = vec![
            vec![1.0, 10.0],
            vec![10.0, 1.0],
            vec![5.0, 5.0],
        ];
        // Phantom cost for unmatched row i = 100.0
        let (c, a) = min_cost_matching_rectangular_with_assignments(
            &cost,
            &|_| 100.0,
            &|_| 100.0,
        );
        // Best: match row 0 to col 0 (1), row 1 to col 1 (1), row 2 is phantom (100)
        // Total = 1 + 1 + 100 = 102
        assert!((c - 102.0).abs() < 1e-10);
        assert_eq!(a.len(), 2); // Only 2 real assignments
    }

    #[test]
    fn test_rectangular_more_cols() {
        // 2 rows, 3 columns -> one col will be unmatched (phantom)
        let cost = vec![
            vec![1.0, 10.0, 5.0],
            vec![10.0, 1.0, 5.0],
        ];
        let (c, a) = min_cost_matching_rectangular_with_assignments(
            &cost,
            &|_| 100.0,
            &|_| 100.0,
        );
        // Best: row 0 -> col 0 (1), row 1 -> col 1 (1), col 2 phantom (100)
        assert!((c - 102.0).abs() < 1e-10);
        assert_eq!(a.len(), 2);
    }

    #[test]
    fn test_rectangular_variable_phantom() {
        // Phantom cost depends on the item
        let cost = vec![
            vec![10.0, 10.0],
            vec![10.0, 10.0],
            vec![10.0, 10.0],
        ];
        // Row 2 has phantom cost 1 (cheap to leave unmatched)
        let (c, _) = min_cost_matching_rectangular_with_assignments(
            &cost,
            &|i| if i == 2 { 1.0 } else { 100.0 },
            &|_| 100.0,
        );
        // Best: match rows 0,1 to cols 0,1 (10+10=20), row 2 phantom (1)
        // Total = 21
        assert!((c - 21.0).abs() < 1e-10);
    }

    #[test]
    fn test_matching_is_perfect() {
        // Verify that each row and column appears exactly once in assignments
        let cost = vec![
            vec![1.0, 2.0, 3.0],
            vec![4.0, 5.0, 6.0],
            vec![7.0, 8.0, 9.0],
        ];
        let (_, a) = min_cost_matching_with_assignments(&cost);
        assert_eq!(a.len(), 3);

        let mut rows: Vec<usize> = a.iter().map(|&(r, _)| r).collect();
        let mut cols: Vec<usize> = a.iter().map(|&(_, c)| c).collect();
        rows.sort();
        cols.sort();
        assert_eq!(rows, vec![0, 1, 2]);
        assert_eq!(cols, vec![0, 1, 2]);
    }

    #[test]
    fn test_zero_cost_matching() {
        let cost = vec![
            vec![0.0, 0.0],
            vec![0.0, 0.0],
        ];
        let (c, _) = min_cost_matching_with_assignments(&cost);
        assert!((c - 0.0).abs() < 1e-10);
    }
}
