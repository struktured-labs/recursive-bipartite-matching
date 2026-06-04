I have enough. Let me return the synthesized report.

# Prior Art on Large-Scale CFR/MCCFR Infoset Storage

## Per-system summaries

### 1. Cepheus (HULHE solver) — Tammelin, Burch, Johanson, Bowling, 2015
- **Reference**: Bowling et al., *Science* 347:6218 (Jan 2015); Tammelin et al., *Solving Large Imperfect Information Games Using CFR+*, arXiv:1407.5042; ACM CACM Nov 2017 reprint.
- **Game**: Heads-Up Limit Hold'em (HULHE). Game tree ~3.16x10^14 decision points; ~1.4x10^13 (13.8T) infosets after lossless suit-isomorphism abstraction.
- **Memory**: **262 TB raw** for regret+strategy in float; **6 TB** compressed for the strategy and **11 TB** compressed for the counterfactual-value table. Distributed across **~200 compute nodes**, each holding its shard on a 1 TB local disk (32 GB RAM, 24 cores each).
- **Data structure**: Flat per-bucket arrays indexed by **Waugh hand isomorphism** (canonical integer index) and betting history. Not a hashmap — direct addressing by index range per round.
- **Numeric format**: **Fixed-point integers** (values are scaled by a constant and truncated). Then a custom entropy code over the sorted integer stream achieves a **~13:1 compression ratio**. Decompressed on-the-fly into RAM per worker for CFR+ sweeps.
- **Concurrency**: Bulk-synchronous parallel — each of the 200 nodes solves its shard, then exchanges with neighbors. No fine-grained concurrent reads/writes. Run took **70 days, 24 trillion hands**.
- **Open source**: CFR+ implementation under BSD at `https://poker.cs.ualberta.ca/cfr_plus.html` (download link from CPRG page, not GitHub).

### 2. Libratus — Brown & Sandholm, 2017 (Science 2018)
- **Reference**: Brown & Sandholm, *Superhuman AI for heads-up no-limit poker: Libratus beats top professionals*, Science 359:6374 (2018).
- **Game**: Heads-Up No-Limit Hold'em (HUNL), ~10^161 decision points raw, abstracted to ~10^12 blueprint infosets.
- **Memory**: Brief was specifically **128 GB RAM / 28 cores per node** during training, only **14 cores actually used** by the agent. **Pittsburgh Bridges supercomputer**; ~25 million core-hours total. Public papers/articles do **not** disclose the absolute bytes of the blueprint table; informal community estimates around tens of TB.
- **Data structure**: Not described in any public paper. Brown's PhD thesis (CMU CS, 2020 — *Equilibrium Finding for Large Adversarial Imperfect-Information Games*) gives the algorithms (MCCFR + sampled regret-based pruning + DCFR + subgame solving) but no schema-level systems description.
- **Concurrency**: Distributed across many nodes of Bridges; published papers do not describe the table-level concurrency. CFR uses per-iteration regret updates; standard MCCFR sharding patterns from prior CPRG work apply.
- **Key engineering lever**: **Regret-Based Pruning (RBP)**. *Reduced Space and Faster Convergence in Imperfect-Information Games via Regret-Based Pruning* (Brown & Sandholm, arXiv:1609.03234) describes **Total RBP**, which not only skips traversal of paths with very negative regret but also **deallocates their regret entries**, giving an empirical **order-of-magnitude space reduction** for large games.
- **Open source**: No. CMU declined to release.

### 3. Pluribus — Brown & Sandholm, 2019
- **Reference**: Brown & Sandholm, *Superhuman AI for multiplayer poker*, Science 365:6456 (2019); supplementary at noambrown.com/papers/19-Science-Superhuman_Supp.pdf (PDF binary, not extractable by WebFetch; pseudocode only is public).
- **Game**: 6-player No-Limit Hold'em.
- **Memory**: Blueprint trained in 8 days on a 64-core server with **<512 GB RAM**. Runtime: **<128 GB RAM, 2x E5-2695v3**, with blueprint kept in **compressed** form in memory.
- **Data structure**: Not detailed in any released artifact. Multiple unofficial GitHub re-implementations exist (apcode/pluribus-poker-AI, whatsdis/pluribus, agnarbjoernstad/Pluribus, keithlee96/pluribus-poker-AI), but they are pedagogical Python/JS ports — they do not faithfully reproduce the production data structure and run on tiny games.
- **Concurrency**: Single 64-core box for blueprint; no distributed CFR like Libratus.
- **Open source**: No official code release.

