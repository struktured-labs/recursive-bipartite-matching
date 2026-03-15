# CLAUDE.md

## Project Overview

Recursive Bipartite Matching (RBM) distance on game trees — a tree metric that
recursively applies minimum-cost bipartite matching (Hungarian method) to align
children at each level. Applied to poker game abstraction (Rhode Island Hold'em).

**Key idea**: the distance between two game trees is determined bottom-up from
leaf payoff differences, with structural mismatches penalized. Trees with small
distance can be merged into a compressed "EV graph" — a DAG that preserves
strategic structure. The distance itself bounds the EV error of the compression.

## Build & Run

```bash
opam exec -- dune build
opam exec -- dune exec bin/main.exe
```

## Architecture

```
lib/
├── tree.ml/mli          # Generic labeled rooted trees
├── hungarian.ml/mli     # Hungarian algorithm (min-cost bipartite matching)
├── distance.ml/mli      # Recursive bipartite matching distance
├── merge.ml/mli         # Tree merge operation
├── card.ml/mli          # Playing cards
├── hand_eval.ml/mli     # 3-card poker hand evaluation
├── rhode_island.ml/mli  # Rhode Island Hold'em game tree generator
└── rbm.ml               # Top-level library module
bin/
└── main.ml              # Demo: distance matrix, metric verification, merge
```

## Key Modules

- **Tree**: `'a t = Leaf of {value; label} | Node of {children; label}` — children are unordered
- **Distance**: recursive matching with configurable phantom penalty (`Ev | `Size | `Constant)
- **Hungarian**: O(n^3) min-cost perfect matching, handles rectangular via phantom padding
- **Merge**: combines matched children recursively, configurable phantom policy (Drop/Keep)
- **Rhode_island**: game tree generator with configurable deck size and betting structure

## Rhode Island Hold'em Rules

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
