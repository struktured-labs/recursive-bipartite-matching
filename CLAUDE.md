# CLAUDE.md

## Project Overview

Recursive Bipartite Matching (RBM) distance on game trees — a tree metric that
recursively applies minimum-cost bipartite matching (Hungarian method) to align
children at each level. Applied to poker game abstraction on both Rhode Island
Hold'em and full 2-player Limit Hold'em (52-card deck).

**Key idea**: the distance between two game trees is determined bottom-up from
leaf payoff differences, with structural mismatches penalized. Trees with small
distance can be merged into a compressed "EV graph" — a DAG that preserves
strategic structure. The distance itself bounds the EV error of the compression.

**Key results**:
- RBM beats EMD 5-0 on full Limit Hold'em preflop abstraction (up to 42% less error)
- RBM beats EMD 7-0 on Rhode Island Hold'em across all compression levels
- MCCFR bot trained on RBM abstractions defeats EMD bot head-to-head (+0.02 bb/hand)
- Online learner: 99.4% cache hit rate, ~400 postflop clusters emerge naturally
- Playable bot: `opam exec -- dune exec bin/play.exe`

## Build & Run

```bash
opam exec -- dune build
opam exec -- dune exec bin/main.exe          # Rhode Island Hold'em demo
opam exec -- dune exec bin/holdem_compare.exe # Full Hold'em RBM vs EMD
opam exec -- dune exec bin/tournament.exe     # MCCFR bot tournament
opam exec -- dune exec bin/play.exe           # Play against trained bot
opam exec -- dune exec bin/train_bot.exe      # Train bot from scratch
```

## Architecture

25 library modules, 17 executables, ~15K lines of OCaml.

```
lib/
├── tree.ml/mli              # Generic labeled rooted trees
├── hungarian.ml/mli         # Hungarian algorithm (min-cost bipartite matching)
├── distance.ml/mli          # Recursive bipartite matching distance
├── merge.ml/mli             # Tree merge operation
├── card.ml/mli              # Playing cards (52-card deck)
├── hand_eval.ml/mli         # 3-card poker hand evaluation (Rhode Island)
├── hand_eval5.ml/mli        # 5-card hand evaluation
├── hand_eval7.ml/mli        # 7-card hand evaluation (Hold'em showdown)
├── hand_iso.ml/mli          # Hand isomorphism / canonical forms
├── equity.ml/mli            # Equity calculation
├── limit_holdem.ml/mli      # Full 2-player Limit Hold'em game trees
├── mini_holdem.ml/mli       # Mini Hold'em variants
├── abstraction.ml/mli       # Game abstraction (RBM + EMD clustering)
├── cfr.ml/mli               # Counterfactual regret minimization
├── cfr_abstract.ml/mli      # CFR on abstracted games
├── emd_baseline.ml/mli      # EMD baseline (Rhode Island)
├── emd_baseline_holdem.ml/mli # EMD baseline (full Hold'em)
├── online_learner.ml/mli    # Self-play learner
├── ev_graph.ml/mli          # Agglomerative clustering → EV graph
├── locator.ml/mli           # Monte Carlo location in EV graph
├── error_bound.ml/mli       # EV error analysis
├── acpc_protocol.ml/mli     # ACPC protocol support
├── parallel.ml/mli          # Parallel computation utilities
├── rhode_island.ml/mli      # Rhode Island Hold'em game tree generator
└── rbm.ml                   # Top-level library module
bin/
├── main.ml                  # Rhode Island Hold'em pipeline demo
├── holdem_compare.ml        # Full Hold'em RBM vs EMD comparison
├── tournament.ml            # MCCFR bot tournament
├── play.ml                  # Interactive play against bot
├── train_bot.ml             # Train MCCFR bot
├── compare.ml               # Rhode Island Hold'em RBM vs EMD
├── self_play.ml             # Online learner demo
├── cfr_demo.ml              # CFR exploitability demo
├── bot_vs_bot.ml            # Head-to-head bot evaluation
├── scale_experiment.ml      # Multi-scale experiments
└── ... (17 total)
```

## Key Modules

- **Tree**: `'a t = Leaf of {value; label} | Node of {children; label}` — children are unordered
- **Distance**: recursive matching with configurable phantom penalty (`Ev | `Size | `Constant)
- **Hungarian**: O(n^3) min-cost perfect matching, handles rectangular via phantom padding
- **Merge**: combines matched children recursively, configurable phantom policy (Drop/Keep)
- **Limit_holdem**: full 2-player Limit Hold'em with 52-card deck, 4 betting rounds
- **Rhode_island**: simplified game tree generator with configurable deck size
- **Cfr / Cfr_abstract**: MCCFR on full and abstracted games
- **Abstraction**: RBM + EMD clustering pipelines

## Game Domains

### Full 2-Player Limit Hold'em (52 cards)
- 2 players, standard 52-card deck, 50 canonical preflop hands (suit isomorphism)
- 2 hole cards each, 5 community cards (flop + turn + river)
- 4 betting rounds, limit betting
- 7-card hand evaluation at showdown

### Rhode Island Hold'em
- 2 players, configurable deck (default 52, use `small_config ~n_ranks:N` for testing)
- 1 hole card each, 2 community cards (flop + turn)
- 3 betting rounds, max 3 raises each
- 3-card hand rankings: trips > straight > flush > pair > high

## Dependencies

- OCaml >= 5.2, dune >= 3.16
- Jane Street: core, core_unix, ppx_jane

## Style

- Jane Street / Core first
- `match x with true -> ... | false -> ...` (not if/then/else)
- `_exn` versions for public functions
- `.mli` files for public interfaces
- `[@@deriving sexp, compare, equal]` on types

## Python / tooling

- Use `uv` for all Python package management (never raw pip)
- AWS CLI installed via `uv tool install awscli`

## Cloud / deployment

- AWS spot instances for large-scale MCCFR training
- Strategy files saved as OCaml Marshal (.dat) — merge with bin/merge_strategies.exe
- Distributed training: each worker trains independently, merge regret sums after