### 4. DeepStack — Moravcik et al., 2017
- **Reference**: Moravcik et al., *DeepStack: Expert-Level Artificial Intelligence in Heads-Up No-Limit Poker*, Science 356:6337 (2017), arXiv:1701.01724.
- **Game**: HUNL.
- **Architecture**: **Fundamentally avoids the infoset table problem.** Quote: "DeepStack does not compute and store a complete strategy prior to play and so has no need for explicit abstraction." Continuous re-solving via depth-limited lookahead, with a neural-network value function trained from 1M+ synthetic poker situations.
- **Memory**: Storage is the trained CFV network weights (small, GB-scale) + per-hand torch tensors in the active **Lookahead** structure (GPU when available). Per the lifrordi/DeepStack-Leduc tutorial: "A Lookahead efficiently stores data at the node and action level using torch tensors. When possible, tensors will be stored on the GPU."
- **Data structure**: Per-resolve dense tensors; no global infoset hashmap. Paper notes the *implicit* full-game infoset count is **~2x10^10 needing ~80 GB** if you wanted to materialize it.
- **Open source**: `lifrordi/DeepStack-Leduc` (Lua/Torch, Leduc only). HUNL extensions exist as `godmoves/DeeperStack` and `aikupoker/deeper-stacker`. Last activity on the original repo is years old.

### 5. Slumbot 2017/2019 — Eric Jackson
- **Reference**: Jackson, *Slumbot NL: Solving Large Games with CFR Using Sampling and Distributed Processing*, AAAI Workshop on Computer Poker 2013; *Targeted CFR* (Jackson 2017); *Compact CFR* (Jackson, AAAI WS, ~2016/17).
- **Game**: HUNL.
- **Memory**: 250,000 core-hours, 2 TB aggregate RAM, **distributed disk-based CFR**. Key Jackson quote: "maintain the regrets and accumulated strategy on disk, rather than in memory, and distribute processing across multiple machines."
- **Data structure** (from direct read of `slumbot2019/src/`):
  - `DiskProbs` class: per-`[player][street][nonterminal_id]` **byte offsets** into per-shard binary files named `sumprobs.x.0.0.<street>.<iter>.p<player>.<suffix>`. Suffix encodes element width: `c` = u8, `s` = u16, `i` = i32, `d` = f64. Lookups are `Reader::SeekTo(offsets_[player][street][nt] + bucket * num_succs * prob_size)` — direct file I/O, not mmap, not a hashmap.
  - `CFRStreetValues<T>` (template over `u8`/`u16`/`i32`/`f64`): 3D `data_[player][nonterminal][holding * num_succs + succ]`. Lazy per-nonterminal allocation.
  - `Quantize()` reduces full-precision regrets/sumprobs to `u8` at load time, scaling to 256 buckets such that quantized probs sum to exactly 255.
  - `fast_hash.cpp`: just standalone `fasthash32`/`fasthash64` *functions* (Merkle-Damgard); not a hash table.
- **Compact CFR** (the published memory-shrinking technique): quantize regrets to small ints (often u8 or u16) at the cost of some quality. Combined with disk-based sweeps, this lets HUNL run on ordinary-RAM commodity nodes.
- **Concurrency**: Single-writer per shard; distributed across machines, sweeps coordinated externally.
- **Open source**: `github.com/ericgjackson/slumbot2019` — MIT, C++, 54+ commits. Maintained: the repo includes a TODO header for "Disk-Based CFR+" still labeled TODO, suggesting the disk path from the 2017 paper is partly documented but not fully cleaned up.

### 6. ReBeL — Brown, Bakhtin, Lerer, Gong, 2020 (FAIR/CMU)
- **Reference**: Brown et al., *Combining Deep Reinforcement Learning and Search for Imperfect-Information Games*, NeurIPS 2020, arXiv:2007.13544.
- **Game**: Poker (HUNL) + Liar's Dice + general framework.
- **Data structure**: Core state is the **Public Belief State (PBS)** — a dual distribution over the players' private hands at a public node. No global infoset hashmap is materialized. Value/policy nets generalize over PBSs.
- **Memory**: Implementation is C++ (`csrc/liars_dice/`, 73.9%) for data generation + Python (`cfvpy/selfplay.py`, 24.5%) training loop. Replay buffers + neural net weights, not a flat regret table.
- **Concurrency**: Standard self-play RL — workers generate trajectories, learners consume. PyTorch level.
- **Open source**: `facebookresearch/rebel` — MIT, Liar's Dice only (no HUNL release for legal reasons).

