# Recursive Bipartite Matching Distance on Game Trees

A tree distance metric via recursive minimum-cost bipartite matching (Hungarian method), with application to extensive-form game abstraction. The distance captures **structural similarity** between game trees — not just expected values, but the shape of the decision landscape that produces them.

## Key Results

**Theoretical:**
- The RBM distance is a **metric** (identity, symmetry, triangle inequality) when the leaf distance is a metric ([proof](WRITEUP.md#101-theorem-the-rbm-distance-is-a-metric))
- Merging two trees at distance `d` introduces EV error **at most `d/2`** (tight at leaves, strictly better at branching nodes) ([proof](WRITEUP.md#102-theorem-ev-error-bound-under-merging))

**Empirical (Full 2-Player Limit Hold'em, 52-card deck):**
- **RBM beats EMD 5-0** on preflop abstraction quality across all compression levels (50 canonical hands):

| Clusters (k) | RBM Error | EMD Error | RBM Advantage |
|:---:|:---:|:---:|:---:|
| 25 | 0.25 | 0.43 | 42% less error |
| 15 | 0.37 | 0.43 | 14% less error |
| 10 | 0.40 | 0.51 | 22% less error |
| 5 | 0.60 | 0.69 | 13% less error |
| 3 | 0.62 | 0.71 | 13% less error |

- **MCCFR head-to-head**: RBM bot beats EMD bot by +0.02 bb/hand over 20K position-alternated hands
- All MCCFR bots beat random (+1.12 to +1.24 bb/h) and always-call (+0.11 to +0.30 bb/h)
- Online learner: 99.4% cache hit rate, 60x faster than offline, ~400 postflop clusters emerge naturally
- Play against the bot: `opam exec -- dune exec bin/play.exe`

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

# Run full Limit Hold'em RBM vs EMD comparison (52-card deck)
opam exec -- dune exec bin/holdem_compare.exe

# Run MCCFR bot tournament (RBM vs EMD vs random vs always-call)
opam exec -- dune exec bin/tournament.exe

# Play against the trained bot interactively
opam exec -- dune exec bin/play.exe

# Train a bot from scratch
opam exec -- dune exec bin/train_bot.exe

# Run online self-play learner
opam exec -- dune exec bin/self_play.exe
```

## Project Structure

25 library modules, 17 executables, ~15K lines of OCaml.

```
lib/
├── tree.ml/mli              # Generic labeled rooted trees (unordered children)
├── hungarian.ml/mli         # O(n^3) min-cost bipartite matching
├── distance.ml/mli          # Recursive bipartite matching distance
├── merge.ml/mli             # Tree merge operation via matching alignment
├── ev_graph.ml/mli          # Agglomerative clustering → compressed EV graph
├── locator.ml/mli           # Monte Carlo sampling location in EV graph
├── error_bound.ml/mli       # EV error analysis + distance-based bound verification
├── emd_baseline.ml/mli      # EMD baseline (RI Hold'em hand-strength abstraction)
├── emd_baseline_holdem.ml/mli # EMD baseline for full Limit Hold'em
├── online_learner.ml/mli    # Self-play learner with incremental EV graph construction
├── card.ml/mli              # Playing cards (52-card deck support)
├── hand_eval.ml/mli         # 3-card poker hand evaluation (Rhode Island)
├── hand_eval5.ml/mli        # 5-card poker hand evaluation
├── hand_eval7.ml/mli        # 7-card poker hand evaluation (Hold'em showdown)
├── hand_iso.ml/mli          # Hand isomorphism / canonical forms
├── equity.ml/mli            # Equity calculation (rollout-based)
├── limit_holdem.ml/mli      # Full 2-player Limit Hold'em game trees
├── mini_holdem.ml/mli       # Mini Hold'em variants for testing
├── abstraction.ml/mli       # Game abstraction (RBM + EMD clustering)
├── cfr.ml/mli               # Counterfactual regret minimization
├── cfr_abstract.ml/mli      # CFR on abstracted games
├── acpc_protocol.ml/mli     # ACPC protocol support
├── parallel.ml/mli          # Parallel computation utilities
├── rhode_island.ml/mli      # Rhode Island Hold'em game tree generator
└── rbm.ml                   # Top-level library re-exports

bin/
├── main.ml                  # Full pipeline demo (distance, compression, metrics)
├── compare.ml               # RBM vs EMD comparison (Rhode Island Hold'em)
├── holdem_compare.ml         # RBM vs EMD comparison (full Limit Hold'em)
├── tournament.ml            # MCCFR bot tournament (RBM vs EMD vs baselines)
├── play.ml                  # Interactive play against trained bot
├── train_bot.ml             # Train MCCFR bot from scratch
├── self_play.ml             # Online self-play learner convergence demo
├── cfr_demo.ml              # CFR exploitability demo
├── bot_vs_bot.ml            # Head-to-head bot evaluation
├── scale_experiment.ml      # Multi-scale RBM vs EMD experiments
├── phase1.ml                # Phase 1 abstraction pipeline
├── phase2.ml                # Phase 2 abstraction pipeline
├── bench_is.ml              # Information set benchmarking
├── test_holdem.ml           # Hold'em test suite
├── test_equity.ml           # Equity calculation tests
├── test_acpc.ml             # ACPC protocol tests
└── acpc_bot.ml              # ACPC-compatible bot

WRITEUP.md                   # Full theoretical writeup with experimental results
docs/paper.tex               # Academic paper (LaTeX)
```

## Test Domains

### Full 2-Player Limit Hold'em (52-card deck)

The primary evaluation domain: heads-up Limit Texas Hold'em with a standard 52-card deck. This is the same game solved by Bowling et al. (2015) and is the benchmark for poker AI abstraction. 50 canonical preflop hands (after suit isomorphism), 4 betting rounds, 7-card hand evaluation at showdown.

### Rhode Island Hold'em

A simplified poker variant for rapid prototyping: [Rhode Island Hold'em](https://www.cs.cmu.edu/~sandholm/RIHoldEm.ISD.aaai05proceedings.pdf) (Gilpin & Sandholm 2005).

- 2 players, configurable deck (use `small_config ~n_ranks:N` for testing)
- 1 hole card each, 2 community cards (flop + turn)
- 3 betting rounds, max 3 raises each, limit betting
- 3-card hand rankings: trips > straight > flush > pair > high card

## The Location Problem

Building the compressed EV graph offline is one thing — finding yourself in it during live play is another. The equivalence classes are defined by global subtree structure, so locating your position requires comparing your continuation tree against cluster representatives. This is O(K * n^2) per decision point.

The online learning approach sidesteps this: build the graph incrementally through self-play, so you always know where you are (you built the graph from your position). The RBM distance serves as a **generalization kernel** — states with similar tree structure share strategies with bounded error.

## Prior Art & Novelty

**Existing work** on matching-based tree distances (Zhang 1996, Kuboyama 2007) and game abstraction (Gilpin/Sandholm 2006, Kroer/Sandholm 2014-2018, Bowling et al. 2015) exists independently. The gap this project fills:

1. Using a full recursive tree distance as the abstraction metric for extensive-form games
2. Proving that the distance directly bounds the EV error of compression
3. Identifying the location problem as the fundamental complexity barrier
4. The online learning formulation that dissolves the location problem

See [WRITEUP.md](WRITEUP.md) for the full theoretical treatment, proofs, and prior art survey.

## License

MIT
