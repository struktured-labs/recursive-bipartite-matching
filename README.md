# Recursive Bipartite Matching Distance on Game Trees

A tree distance metric via recursive minimum-cost bipartite matching (Hungarian method), with application to extensive-form game abstraction. The distance captures **structural similarity** between game trees — not just expected values, but the shape of the decision landscape that produces them.

## Key Results

**Theoretical:**
- The RBM distance is a **metric** (identity, symmetry, triangle inequality) when the leaf distance is a metric ([proof](WRITEUP.md#91-theorem-the-rbm-distance-is-a-metric))
- Merging two trees at distance `d` introduces EV error **at most `d/2`** (tight at leaves, strictly better at branching nodes) ([proof](WRITEUP.md#92-theorem-ev-error-bound-under-merging))

**Empirical (Rhode Island Hold'em):**
- **RBM beats EMD 7-0** across compression levels on varied-community deals. EMD (the standard poker AI metric from Gilpin & Sandholm 2006) produces 30x more EV error than RBM at the same cluster count
- Zero-error compression at 30x on structurally identical deals
- Online self-play learner discovers natural game clusters by game 100 with 99.5% cache hit rate by game 600
- All metric properties verified on 753K+ triples

## How It Works

Given two rooted trees, the distance is computed bottom-up:

1. **Leaves**: distance = `|payoff_1 - payoff_2|`
2. **Internal nodes**: build a cost matrix between children (recursive distances), solve the min-cost bipartite matching via Hungarian algorithm. Unmatched children incur a phantom penalty.
3. The matching cost at the root is the tree distance.

Trees with small distance can be **merged** (aligned children are recursively merged, leaf values averaged), producing a compressed **EV graph** — a DAG where structurally similar game states share a single representative.

```
Tree A          Tree B          Distance = optimal matching cost
  /|\             /|\
 / | \           / | \
a  b  c         d  e  f    →   min-cost matching: (a↔e, b↔d, c↔f)
5  3  8         4  6  7         cost = |5-6| + |3-4| + |8-7| = 4
```

## Build & Run

Requires OCaml >= 5.2 with Jane Street Core libraries.

```bash
# Install dependencies
opam install core core_unix ppx_jane

# Build everything
opam exec -- dune build

# Run the main demo (4-rank RI Hold'em, distance matrix, compression, metrics)
opam exec -- dune exec bin/main.exe

# Run RBM vs EMD head-to-head comparison (~5s)
opam exec -- dune exec bin/compare.exe

# Run online self-play learner
opam exec -- dune exec bin/self_play.exe
```

## Project Structure

```
lib/
├── tree.ml/mli            # Generic labeled rooted trees (unordered children)
├── hungarian.ml/mli       # O(n^3) min-cost bipartite matching
├── distance.ml/mli        # Recursive bipartite matching distance
├── merge.ml/mli           # Tree merge operation via matching alignment
├── ev_graph.ml/mli        # Agglomerative clustering → compressed EV graph
├── locator.ml/mli         # Monte Carlo sampling location in EV graph
├── error_bound.ml/mli     # EV error analysis + distance-based bound verification
├── emd_baseline.ml/mli    # EMD baseline (Gilpin/Sandholm hand-strength abstraction)
├── online_learner.ml/mli  # Self-play learner with incremental EV graph construction
├── card.ml/mli            # Playing cards
├── hand_eval.ml/mli       # 3-card poker hand evaluation
├── rhode_island.ml/mli    # Rhode Island Hold'em game tree generator
└── rbm.ml                 # Top-level library re-exports

bin/
├── main.ml                # Full pipeline demo (distance, compression, metrics)
├── compare.ml             # RBM vs EMD vs scalar-EV head-to-head comparison
└── self_play.ml           # Online self-play learner convergence demo

WRITEUP.md                 # Full theoretical writeup (~1000 lines):
                           #   distance definition, merge, poker application,
                           #   location problem, prior art, sampling approach,
                           #   online learning, formal proofs, open questions
```

## Rhode Island Hold'em

The test domain is [Rhode Island Hold'em](https://www.cs.cmu.edu/~sandholm/RIHoldEm.ISD.aaai05proceedings.pdf) (Gilpin & Sandholm 2005): a simplified poker variant designed for AI research.

- 2 players, configurable deck (use `small_config ~n_ranks:N` for testing)
- 1 hole card each, 2 community cards (flop + turn)
- 3 betting rounds, max 3 raises each, limit betting
- 3-card hand rankings: trips > straight > flush > pair > high card

## The Location Problem

Building the compressed EV graph offline is one thing — finding yourself in it during live play is another. The equivalence classes are defined by global subtree structure, so locating your position requires comparing your continuation tree against cluster representatives. This is O(K * n^2) per decision point.

The online learning approach sidesteps this: build the graph incrementally through self-play, so you always know where you are (you built the graph from your position). The RBM distance serves as a **generalization kernel** — states with similar tree structure share strategies with bounded error.

## Prior Art & Novelty

**Existing work** on matching-based tree distances (Zhang 1996, Kuboyama 2007) and game abstraction (Gilpin/Sandholm 2006, Kroer/Sandholm 2014-2018) exists independently. The gap this project fills:

1. Using a full recursive tree distance as the abstraction metric for extensive-form games
2. Proving that the distance directly bounds the EV error of compression
3. Identifying the location problem as the fundamental complexity barrier
4. The online learning formulation that dissolves the location problem

See [WRITEUP.md](WRITEUP.md) for the full theoretical treatment, proofs, and prior art survey.

## License

MIT