### 7. University of Alberta CPRG — Open Pure CFR, Open CFR, CFR+
- **Reference**: Gibson 2014 PhD thesis; CPRG project pages.
- **Open Pure CFR** (`rggibson/open-pure-cfr`, C++, BSD, last release **v1.0 Aug 2 2013**, 35 commits): The header `entries.hpp` makes it concrete — `Entries_der<T>` is a **flat `T*` array** allocated with `calloc(total_num_entries, sizeof(T))`, indexed by `get_entry_index(bucket, soln_idx)`. `T` is one of `uint8_t`, `int`, `uint32_t`, `uint64_t`. Preflop sumprobs use `int64_t`; everywhere else `int32_t`. **All RAM, no mmap, no hash table.** Pure CFR halves memory vs vanilla by using ints not doubles.
- **Open CFR** (Kevin Waugh, Leduc only, BSD).
- **CFR+** (Cepheus, BSD) — see Cepheus section above.
- **Hand isomorphism** (`kdub0/hand-isomorphism`, C, MIT): Provides a **perfect-hash-like canonical index** over isomorphic poker hands. This is the dense-indexing primitive Cepheus and Open Pure CFR build on, eliminating the need for a key hashmap at the *hand* level.

### 8. Other systems briefly
- **PioSolver / GTO+** (commercial subgame solvers): full tree in RAM during a solve; `.cfr` save files. GTO+ recomputes later streets on demand to keep files in the hundreds-of-KB range vs PioSolver's hundreds of MB. Subgame-scoped; not full-game blueprints.
- **Deep CFR** (Brown et al. 2019, ICML): replay buffer + two neural nets (advantage, average policy). Reservoir sampling. Replaces the infoset table with NN inference — same architectural choice as DeepStack/ReBeL.

## Cross-cutting lessons

1. **Almost nobody publishes the systems-level schema.** The CFR papers cover algorithms; the only place a real on-disk layout shows up is Slumbot's source (read directly above) and Cepheus's compression description.

2. **Direct addressing via canonical hand indices beats a u64 hashmap when you can afford it.** Cepheus, Open Pure CFR, and Slumbot all index by `[player][nonterminal][bucket * n_actions + a]`. No hash, no MPHF — a flat array with a deterministic perfect-hash-like layout courtesy of Waugh's hand isomorphism + the fixed betting tree.

3. **Quantization dominates.** Cepheus: int+entropy code, ~13:1. Slumbot: u8 quantized sumprobs, sums to 255. Open Pure CFR: ints not doubles, 2x savings. None use bf16/f32 in production. Your u16 epoch and f32 arenas are already on this track.

4. **Disk-backed CFR is precedented and works.** Slumbot (2013-onwards) is the canonical citation for "store regrets on disk, sweep them in." It uses **per-shard binary files indexed by offset table** (not mmap, not hashmaps, just `pread`/`SeekTo`). This is the cheapest possible architecture and the closest analog to your LSM-frozen-layers idea.

5. **Pruning shrinks the table itself, not just compresses entries.** Total RBP (Brown & Sandholm NIPS-15) **deallocates** entries on actions with deeply negative regret. Order-of-magnitude space win in HUNL. None of the public CFR table layouts you'd see in Cepheus or Slumbot do this — it's a Libratus-internal innovation.

6. **NN-as-value-function architectures sidestep the problem.** DeepStack/ReBeL/Deep CFR don't have a billion-infoset table at all. They have a value net + per-resolve dense tensors. This is the only published path that scales without disk-backed storage. Not useful for you given the project mandate (no NN-as-bucket) but worth noting as the only paper-quality "way around" the wall.

7. **Open-source CFR code at HUNL scale is rare and old.** `rggibson/open-pure-cfr` (2013), `ericgjackson/slumbot2019` (active but lightly documented), `lifrordi/DeepStack-Leduc` (Leduc only). No maintained Rust equivalent exists in the literature search. You'd be writing the first one.

## What you should steal

**For the immediate 1B-iter target:** Stay with your per-thread `FxHashMap` + LSM-frozen-layer + BBHash design. It is **architecturally identical to Slumbot's disk-backed CFR**, but with two improvements Slumbot doesn't have: (a) explicit MPHF over the u64 key (Slumbot avoids needing this only because its keys are precomputable from the static game tree — you don't get that luxury because RBM buckets are dynamic), and (b) mmap-backed flat arenas instead of `pread` (better OS page cache behavior under 32 readers x 8 lookups/iter).

**For 5B-10B:** Two ideas from prior art are immediately worth porting:

- **Cepheus-style fixed-point + entropy-coded frozen layers.** Quantize your offsets table (the 8-byte u64 key + offset + n_actions + epoch entry, ~24-32 bytes) by delta-encoding sorted keys within each frozen layer. Slumbot's 4-format file suffix scheme (`c`/`s`/`i`/`d`) is the right pattern: write the smallest representation that round's accuracy permits, **picked per-layer at freeze time**.
- **Total-RBP-style pruning at freeze.** When a frozen layer rolls in, drop entries whose absolute cumulative regret is below threshold relative to the action's siblings. Brown reports order-of-magnitude space wins. This is the largest single lever in the prior art that you are not yet using.

**For 10B:** Lean harder on **canonical indexing**. Your u64 key includes "postflop RBM bucket + board bucket + betting history." If you can make the betting-history component a **dense int** over the fixed action abstraction (a la Slumbot's `nonterminal_id`) and the bucket component a **dense int** over the (currently dynamic) RBM cluster ID, then the working set per `[round][nonterminal]` collapses to a flat `n_buckets * n_actions` array — same architecture as Cepheus/Slumbot, no hashmap needed, mmap-friendly, page-locality-perfect. The cost is freezing the bucket-ID assignment after the cluster-discovery phase so IDs stay dense. This is the single biggest architectural win in the historical literature and is the path Cepheus, Slumbot, and Open Pure CFR all converged on.

Sources:
- [Cepheus: Heads-Up Limit Hold'em Poker Is Solved (CACM 2017)](http://webdocs.cs.ualberta.ca/~games/poker/publications/heads-up_limit_poker_is_solved.acm2017.pdf)
- [Solving Large Imperfect Information Games Using CFR+ (Tammelin et al., arXiv:1407.5042)](https://arxiv.org/pdf/1407.5042)
- [CPRG CFR+ project page](https://poker.cs.ualberta.ca/cfr_plus.html)
- [Open Pure CFR project page](https://poker.cs.ualberta.ca/open_pure_cfr.html)
- [rggibson/open-pure-cfr (GitHub)](https://github.com/rggibson/open-pure-cfr)
- [Libratus: Superhuman AI for heads-up no-limit poker (Science 2018)](https://www.science.org/doi/10.1126/science.aao1733)
- [Brown & Sandholm — Reduced Space and Faster Convergence via RBP (arXiv:1609.03234)](https://arxiv.org/pdf/1609.03234)
- [Brown & Sandholm — Regret-Based Pruning NIPS-15](https://www.cs.cmu.edu/~sandholm/regret-basedPruning.nips15.withAppendix.pdf)
- [Noam Brown PhD page (CMU CSD)](https://www.csd.cmu.edu/academics/doctoral/degrees-conferred/noam-brown)
- [Pluribus: Superhuman AI for Multiplayer Poker (KDnuggets summary)](https://www.kdnuggets.com/2019/08/inside-pluribus-facebooks-new-ai-poker.html)
- [Pluribus supplementary materials (PDF, Noam Brown)](https://noambrown.com/papers/19-Science-Superhuman_Supp.pdf)
- [DeepStack: Expert-Level AI in HUNL (arXiv:1701.01724)](https://arxiv.org/pdf/1701.01724)
- [lifrordi/DeepStack-Leduc (GitHub)](https://github.com/lifrordi/DeepStack-Leduc)
- [Slumbot NL: Solving Large Games with CFR (AAAI WS, PDF)](https://cdn.aaai.org/ocs/ws/ws0979/7044-30516-1-PB.pdf)
- [ericgjackson/slumbot2019 (GitHub)](https://github.com/ericgjackson/slumbot2019)
- [ReBeL: Combining Deep RL and Search for Imperfect-Info Games (arXiv:2007.13544)](https://arxiv.org/pdf/2007.13544)
- [facebookresearch/rebel (GitHub)](https://github.com/facebookresearch/rebel)
- [Brown et al. — Deep CFR (ICML 2019)](https://proceedings.mlr.press/v97/brown19b/brown19b.pdf)
- [Brown & Sandholm — Discounted CFR (arXiv:1809.04040)](https://arxiv.org/pdf/1809.04040)
- [Waugh — A Fast and Optimal Hand Isomorphism Algorithm](https://www.cs.cmu.edu/~waugh/publications/isomorphism13.pdf)
- [kdub0/hand-isomorphism (GitHub)](https://github.com/kdub0/hand-isomorphism)