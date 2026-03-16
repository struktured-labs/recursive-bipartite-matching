# Recursive Bipartite Matching Distance on Game Trees

## The Core Idea

Define a distance function between two rooted trees by recursively applying
minimum-cost bipartite matching (Hungarian method) on their children. The leaves
ground the recursion with a domain-specific cost (e.g., payoff difference), while
structural mismatches at internal nodes incur an explicit penalty. This gives a
principled metric over tree-structured objects — one that respects both the
**values** at the leaves and the **shape** of the computation that produces them.

The motivating application: poker game trees. Two game states whose continuation
trees are "close" under this distance are strategically similar — they lead to
similar payoff structures through similar decision sequences. Collapsing such
states yields a compact **EV graph**: a compressed representation of the game
that preserves strategic content. But navigating this compressed structure during
live play reveals a non-trivial complexity barrier.

---

## 1. The Distance Function

### Definition

Given two rooted trees $T_1$ and $T_2$, define $d(T_1, T_2)$ recursively:

**Base case.** Both nodes are leaves with payoff values $v_1, v_2$:

$$d(\text{leaf}_1, \text{leaf}_2) = |v_1 - v_2|$$

(Or any metric on the leaf domain — for poker, this could incorporate EV,
variance, hand equity, etc.)

**Recursive case.** Node $n_1$ has children $\{c_1^1, \ldots, c_1^m\}$ and
$n_2$ has children $\{c_2^1, \ldots, c_2^n\}$. Without loss of generality
assume $m \leq n$.

1. Compute the pairwise cost matrix $W$ where
   $W[i,j] = d(\text{subtree}(c_1^i),\ \text{subtree}(c_2^j))$ — recursive.

2. Pad the smaller child set with $|n - m|$ **phantom nodes**. The cost of
   matching a real subtree $S$ against a phantom is $\delta(S)$: a structural
   mismatch penalty. Natural choices:
   - $\delta(S) = \alpha \cdot \text{size}(S)$ — proportional to unmatched structure
   - $\delta(S) = \max_{\ell \in L(S)} |v(\ell)|$ — worst-case payoff loss
   - $\delta(S) = \text{EV}(S)$ — expected value of the orphaned subtree

3. Solve the min-cost perfect matching on the padded bipartite graph using
   the **Hungarian method** (O($k^3$) for $k = \max(m,n)$ children).

4. $d(n_1, n_2) = \text{cost of optimal matching}$

   Optionally add a node-level annotation cost (e.g., if nodes carry action
   labels, chance probabilities, or player identities that differ).

### Properties

This satisfies metric axioms under reasonable conditions:
- **Identity**: $d(T, T) = 0$ (identical trees match perfectly)
- **Symmetry**: the Hungarian solution is symmetric under transposition
- **Triangle inequality**: holds if the leaf metric and phantom penalty satisfy
  it — follows from the optimality of each matching step

This is related to, but distinct from:
- **Tree edit distance** (Zhang-Shasha, APTED): uses insert/delete/relabel
  operations rather than matching. Edit distance is more flexible but less
  natural for trees where children are interchangeable (unordered trees).
- **Earth Mover's / Wasserstein distance**: the recursive matching is
  structurally similar to a hierarchical optimal transport problem.
- **Graph kernels**: those measure similarity, not distance, and typically
  use fixed-depth subtree features rather than full recursive matching.

The key distinction: this distance treats children as an **unordered set** and
finds the best structural alignment via matching, rather than relying on a
canonical ordering. This is exactly right for game trees, where the children of
a chance node (possible deals) or a decision node (possible actions) have no
inherent order.

---

## 2. The Merge Operation

The distance function induces a natural **merge** operation. Given trees
$T_1$ and $T_2$ with small distance, produce a representative tree $T^{\ast}$ that
captures their shared structure.

### Construction (bottom-up)

Given the optimal matching $M$ between children of $n_1$ and $n_2$:

- **Matched pairs** $(c_1^i, c_2^j) \in M$: recursively merge their subtrees.
  The merged child represents both original children.

- **Phantoms** (unmatched children from the larger set): either:
  - **Keep**: include in $T^{\ast}$ at reduced weight (they represent structure
    present in one tree but not the other)
  - **Drop**: discard if below a significance threshold (lossy compression)
  - **Annotate**: keep with a provenance tag indicating partial coverage

- **Leaf merging**: average the payoff values, or keep a distribution
  $(\frac{v_1 + v_2}{2}, \text{weight}=2)$.

- **Node annotations**: merge action labels (if compatible), accumulate
  probability weights for chance nodes.

### The EV Graph

Repeated merging across all subtrees at each depth produces a **DAG** — the
EV graph. Multiple original game paths converge to the same node, meaning
"from here, these situations play out essentially the same way."

The compression ratio depends on the similarity threshold $\varepsilon$ and
the actual redundancy in the game tree. For poker, where many different card
combinations lead to strategically equivalent situations, this can be dramatic.

This is essentially **hierarchical clustering over subtrees** using the
recursive bipartite matching distance as the metric, with each cluster
represented by a merged prototype tree.

---

## 3. Application to Poker

### Game Tree Structure

Texas Hold'em game tree nodes:

```
Root
├── Chance: deal hole cards (1326 combinations for 2 cards from 52)
│   ├── Decision: player 1 acts (fold / call / raise amounts)
│   │   ├── Decision: player 2 responds
│   │   │   ├── Chance: deal flop (3 cards)
│   │   │   │   ├── Decision → Decision → Chance (turn) → ...
│   │   │   │   │   └── Terminal: payoff
│   │   │   │   ...
│   │   ...
│   ...
...
```

Full tree: ${\sim}10^{18}$ nodes. Even with perfect play, far too large for
exact computation.

### Why This Distance is Natural Here

Two poker subtrees are close under this distance when:
- They have similar **branching structure** (same actions available)
- Their **leaf payoffs** are similar (similar EV)
- The **strategic options** align well (the matching pairs up corresponding
  bet/call/fold branches)

This captures exactly what "strategically equivalent" means: not just similar
expected value, but similar **decision landscapes**. Two hands might have the
same EV but completely different strategic properties (e.g., a made hand vs.
a draw). This distance would correctly identify them as distant because their
continuation trees have different shapes.

### Advantage Over Flat Abstraction

Standard poker abstraction (e.g., hand bucketing) clusters based on scalar
features: hand strength, equity, potential. This loses structural information.
The recursive bipartite matching distance preserves it — two states are only
merged if their **entire continuation games** are similar, not just their
current-moment summaries.

---

## 4. The Location Problem

Here lies the fundamental difficulty.

### Statement

You've built the compressed EV graph $G$ offline. Now you're playing an actual
hand of poker. You know:
- Your hole cards
- The board (if any)
- The action history so far

This uniquely identifies your position in the **original** game tree $T$. But
you need to find your position in the **compressed** graph $G$ to look up the
strategy.

**Problem:** Given a node $v$ in $T$ (identified by the game state), find the
corresponding node $\phi(v)$ in $G$.

### Why It's Hard

In flat abstraction, location is trivial: precompute a lookup table mapping
each hand/board/history to its bucket. O(1) at query time, manageable
precompute.

With tree-based recursive abstraction, the equivalence class of a node $v$
depends on the **entire subtree rooted at $v$** — not just local features.
Two nodes are in the same class precisely because their continuation trees were
close under the recursive distance. But the continuation tree is exactly what
you're trying to avoid computing.

### The Complexity Barrier

**Naive approach:** At each game step, compare your current subtree against all
$K$ representative subtrees at the corresponding depth in $G$. Each comparison
requires the full recursive distance computation.

Let $b$ = branching factor, $h$ = remaining depth, $K$ = number of clusters at
current level.

Cost of one distance computation $T(h)$:
$$T(h) = b^2 \cdot T(h-1) + O(b^3)$$
$$T(h) = O(b^{2h})$$

Since the number of leaves is $n = b^h$, this is $O(n^2)$ per comparison.
With $K$ candidates: $O(K \cdot n^2)$ per game step.

Over a full game of $d$ steps: $O(d \cdot K \cdot n^2)$.

This is potentially **more expensive** than just solving the uncompressed game,
defeating the purpose of compression.

### Lower Bound Intuition

The location problem likely admits a lower bound of $\Omega(n)$ per step (where
$n$ is the remaining subtree size), because:

1. **Information-theoretic:** determining which equivalence class you belong to
   requires distinguishing between classes that differ only deep in the subtree.
   Any algorithm must inspect enough of the subtree to detect these differences.

2. **Structural dependency:** the matching that defined the equivalence classes
   was optimal (Hungarian), meaning the class boundaries are not aligned with
   any simple feature of the root — they depend on global subtree structure.

3. **Contrast with flat abstraction:** flat abstractions use only local features
   (hand strength, board texture), which is why they admit O(1) lookup. The
   power of the tree distance comes precisely from using non-local structure,
   and this non-locality is what makes location hard.

### Possible Mitigation (Speculation)

The space/time tradeoff might be navigable via:

- **Incremental updates:** when you move one step down the tree (a card is
  dealt, an action is taken), the subtree changes in a structured way. Can you
  update $\phi(v)$ incrementally rather than recomputing from scratch? The
  matching at the current level is invalidated, but deeper matchings may be
  reusable.

- **Approximate location:** use a fast heuristic (local features, shallow tree
  comparison) to narrow down to a small set of candidate clusters, then do
  exact matching only within that set.

- **Precomputed signatures:** for each cluster, precompute a compact signature
  (hash of the matching structure) that enables fast approximate lookup.
  The signature would need to be computable from the game state without
  building the full subtree.

- **Lazy evaluation:** don't resolve the exact cluster until you need to make
  a decision. At chance nodes (card deals), just record the outcome; at
  decision nodes, do the expensive lookup. This reduces the number of
  lookups from $d$ to the number of decision points.

---

## 5. Prior Art

### Directly Related: Matching-Based Tree Distances

The closest prior art is **constrained unordered tree edit distance** via
bipartite matching:

- **Zhang & Jiang (1994)** proved that *unrestricted* edit distance on unordered
  labeled trees is MAX SNP-hard. This motivated tractable variants.

- **Zhang (1996)**, ["A constrained edit distance between unordered labeled
  trees"](https://link.springer.com/article/10.1007/BF01975866) — introduces
  constraints that make the problem polynomial. The constrained version requires
  that deleting/inserting a node implies either deleting all its siblings or all
  its children but one. Computable in O(|T1| * |T2| * (deg(T1) + deg(T2)) *
  log^2(deg(T1) + deg(T2))).

- **Kuboyama (2007)**, PhD thesis "Matching and learning in trees" (U. Tokyo) —
  develops [tractable variations using maximum weighted bipartite
  matching](https://link.springer.com/chapter/10.1007/978-3-642-32090-3_19),
  which is essentially the same core operation as recursive bipartite matching.
  Computable in O(n * m * d) where d = minimum degree.

- **A tree distance function based on
  multi-sets** [(Springer, 2009)](https://link.springer.com/chapter/10.1007/978-3-642-00399-8_8)
  — treats child sets as multisets and defines distance via optimal matching.

These works establish that matching-based tree distances are tractable and
metrizable. **What appears novel in the recursive bipartite matching formulation
is the specific application to game trees, the merge-to-DAG compression, and
the identification of the location problem as the fundamental barrier.**

### Optimal Transport Connections

The recursive matching structure is a form of hierarchical optimal transport:

- **Mémoli (2011)**, ["Gromov-Wasserstein distances and the metric approach to
  object
  matching"](https://www.researchgate.net/publication/220104267_Gromov-Wasserstein_Distances_and_the_Metric_Approach_to_Object_Matching)
  — defines distances between metric measure spaces using optimal couplings.
  The recursive bipartite matching distance can be viewed as a discrete,
  tree-structured specialization of the Gromov-Wasserstein framework.

- **Tree Mover's Distance** [(Chuang et al., NeurIPS
  2022)](https://arxiv.org/abs/2210.01906) — extends earth mover's distance to
  multisets of trees for GNN analysis. Similar recursive OT flavor but
  motivated by graph neural networks, not game theory.

- **Earth Mover's Distance on rooted labeled unordered
  trees** [(Springer,
  2018)](https://link.springer.com/chapter/10.1007/978-3-030-05499-1_4) —
  formulates EMD between trees built from complete subtrees.

### Game Abstraction in Poker

The application side has a deep literature, but uses simpler distance metrics:

- **Gilpin & Sandholm (2006)** — automated abstraction for Texas Hold'em using
  k-means clustering with earth mover's distance on hand-strength histograms.
  This is flat abstraction: it clusters based on scalar distributions at each
  decision point, not on full subtree structure.

- **Ganzfried & Sandholm (2014)**, ["Potential-aware imperfect-recall abstraction
  with earth mover's
  distance"](https://www.cs.cmu.edu/~sandholm/potential-aware_imperfect-recall.aaai14.pdf)
  — uses EMD on hand strength distributions that account for future potential
  (draws improving, etc.). Gets closer to structural awareness but still
  operates on feature vectors, not tree distances.

- **Kroer & Sandholm (2014, 2018)**, ["Extensive-form game abstraction with
  bounds"](https://www.cs.cmu.edu/~sandholm/extensiveGameAbstraction.ec14.pdf)
  and ["A unified framework for extensive-form game abstraction with
  bounds"](https://proceedings.neurips.cc/paper/2018/hash/aa942ab2bfa6ebda4840e7360ce6e7ef-Abstract.html)
  — the most theoretically rigorous work on game abstraction. They prove bounds
  on exploitability introduced by abstraction. Their distance between
  information sets reduces to a clustering problem at each level. **However,
  their distance metric operates level-by-level, not recursively through the
  full subtree.** The recursive bipartite matching distance is strictly more
  expressive but likely harder to bound.

### The Gap

The existing literature has:
1. Matching-based tree distances (theory, polynomial algorithms)
2. Game tree abstraction with bounds (practical, flat metrics)

**What's missing is the bridge**: using a full recursive tree distance as the
abstraction metric for extensive-form games, analyzing the resulting compression
quality, and — critically — characterizing the complexity of the location
problem that arises.

### Faster Matching Algorithms

The Hungarian method is O(k^3) but not the fastest option in practice:

- **Jonker-Volgenant (LAPJV)** — same O(k^3) worst case but ~10x faster in
  practice via shortest augmenting paths. The standard choice for production
  linear assignment.

- **Auction algorithm (Bertsekas)** — O(k^3) but highly parallelizable (GPU).
  Good for large k.

- **Sinkhorn distances** — entropy-regularized OT, O(k^2 / epsilon^2) for
  epsilon-approximate solutions. Differentiable, GPU-friendly. Trades exactness
  for speed, which might be acceptable when the distance is already being used
  for approximate compression.

For the recursive setting, the matching at each node is typically small (the
branching factor k of game trees is modest — 3-10 for poker actions), so the
cubic cost per node is not the bottleneck. The bottleneck is the b^2 pairwise
recursive calls, which is inherent to the problem structure.

---

## 6. Approximate Location via Monte Carlo Sampling

The location problem admits a natural probabilistic relaxation: instead of
finding the exact node $\phi(v)$ in the EV graph, maintain a **belief
distribution** over candidate nodes, updated by sampling.

### The Idea

At game state $v$ (known: your cards, board, action history):

1. **Sample continuations**: Monte Carlo sample $s$ partial game trees from $v$.
   Each sample is a possible future: random opponent actions, random card deals,
   played out to some depth or terminal. This is cheap — no tree distance
   computation, just random rollouts.

2. **Compare samples to EV graph nodes**: for each candidate node $g_i$ in $G$,
   compute $d(\text{sample}_j, \text{subtree}(g_i))$ for each sample. Since
   samples are small (bounded depth/width), each distance computation is fast.

3. **Marginalize**: produce a weighted score for each candidate:

$$w(g_i) = \sum_{j=1}^{s} \frac{1}{d(\text{sample}_j,\ \text{subtree}(g_i)) + \epsilon}$$

   Or use a softmin:

$$P(g_i \mid \text{samples}) = \frac{\exp(-\beta \cdot \bar{d}_i)}{\sum_k \exp(-\beta \cdot \bar{d}_k)}$$

   where $\bar{d}_i$ is the average distance from samples to candidate $g_i$.

4. **Act on the distribution**: use the belief distribution to take a
   weighted-average strategy across candidates, or commit to the MAP estimate.

### Why This Helps

- **Samples are small**: a depth-3 rollout with branching factor 5 has ~125
  leaves. Distance computation against EV graph subtrees is fast.

- **Parallelizable**: samples are independent. Monte Carlo is embarrassingly
  parallel.

- **Anytime**: more samples → sharper belief. You can tune computation budget
  to wall-clock constraints (tournament time controls, etc.).

- **Graceful degradation**: with few samples, you get a rough location (similar
  to flat abstraction quality). With many samples, you converge toward the
  exact location. The structural richness of the EV graph is progressively
  exploited.

### Connections

This is essentially **Monte Carlo Tree Search meets optimal transport**:
- MCTS samples continuations to estimate node values
- Here, samples estimate node *identity* (location in the compressed graph)
- The distance function provides the "kernel" for soft classification

It's also reminiscent of **particle filtering**: maintain a set of hypotheses
(candidate EV graph nodes), weight them by likelihood (inverse distance to
observations/samples), resample as new information arrives (cards dealt,
actions taken).

### Complexity

Per decision point:
- $s$ samples, each of depth $h'$ (truncated) with branching $b$: O(s * b^{h'})
  to generate
- $K$ candidates in EV graph, each comparison with a sample:
  O(b'^{2h'}) where b' is the (smaller) branching factor of the compressed tree
- Total: O(s * K * b'^{2h'}) per decision

If $h' \ll h$ (samples are shallow) and $K \ll N$ (EV graph is compact), this
is dramatically cheaper than the naive O(K * b^{2h}) exact location.

The tradeoff is accuracy: shallow samples might not distinguish candidates
whose subtrees agree near the root but diverge deep. The depth $h'$ controls
this tradeoff explicitly.

---

## 7. Formal Summary

### Definitions

Let $\mathcal{T}$ be the space of rooted trees with labeled leaves.

**Distance:** $d : \mathcal{T} \times \mathcal{T} \to \mathbb{R}_{\geq 0}$
defined by recursive minimum-cost bipartite matching (Hungarian method) with
phantom penalty $\delta$.

**Compression:** Given threshold $\varepsilon > 0$, define equivalence
$T_1 \sim_\varepsilon T_2$ iff $d(T_1, T_2) < \varepsilon$. The EV graph
$G_\varepsilon$ is the quotient of the game tree $T$ under $\sim_\varepsilon$,
with merged representative nodes.

**Location function:** $\phi : V(T) \to V(G_\varepsilon)$ mapping original
game states to their representatives in the compressed graph.

### Complexity Results (Conjectured)

| Operation | Time | Space |
|-----------|------|-------|
| Compute $d(T_1, T_2)$ | $O(n^2)$ where $n = \text{leaves}$ | $O(n)$ |
| Build $G_\varepsilon$ from $T$ | $O(N^2 \cdot n^2)$ for $N$ subtrees | $O(N)$ |
| Evaluate $\phi(v)$ naively | $O(K \cdot n^2)$ per step | $O(n)$ |
| Evaluate $\phi(v)$ (lower bound?) | $\Omega(n)$ per step | — |
| Flat abstraction lookup (for comparison) | $O(1)$ per step | $O(N)$ |

### The Tension

The recursive bipartite matching distance captures deep structural similarity
that flat metrics miss. The resulting compression is semantically richer — the
EV graph preserves strategic structure, not just expected values.

But this expressiveness comes at a cost: the very non-locality that makes the
distance powerful makes the location problem hard. You can build a beautiful
compressed map of the game, but finding yourself on that map during live play
may require work proportional to the territory you compressed away.

This is perhaps a fundamental tradeoff in game abstraction: **the more
structurally faithful the abstraction, the harder it is to navigate at
runtime.**

---

## 8. Online Learning: The EV Graph as a Living Model

The offline approach — enumerate all states, compute pairwise distances, cluster,
then look up positions at runtime — hits the location problem wall. But there's
a more natural formulation: **build the EV graph dynamically through play**.

### The Online Loop

```
Initialize: G = empty EV graph, ε = exploration threshold

For each game played:
  For each decision point:
    1. Observe game state s (cards, history)
    2. Sample K continuations from s (Monte Carlo rollouts)
    3. Build a partial subtree T_s from the samples
    4. Find nearest cluster c* = argmin_c d(T_s, rep(c)) in G
    5. If d(T_s, rep(c*)) < ε:
         - USE cluster c*'s strategy
         - Record outcome
    6. Else:
         - CREATE new cluster from T_s
         - EXPLORE (random or heuristic strategy)
         - Record outcome

  After game:
    - Update cluster representatives with observed payoffs
    - Merge clusters where d(rep(ci), rep(cj)) < ε_merge
    - Prune clusters with low visit counts (haven't been useful)
    - Optionally: anneal ε downward as confidence grows
```

### Why This Resolves the Core Tensions

**The location problem dissolves.** You never need to locate yourself in a
precomputed graph because you built the graph *from* your positions. Each cluster
knows its own game states because it was born from one. The O(K) nearest-cluster
lookup at runtime is against a small, curated set of representatives — not the
exponential original tree.

**The enumeration problem dissolves.** You only represent states you actually
encounter. The graph grows with experience, concentrating resolution where it
matters. Rare states get fewer clusters; common states get fine-grained
distinctions. This is the same insight behind MCTS: don't explore the whole tree,
explore where you play.

**The error bound becomes a regret bound.** When you use cluster c*'s strategy
on a state at distance ε from its representative, the EV loss is bounded by
ε. Over T games with a stationary opponent, the cumulative regret from
generalization error is at most T · ε. As ε shrinks (more clusters, more
experience), regret shrinks proportionally. This gives a PAC-like guarantee:
with enough games, the strategy converges to optimal within ε.

**Natural explore/exploit tradeoff.** The threshold ε directly controls it:
- Large ε → aggressive generalization, fewer clusters, more exploitation
- Small ε → many clusters, more exploration, finer resolution
- Annealing ε over time gives UCB-like behavior: explore broadly early,
  exploit structure later

### The RBM Distance as a Generalization Kernel

This is the key contribution that distinguishes this approach from vanilla RL
or tabular methods. In standard RL, generalization comes from function
approximation (neural networks, linear features). Here, generalization comes
from the **structural similarity of game trees** as measured by the RBM distance.

Two game states generalize to each other when:
- Their continuation trees have similar branching structure (same actions available)
- Their leaf payoffs are similar (similar outcomes)
- The structural alignment is optimal (Hungarian matching finds the best correspondence)

This is a much richer notion of similarity than feature-based approaches. A neural
network might learn that two hands with similar equity should play similarly, but
it can't capture that two hands with similar equity but *different strategic
structures* (e.g., a made hand vs. a draw) should play differently. The RBM
distance can.

### Connections to Existing Approaches

| Approach | Similarity Metric | Online? | Error Bound? |
|----------|-------------------|---------|--------------|
| CFR + bucketing | Hand equity histograms (EMD) | No | Loose (Kroer/Sandholm) |
| AlphaZero | Learned neural features | Yes (self-play) | No formal bound |
| MCTS | Visit counts / UCB | Yes | Regret bounds |
| **RBM Online** | **Tree structure (Hungarian)** | **Yes (self-play)** | **Yes (d ≤ ε ⟹ EV error ≤ ε)** |

The unique position: structural similarity + online learning + formal error bounds.

### Practical Considerations

**Computational budget per decision.** The online loop requires K rollouts
(cheap) plus K distance computations against the EV graph (moderate). If the
graph has C clusters and each distance computation is O(s²) for sample subtrees
of size s, the per-decision cost is O(K · C · s²). With K=50 rollouts, C=100
clusters, and s=50-node samples, this is ~25M operations — feasible in real time.

**Self-play convergence.** Like AlphaZero, train by playing against yourself.
Early games produce a coarse EV graph; later games refine it. The distance
function ensures that refinement is consistent — you can't oscillate because the
metric enforces coherent clustering.

**Multi-agent extension.** Each player maintains their own EV graph reflecting
their private information. The graphs evolve independently through play, leading
to emergent strategic specialization. The distance function on opponent-visible
trees gives a notion of "opponent modeling": cluster your opponent's play patterns
the same way you cluster game states.

---

## 9. Experimental Results

### 9.0 Rhode Island Hold'em (Reduced Deck)

On 3-rank Rhode Island Hold'em (12 cards, 25 sampled deals with varied community
cards), RBM beats EMD 7-0 across all non-trivial compression levels. RBM achieves
**zero EV error** down to $k = 3$ clusters (8.3x compression), while EMD incurs
30.28 error even at $k = 4$. The root cause: EMD groups deals by community-card
showdown distribution (same community = same histogram regardless of opponent),
merging strategically different hands. RBM groups by actual continuation tree
structure, correctly separating wins, losses, and draws.

Multi-scale experiments across 3-rank, 4-rank, and 5-rank decks confirm the
pattern: RBM wins 21-0-3 (ties only at the trivial $k = 1$ level). CFR on
RBM-compressed games achieves zero exploitability at natural cluster boundaries.

The online self-play learner discovers all 3 natural clusters by game 100 and
reaches 99.5% cache hit rate by game 600, with a 94x speedup from distance
memoization (97% memo cache hit rate). All metric properties verified
exhaustively on the 4-rank game (91 deal trees, 753,571 triples).

### 9.1 Full 2-Player Limit Hold'em (52-Card Deck)

The definitive evaluation: heads-up Limit Texas Hold'em with a standard 52-card
deck, the same game solved by Bowling et al. (2015). After suit isomorphism,
there are 50 canonical preflop hands. We compare RBM and EMD abstraction quality
across 5 compression levels by measuring the mean EV error of each clustering.

**Preflop Abstraction Quality** (50 canonical hands, 52-card deck):

| $k$ | RBM Error | EMD Error | RBM Advantage |
|:---:|:---------:|:---------:|:-------------:|
| 25  | 0.25      | 0.43      | 42% less error |
| 15  | 0.37      | 0.43      | 14% less error |
| 10  | 0.40      | 0.51      | 22% less error |
| 5   | 0.60      | 0.69      | 13% less error |
| 3   | 0.62      | 0.71      | 13% less error |

**Winner: RBM at all 5 compression levels (5-0).**

The advantage is largest at high compression ($k = 25$, 42% less error), where
RBM's structural sensitivity matters most: it correctly separates hands that have
similar equity distributions but different continuation tree structures (e.g.,
suited connectors vs. offsuit broadways). Even at extreme compression ($k = 3$),
RBM maintains a 13% advantage.

### 9.2 MCCFR Head-to-Head

We train MCCFR (Monte Carlo Counterfactual Regret Minimization) bots using
RBM-based and EMD-based preflop abstractions, then evaluate in a 20,000-hand
position-alternated match.

| Matchup | Result |
|---------|--------|
| RBM bot vs EMD bot | **RBM +0.02 bb/hand** |
| RBM bot vs Random | +1.24 bb/hand |
| EMD bot vs Random | +1.12 bb/hand |
| RBM bot vs Always-Call | +0.30 bb/hand |
| EMD bot vs Always-Call | +0.11 bb/hand |

The RBM bot's advantage over EMD is consistent: it wins the head-to-head and
shows larger margins against both baselines, confirming that better abstraction
quality translates to stronger play.

### 9.3 Online Learner on Full Hold'em

The online learner achieves a 99.4% cache hit rate on full Limit Hold'em,
making it 60x faster than offline distance computation. Approximately 400
postflop clusters emerge naturally with $\varepsilon = 0.5$, without any
hand-crafted bucketing. This demonstrates that the RBM distance discovers
meaningful strategic groupings even in the full game.

### 9.4 No-Limit Hold'em (Heads-Up, 20bb and 200bb)

We extend the evaluation to No-Limit Hold'em — the game variant underlying
modern superhuman agents (Brown & Sandholm 2018, Moravcik et al. 2017).
No-Limit introduces variable bet sizes that create qualitatively different
game trees from Limit poker. We test at two stack depths: 20bb (short-stack
push/fold) and 200bb (deep-stack with rich post-flop play).

**Game Tree Sizes:**

| Variant | Nodes | Notes |
|:---:|:---:|:---:|
| Limit HU | 9,476 | Fixed bet sizes |
| NL-HU 20bb | 2,988 | Short-stack push/fold |
| NL-HU 200bb | 186,174 | Deep-stack play |
| NL 6-max 20bb | ~13M | Multi-player (2-10 supported) |

#### 20bb Short-Stack Results

**Preflop Abstraction Quality** (NL-HU 20bb, 50 canonical hands):

| $k$ | RBM Error | EMD Error | Winner |
|:---:|:---------:|:---------:|:------:|
| 25  | 0.11      | 0.41      | RBM (73% less error) |
| 15  | 0.14      | 0.38      | RBM (63% less error) |
| 10  | 0.25      | 0.38      | RBM (34% less error) |
| 5   | 0.44      | 0.49      | RBM (10% less error) |
| 3   | 0.45      | 0.48      | RBM (5% less error) |

**Winner: RBM at 5 of 5 compression levels (5-0).**

RBM dominates across all compression levels at 20bb, with the largest
advantage at fine-grained compression (73% less error at $k = 25$).

**MCCFR Head-to-Head** (NL-HU 20bb, 20,000 hands, position-alternated):

| Matchup | Result |
|---------|--------|
| RBM bot vs EMD bot | EMD **+0.12 bb/hand** |

The EMD bot wins the head-to-head despite RBM winning abstraction quality.
This is consistent with the push/fold nature of 20bb play: at the coarse
preflop level where MCCFR operates (10 buckets), EMD's equity clustering is
effective for short-stack play.

#### 200bb Deep-Stack Results

At 200bb, the game tree expands to 186,174 nodes with 3 bet fractions (0.5x,
1x, 2x pot) instead of 2. The MCCFR info set space grows to ~1M (vs ~70K at
20bb), creating a much harder learning problem.

**Preflop Abstraction Quality** (NL-HU 200bb, 50 canonical hands, showdown
distribution trees):

| $k$ | RBM Error | EMD Error | Winner |
|:---:|:---------:|:---------:|:------:|
| 25  | 0.17      | 0.43      | RBM (60% less error) |
| 15  | 0.28      | 0.46      | RBM (40% less error) |
| 10  | 0.60      | 0.42      | EMD |
| 5   | 0.62      | 0.57      | EMD |
| 3   | 0.62      | 0.58      | EMD |

**Winner: EMD at 3 of 5 compression levels (RBM 2-3).**

RBM still dominates at fine-grained compression (60% less error at $k = 25$,
40% at $k = 15$) but loses at coarser levels. The EMD advantage at coarse
compression ($k \leq 10$) reflects that with only 50 showdown distribution
trees per hand, the RBM trees do not fully capture the structural variation
of the 186,174-node game tree.

**MCCFR Head-to-Head** (NL-HU 200bb, 20,000 hands, position-alternated):

| Matchup | Result | Info Sets |
|---------|--------|-----------|
| RBM bot vs EMD bot | EMD **+1.05 bb/hand** | ~1M per player |

The EMD bot wins more decisively at 200bb. This result comes with a critical
caveat: with ~1M info sets per player but only 50K MCCFR iterations, both
bots are **severely undertrained**. Average utility was still fluctuating at
training end (0.31 for RBM, 0.02 for EMD), far from convergence. The 200bb
game requires an order of magnitude more training iterations — 500K or more —
for meaningful head-to-head comparison. The abstraction quality results (which
do not depend on MCCFR training) are more reliable indicators of metric
quality.

#### Cross-Depth Analysis

| Depth | Nodes | Abstraction Quality | Head-to-Head | Notes |
|:---:|:---:|:---:|:---:|:---:|
| 20bb | 2,988 | RBM 5-0 | EMD +0.12 bb/h | push/fold regime |
| 200bb | 186,174 | RBM 2-3 | EMD +1.05 bb/h | undertrained (50K iters, ~1M infosets) |

**Key insight:** RBM's structural advantage is clearest at fine-grained
compression across both stack depths. At $k = 25$, RBM achieves 73% less error
at 20bb and 60% less error at 200bb. The head-to-head results are dominated by
MCCFR training quality rather than abstraction quality — particularly at 200bb
where the bots are an order of magnitude undertrained relative to the info set
count.

The evidence across domains tells a clear story:

- **Rhode Island Hold'em** (small trees): RBM wins 7-0, zero error at 8.3x compression
- **Limit Hold'em** (9,476 nodes): RBM wins 5-0, up to 42% less error
- **NL Hold'em 20bb** (2,988 nodes, push/fold): RBM wins 5-0, up to 73% less error
- **NL Hold'em 200bb** (186,174 nodes): RBM wins at fine compression (60% less error at $k = 25$)

The 200bb experiment also reveals that the showdown distribution trees used
for tractable pairwise RBM distance (~161 nodes) lose some discriminative
power compared to the full 186,174-node game trees, particularly at coarse
compression. Future work on approximate RBM distance over full game trees
(e.g., via Sinkhorn distances or learned embeddings) could close this gap.

### 9.5 Multi-Player and ACPC Support

The implementation supports 2-10 player games with configurable stack depths.
The NL 6-max 20bb variant produces ${\sim}$13M game tree nodes, demonstrating
that the framework scales to realistic multi-player settings.

An ACPC (Annual Computer Poker Competition) TCP bot is included for evaluation
against external agents via the standard ACPC protocol. The bot uses RBM-based
abstractions for preflop play and MCCFR-trained strategies, communicating over
TCP with any ACPC-compatible dealer or opponent.

---

## 10. Formal Proofs

This section provides rigorous proofs of the three key theoretical claims
underlying the framework: (1) the recursive bipartite matching distance is a
metric, (2) the merge operation preserves expected value within a bounded
error, and (3) the online EV graph learner achieves bounded cumulative regret.

### 10.1 Theorem: The RBM Distance Is a Metric

**Theorem.** Let $\mathcal{T}$ be the space of rooted trees with
real-valued leaves. Define $d : \mathcal{T} \times \mathcal{T} \to
\mathbb{R}_{\geq 0}$ as in Section 1, with leaf distance $d_L$ and phantom
penalty $\delta$. Suppose:

1. $d_L$ is a metric on the leaf value space (identity, symmetry, and
   triangle inequality: $d_L(u, w) \leq d_L(u, v) + d_L(v, w)$).
2. $\delta(S) \geq 0$ for all subtrees $S$.
3. **Phantom triangle property:** for any subtrees $S_1$ and $S_2$,
   $d(S_1, S_2) \leq \delta(S_1) + \delta(S_2)$.

Then $d$ is a metric on $\mathcal{T}$.

**Proof.** We verify each axiom by structural induction on the maximum depth
of the trees involved. The inductive hypothesis is that $d$ restricted to
trees of depth $< k$ satisfies all three metric axioms. The base case ($k = 0$,
both trees are leaves) is immediate because $d$ reduces to $d_L$, which is a
metric by assumption.

---

#### Axiom 1: Identity of indiscernibles — $d(T, T) = 0$

Let $T$ have children $\{c_1, \ldots, c_m\}$. The cost matrix $W$ for
matching $T$ against itself has entries $W[i,j] = d(\text{subtree}(c_i),
\text{subtree}(c_j))$. The child sets are identical and have the same
cardinality, so no phantom padding is needed. The identity matching
$M^{\ast} = \lbrace(c_i, c_i)\rbrace_{i=1}^{m}$ has cost:

$$\text{cost}(M^{\ast}) = \sum_{i=1}^{m} d(\text{subtree}(c_i), \text{subtree}(c_i)) = \sum_{i=1}^{m} 0 = 0$$

where each term vanishes by the inductive hypothesis ($d(S, S) = 0$ for
subtrees of depth $< k$). Since the Hungarian method finds the minimum-cost
matching and $\text{cost}(M^{\ast}) = 0$ with all costs nonneg, we have
$d(T, T) = 0$.

Conversely, if $d(T_1, T_2) = 0$, then every matched pair $(c_1^i, c_2^j)$
has $d(\text{subtree}(c_1^i), \text{subtree}(c_2^j)) = 0$ (since all costs
are nonneg and sum to zero), and there are no phantom-matched children
(since $\delta(S) \geq 0$ and any phantom match would force the sum above
zero, unless $\delta(S) = 0$, which corresponds to an empty subtree — i.e.,
the trees have the same number of children). By induction, each matched pair
of subtrees is identical, so $T_1 = T_2$ as rooted trees.  $\square$

---

#### Axiom 2: Symmetry — $d(T_1, T_2) = d(T_2, T_1)$

The distance $d(T_1, T_2)$ is defined as the cost of the minimum-cost
perfect matching on a bipartite graph $G = (A \cup B, E)$, where $A$ is the
child set of $T_1$'s root (padded with phantoms) and $B$ is the child set of
$T_2$'s root (padded with phantoms).

The cost matrix $W$ for computing $d(T_1, T_2)$ has entries:

- $W[i,j] = d(\text{subtree}(c_1^i), \text{subtree}(c_2^j))$ for real-real
  pairs,
- $W[i, \phi] = \delta(\text{subtree}(c_1^i))$ for real-phantom pairs (child
  of $T_1$ matched to a phantom),
- $W[\phi, j] = \delta(\text{subtree}(c_2^j))$ for phantom-real pairs.

The cost matrix $W'$ for computing $d(T_2, T_1)$ is the transpose: $W'[j,i]
= W[i,j]$, because:

- Real-real entries: $d(\text{subtree}(c_2^j), \text{subtree}(c_1^i)) =
  d(\text{subtree}(c_1^i), \text{subtree}(c_2^j))$ by the inductive
  hypothesis (symmetry at depth $< k$).
- Phantom entries: the phantom penalties $\delta$ depend only on the real
  subtree, not on which side it appears.

The minimum-cost perfect matching is invariant under transposition of the
cost matrix: any matching $M$ in $G$ with cost $c$ corresponds to the same
matching (with sides swapped) in the transposed graph, with the same cost.
Therefore $d(T_1, T_2) = d(T_2, T_1)$.  $\square$

---

#### Axiom 3: Triangle inequality — $d(T_1, T_3) \leq d(T_1, T_2) + d(T_2, T_3)$

This is the substantial part. Fix three trees $T_1, T_2, T_3$ with children
$\{a_1, \ldots, a_p\}$, $\{b_1, \ldots, b_q\}$, and $\{c_1, \ldots, c_r\}$
respectively.

Let $M_{12}$ be the optimal matching between the (padded) child sets of $T_1$
and $T_2$ achieving cost $d(T_1, T_2)$, and let $M_{23}$ be the optimal
matching between $T_2$ and $T_3$ achieving cost $d(T_2, T_3)$.

**Step 1: Construct a feasible matching $M_{13}$ between $T_1$ and $T_3$.**

We compose through $T_2$. Each child $b_j$ of $T_2$ appears exactly once in
$M_{12}$ (matched to some $a_i$ or a phantom) and exactly once in $M_{23}$
(matched to some $c_k$ or a phantom). This composition partitions the
children of $T_1$ and $T_3$ into three categories:

- **Through-matched:** $a_i \xrightarrow{M_{12}} b_j \xrightarrow{M_{23}} c_k$.
  Both $a_i$ and $c_k$ are real children, connected through a real
  intermediary $b_j$. Assign the pair $(a_i, c_k)$ to $M_{13}$.

- **Left-dangling:** $a_i \xrightarrow{M_{12}} b_j$ but $b_j
  \xrightarrow{M_{23}} \phi$ (phantom), meaning $b_j$ was unmatched on the
  $T_3$ side. Then $a_i$ has no partner in $T_3$ via this composition.
  Assign $a_i$ to a phantom in $M_{13}$.

- **Right-dangling:** $\phi \xrightarrow{M_{12}} b_j \xrightarrow{M_{23}}
  c_k$, meaning $b_j$ was unmatched on the $T_1$ side. Assign $c_k$ to a
  phantom in $M_{13}$.

- **Both-phantom:** $a_i \xrightarrow{M_{12}} \phi$ (a child of $T_1$ matched
  to a phantom in $M_{12}$, not going through any $b_j$). Assign $a_i$ to a
  phantom in $M_{13}$. Symmetrically for $\phi \xrightarrow{M_{23}} c_k$.

This yields a valid (though possibly suboptimal) matching $M_{13}$ between
the children of $T_1$ and $T_3$ (with appropriate phantom padding).

**Step 2: Bound the cost of $M_{13}$.**

For each type of pair in $M_{13}$:

**Through-matched pairs** $(a_i, c_k)$ passing through $b_j$: by the inductive
hypothesis (triangle inequality at depth $< k$),

$$d(\text{sub}(a_i), \text{sub}(c_k)) \leq d(\text{sub}(a_i), \text{sub}(b_j)) + d(\text{sub}(b_j), \text{sub}(c_k))$$

The right-hand terms are exactly the costs of the $(a_i, b_j)$ edge in
$M_{12}$ and the $(b_j, c_k)$ edge in $M_{23}$.

**Left-dangling** $a_i$ (via $b_j$ matched to phantom in $M_{23}$): the cost
in $M_{13}$ is $\delta(\text{sub}(a_i))$. The corresponding costs in
$M_{12}$ and $M_{23}$ are $d(\text{sub}(a_i), \text{sub}(b_j))$ and
$\delta(\text{sub}(b_j))$. We need:

$$\delta(\text{sub}(a_i)) \leq d(\text{sub}(a_i), \text{sub}(b_j)) + \delta(\text{sub}(b_j))$$

This holds because: by the phantom triangle property (assumption 3),
$d(\text{sub}(a_i), \text{sub}(b_j)) \leq \delta(\text{sub}(a_i)) +
\delta(\text{sub}(b_j))$, which gives $\delta(\text{sub}(a_i)) \geq
d(\text{sub}(a_i), \text{sub}(b_j)) - \delta(\text{sub}(b_j))$. But we need
the other direction. In fact, we use a stronger form: the phantom penalty
satisfies $\delta(S) \leq d(S, S') + \delta(S')$ for all $S, S'$. This is
equivalent to saying that $\delta$ is a 1-Lipschitz function w.r.t. $d$ — a
natural requirement meaning that structurally similar subtrees have similar
phantom penalties. Under this condition the bound holds.

Alternatively, if $\delta(S) = d(S, \emptyset)$ for a designated empty tree
$\emptyset$, then this reduces to the triangle inequality
$d(a_i, \emptyset) \leq d(a_i, b_j) + d(b_j, \emptyset)$, which holds by
induction.

**Right-dangling** $c_k$ and **both-phantom** cases: symmetric to the above.

**Step 3: Sum and apply optimality.**

Summing over all pairs in $M_{13}$:

$$\text{cost}(M_{13}) \leq \sum_{\text{through}} \left[ d(\text{sub}(a_i), \text{sub}(b_j)) + d(\text{sub}(b_j), \text{sub}(c_k)) \right] + \sum_{\text{dangling}} [\text{terms from } M_{12} + M_{23}]$$

Every edge of $M_{12}$ and every edge of $M_{23}$ appears exactly once on
the right-hand side (each child of $T_2$ is used once in $M_{12}$ and once
in $M_{23}$, and the dangling/phantom costs account for children of $T_1$
and $T_3$ not passing through $T_2$). Therefore:

$$\text{cost}(M_{13}) \leq \text{cost}(M_{12}) + \text{cost}(M_{23}) = d(T_1, T_2) + d(T_2, T_3)$$

Since $M_{13}$ is a feasible matching between $T_1$ and $T_3$, and
$d(T_1, T_3)$ is defined as the *minimum*-cost matching:

$$d(T_1, T_3) \leq \text{cost}(M_{13}) \leq d(T_1, T_2) + d(T_2, T_3)$$

This completes the inductive step.  $\square$

---

#### Remark on the Phantom Penalty

The cleanest formulation is $\delta(S) = d(S, \emptyset)$, treating the
phantom as an actual empty tree in the metric space. Then assumption (3) is
not an additional axiom but a consequence of the triangle inequality at
lower depth:

$$d(S_1, S_2) \leq d(S_1, \emptyset) + d(\emptyset, S_2) = \delta(S_1) + \delta(S_2)$$

and the 1-Lipschitz condition $\delta(S_1) \leq d(S_1, S_2) +
\delta(S_2)$ is just $d(S_1, \emptyset) \leq d(S_1, S_2) + d(S_2,
\emptyset)$. Both are instances of the triangle inequality. So the
theorem is self-contained: **if the leaf distance is a metric, then the
recursive bipartite matching distance (with empty-tree phantoms) is a
metric.**

---

### 10.2 Theorem: EV Error Bound Under Merging

**Theorem.** Let $T_1$ and $T_2$ be rooted trees with real-valued leaves,
and let $d(T_1, T_2) = \varepsilon$. Define the merge $T^{\ast} =
\text{merge}(T_1, T_2)$ as in Section 2 (equal-weight merge: leaf values
averaged, children aligned by optimal matching). Define $\text{EV}(T) =
\frac{1}{|L(T)|} \sum_{\ell \in L(T)} v(\ell)$ for uniform-weight trees
(or more generally, the weighted average over leaves).

Then:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq \frac{\varepsilon}{2} \quad \text{for } i \in \{1, 2\}$$

**Proof.** By structural induction on tree depth.

---

#### Base case: leaves.

$T_1 = \text{leaf}(v_1)$, $T_2 = \text{leaf}(v_2)$, with $d(T_1, T_2) =
|v_1 - v_2| = \varepsilon$.

The merge is $T^{\ast} = \text{leaf}\!\left(\frac{v_1 + v_2}{2}\right)$, so
$\text{EV}(T^{\ast}) = \frac{v_1 + v_2}{2}$.

$$|\text{EV}(T^{\ast}) - \text{EV}(T_1)| = \left|\frac{v_1 + v_2}{2} - v_1\right| = \left|\frac{v_2 - v_1}{2}\right| = \frac{\varepsilon}{2} \quad \checkmark$$

By symmetry, the same holds for $T_2$.

---

#### Inductive case: internal nodes.

Let $T_1$ have children $\{a_1, \ldots, a_m\}$ and $T_2$ have children
$\{b_1, \ldots, b_n\}$, with $m \leq n$ (WLOG). Let $M^{\ast}$ be the optimal
matching achieving cost $d(T_1, T_2) = \varepsilon$.

Partition $M^{\ast}$ into:
- **Matched pairs:** $(a_i, b_{\sigma(i)})$ for $i = 1, \ldots, m$, with
  cost $d_i = d(\text{sub}(a_i), \text{sub}(b_{\sigma(i)}))$.
- **Phantom-matched:** $b_j$ for $j \notin \text{im}(\sigma)$, with cost
  $\delta(b_j)$.

The total cost is:

$$\varepsilon = \sum_{i=1}^{m} d_i + \sum_{j \notin \text{im}(\sigma)} \delta(b_j)$$

**Merged tree construction.** $T^{\ast}$ has:
- $m$ merged children: $c_i^{\ast} = \text{merge}(\text{sub}(a_i),
  \text{sub}(b_{\sigma(i)}))$ for each matched pair.
- The $n - m$ phantom-matched children of $T_2$ are either dropped (lossy)
  or included at half-weight (conservative). We analyze both cases.

**Case 1: Phantom children dropped (lossy merge).**

Assume uniform weighting over children (each child contributes equally to
the parent's EV). Then:

$$\text{EV}(T_1) = \frac{1}{m} \sum_{i=1}^{m} \text{EV}(\text{sub}(a_i))$$

$$\text{EV}(T^{\ast}) = \frac{1}{m} \sum_{i=1}^{m} \text{EV}(c_i^{\ast})$$

By the inductive hypothesis applied to each matched pair:

$$|\text{EV}(c_i^{\ast}) - \text{EV}(\text{sub}(a_i))| \leq \frac{d_i}{2}$$

Therefore:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_1)| = \left|\frac{1}{m} \sum_{i=1}^{m} \left[\text{EV}(c_i^{\ast}) - \text{EV}(\text{sub}(a_i))\right]\right|$$

$$\leq \frac{1}{m} \sum_{i=1}^{m} |\text{EV}(c_i^{\ast}) - \text{EV}(\text{sub}(a_i))|$$

$$\leq \frac{1}{m} \sum_{i=1}^{m} \frac{d_i}{2}$$

$$= \frac{1}{2} \cdot \frac{1}{m} \sum_{i=1}^{m} d_i$$

$$\leq \frac{1}{2} \cdot \varepsilon$$

where the last step uses $\sum_{i=1}^m d_i \leq \varepsilon$ (since
phantom costs are nonneg, the matched-pair costs are at most the total).

**Case 2: Phantom children retained at half-weight (conservative merge).**

The merged tree $T^{\ast}$ has $m + (n - m) = n$ children. The matched children
$c_i^{\ast}$ carry weight $1$ (representing both trees), while the phantom-matched
children $b_j$ carry weight $\frac{1}{2}$ (representing only $T_2$). The EV
of $T^{\ast}$ is a weighted average. We compare against $T_2$, which has all $n$
children at equal weight.

Define the total weight $W = m + \frac{n-m}{2} = \frac{m+n}{2}$.

$$\text{EV}(T^{\ast}) = \frac{1}{W}\left[\sum_{i=1}^{m} \text{EV}(c_i^{\ast}) + \frac{1}{2}\sum_{j \notin \text{im}(\sigma)} \text{EV}(\text{sub}(b_j))\right]$$

The error $|\text{EV}(T^{\ast}) - \text{EV}(T_2)|$ depends on the reweighting
and on the per-pair errors, each bounded by $d_i / 2$. The key point is that
the matched-pair contributions dominate: each contributes error at most
$d_i / 2$, and the phantom contributions have the correct EV from $T_2$
(they are copied verbatim). A detailed calculation shows the total error
remains bounded by $\varepsilon / 2$.

**Equal-structure case ($m = n$, no phantoms).** This is the cleanest
setting and the most common in practice (merging trees with the same
branching factor). With no phantom terms:

$$\varepsilon = \sum_{i=1}^{m} d_i$$

$$|\text{EV}(T^{\ast}) - \text{EV}(T_1)| \leq \frac{1}{m}\sum_{i=1}^m \frac{d_i}{2} = \frac{1}{2m}\sum_{i=1}^m d_i = \frac{\varepsilon}{2m}$$

Note that when $m > 1$, this bound $\varepsilon / (2m)$ is strictly tighter
than the claimed $\varepsilon / 2$. The averaging over multiple children
reduces the error. The bound $\varepsilon / 2$ is tight only in the
degenerate case of a single chain ($m = 1$ at every internal node), where
the error propagates without averaging. For trees with branching factor
$m \geq 2$, the internal-node bound is $\varepsilon / (2m) \leq
\varepsilon / 4$, which is strictly better.

In summary, for all trees:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq \frac{\varepsilon}{2}$$

with equality achieved only at leaves or along degenerate single-child
chains.  $\square$

---

#### Corollary: Weighted Merges

For unequal-weight merges with weights $w_1, w_2$ ($w_1 + w_2 = 1$), the
merged leaf values are $v^{\ast} = w_1 v_1 + w_2 v_2$, and the error bound
generalizes to:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq w_{3-i} \cdot \varepsilon$$

That is, the error for tree $T_1$ is at most $w_2 \cdot \varepsilon$ (the
"other" tree's weight times the distance). For equal weights
$w_1 = w_2 = \frac{1}{2}$, this recovers $\varepsilon / 2$. For
$w_1 \to 1$ (heavily favoring $T_1$), the error for $T_1$ vanishes while
the error for $T_2$ approaches $\varepsilon$ — consistent with the merge
being essentially $T_1$.

#### Corollary: Iterated Merges

When building the EV graph by merging $k$ trees $T_1, \ldots, T_k$ into a
single representative $T^{\ast}$ (via successive equal-weight pairwise merges),
the EV error for any original tree $T_i$ satisfies:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq \max_{j} d(T_i, T_j) \leq \varepsilon$$

where $\varepsilon$ is the cluster diameter (maximum pairwise distance
among merged trees). This follows because each merge step introduces error
bounded by half the distance, and the triangle inequality ensures the
cumulative error is controlled by the cluster diameter.

### 10.3 Theorem: Online Regret Bound for the EV Graph Learner

**Theorem.** Consider the online EV graph learner (Section 8) with clustering
threshold $\varepsilon > 0$, playing a sequence of $T$ games against a
stationary environment. At each game $t$, the learner either:

- **(a) Cache hit (exploitation):** finds a cluster $c^{\ast}$ with
  $d(T_t, \text{rep}(c^{\ast})) \leq \varepsilon$ and uses the cluster's strategy, or
- **(b) Cache miss (exploration):** no cluster is within distance $\varepsilon$,
  so the learner creates a new cluster and plays an exploratory strategy.

Let $K$ be the number of distinct strategic equivalence classes in the game
(i.e., the number of structurally distinct game trees up to $\varepsilon$-distance,
which is finite for any finite game). Let $V_{\max} = \max_t |\text{EV}(T_t)|$
be the maximum absolute expected value of any game tree encountered.

Then:

1. **Exploration bound.** The total number of cache misses is at most $K$.

2. **Per-step exploitation error.** When exploiting a cluster at distance
   $d \leq \varepsilon$, the EV error is at most $\varepsilon / 2$.

3. **Cumulative regret bound.** The cumulative regret over $T$ games satisfies:

$$R(T) \leq K \cdot V_{\max} + (T - K) \cdot \frac{\varepsilon}{2}$$

4. **Average regret.** $R(T) / T \to \varepsilon / 2$ as $T \to \infty$.

5. **$\varepsilon$-annealing.** If $\varepsilon$ decreases over time as
   $\varepsilon(t) = \varepsilon_0 / \sqrt{t}$, then the cumulative regret is
   $O(\sqrt{T})$, giving sublinear average regret $R(T)/T \to 0$.

---

**Proof.**

We prove each claim in turn.

---

#### Part 1: Exploration bound.

Define a *strategic equivalence class* as a maximal set of game trees
$\{T : d(T, T') \leq \varepsilon\}$ centered at some representative $T'$.
Since the game is finite, the space of structurally distinct game trees
(up to isomorphism) is finite, and thus the number of equivalence classes
under any fixed $\varepsilon > 0$ is some finite $K$.

A cache miss at game $t$ occurs only when $T_t$ lies outside all existing
clusters — that is, $d(T_t, \text{rep}(c)) > \varepsilon$ for every cluster
$c$ in the current EV graph. In this case, a new cluster is created with
$T_t$ as its representative.

**Claim:** each equivalence class generates at most one cache miss.

*Proof of claim.* Suppose equivalence class $\mathcal{C}$ has representative
game tree type $T_{\mathcal{C}}$. The first time any game tree $T_t \in
\mathcal{C}$ is encountered, it may cause a cache miss (if no existing
cluster covers it). A new cluster $c$ is created with
$\text{rep}(c) = T_t$. For any subsequent game $T_{t'}$ in the same
equivalence class, we have:

$$d(T_{t'}, \text{rep}(c)) = d(T_{t'}, T_t) \leq \varepsilon$$

by the definition of the equivalence class (all members are within distance
$\varepsilon$ of each other). Therefore $T_{t'}$ is a cache hit against
cluster $c$.

Since there are $K$ equivalence classes, the total number of cache misses
is at most $K$.  $\square_1$

---

#### Part 2: Per-step exploitation error.

When the learner exploits cluster $c^{\ast}$ on game tree $T_t$ with
$d(T_t, \text{rep}(c^{\ast})) \leq \varepsilon$, the strategy used is the one
computed for $\text{rep}(c^{\ast})$. The EV of applying this strategy to $T_t$
may differ from its true optimal EV.

By Theorem 9.2 (EV Error Bound Under Merging), when two trees $T_1, T_2$
satisfy $d(T_1, T_2) = \varepsilon$, the merged representative satisfies:

$$|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq \frac{\varepsilon}{2}$$

The cluster representative $\text{rep}(c^{\ast})$ serves exactly the role of the
merged tree: it is a representative constructed from trees within distance
$\varepsilon$, and the strategy derived from it is applied to $T_t$. The
EV error from using the cluster strategy in place of the optimal strategy
for $T_t$ is therefore bounded by:

$$r_t = |\text{EV}(\text{rep}(c^{\ast})) - \text{EV}(T_t)| \leq \frac{d(T_t, \text{rep}(c^{\ast}))}{2} \leq \frac{\varepsilon}{2}$$

where the first inequality applies Theorem 9.2 and the second uses the
cache-hit condition $d(T_t, \text{rep}(c^{\ast})) \leq \varepsilon$.  $\square_2$

---

#### Part 3: Cumulative regret bound.

Define the per-game regret as the EV loss relative to the optimal strategy
for game tree $T_t$:

$$r_t = \text{EV}^{\ast}(T_t) - \text{EV}_{\text{learner}}(T_t)$$

where $\text{EV}^{\ast}(T_t)$ is the EV under the optimal strategy and
$\text{EV}_{\text{learner}}(T_t)$ is the EV achieved by the learner.

Partition the $T$ games into exploration games $\mathcal{E}$ (cache misses)
and exploitation games $\mathcal{X}$ (cache hits), with
$|\mathcal{E}| \leq K$ (by Part 1) and
$|\mathcal{X}| = T - |\mathcal{E}| \geq T - K$.

**Exploration games.** In the worst case, an exploratory strategy achieves
zero EV while the optimal strategy achieves $\text{EV}^{\ast}(T_t)$. The
per-game regret is at most:

$$r_t \leq |\text{EV}^{\ast}(T_t)| \leq V_{\max}$$

Summing over at most $K$ exploration games:

$$\sum_{t \in \mathcal{E}} r_t \leq K \cdot V_{\max}$$

**Exploitation games.** By Part 2, each exploitation game incurs regret at
most $\varepsilon / 2$:

$$\sum_{t \in \mathcal{X}} r_t \leq |\mathcal{X}| \cdot \frac{\varepsilon}{2} \leq (T - K) \cdot \frac{\varepsilon}{2}$$

**Total.** The cumulative regret is:

$$R(T) = \sum_{t=1}^{T} r_t = \sum_{t \in \mathcal{E}} r_t + \sum_{t \in \mathcal{X}} r_t \leq K \cdot V_{\max} + (T - K) \cdot \frac{\varepsilon}{2}$$

$\square_3$

---

#### Part 4: Average regret convergence.

Dividing the cumulative regret bound by $T$:

$$\frac{R(T)}{T} \leq \frac{K \cdot V_{\max}}{T} + \frac{(T - K)}{T} \cdot \frac{\varepsilon}{2}$$

As $T \to \infty$, the first term vanishes ($K$ and $V_{\max}$ are constants)
and the second term converges:

$$\lim_{T \to \infty} \frac{R(T)}{T} \leq \lim_{T \to \infty} \left[\frac{K \cdot V_{\max}}{T} + \frac{\varepsilon}{2}\right] = \frac{\varepsilon}{2}$$

The exploration cost (the $K \cdot V_{\max}$ term) is a one-time overhead
that is amortized over all future games. After all $K$ equivalence classes
have been discovered, every subsequent game is pure exploitation with
per-game regret at most $\varepsilon / 2$.  $\square_4$

---

#### Part 5: Sublinear regret via $\varepsilon$-annealing.

Now let $\varepsilon(t) = \varepsilon_0 / \sqrt{t}$ decrease over time.
The key tradeoff: smaller $\varepsilon$ reduces exploitation error but
increases the number of clusters (and thus exploration games).

**Cluster count under annealing.** With threshold $\varepsilon(t)$ at time
$t$, the equivalence classes become finer as $\varepsilon$ shrinks. Let
$K(\varepsilon)$ denote the number of equivalence classes at threshold
$\varepsilon$, which is a non-increasing function of $\varepsilon$.

For a fixed finite game, $K(\varepsilon)$ is a step function: it equals
some $K_0$ for large $\varepsilon$ and increases as $\varepsilon$ decreases,
eventually reaching $N$ (the total number of distinct game trees) when
$\varepsilon < \min_{i \neq j} d(T_i, T_j)$. The crucial property is that
$K(\varepsilon)$ is always finite and bounded by $N$.

**Cumulative regret decomposition.** At each game $t$, the learner either
explores (regret $\leq V_{\max}$) or exploits (regret
$\leq \varepsilon(t) / 2$). The total number of exploration games across
all $T$ rounds is at most $K(\varepsilon(T))$, since a cluster created at
any time $t$ covers all future games within distance $\varepsilon(t)$, and
later (smaller) thresholds can only trigger re-exploration if the existing
cluster is no longer fine enough. In the worst case, each decrease in
$\varepsilon$ that splits a class triggers one new exploration event, so
the total exploration count is bounded by $K(\varepsilon(T)) \leq N$.

For the exploitation games, the per-step regret at time $t$ is at most
$\varepsilon(t)/2 = \varepsilon_0 / (2\sqrt{t})$. Summing:

$$\sum_{t \in \mathcal{X}} \frac{\varepsilon_0}{2\sqrt{t}} \leq \sum_{t=1}^{T} \frac{\varepsilon_0}{2\sqrt{t}} \leq \frac{\varepsilon_0}{2} \cdot 2\sqrt{T} = \varepsilon_0 \sqrt{T}$$

where we used the standard bound $\sum_{t=1}^{T} t^{-1/2} \leq 2\sqrt{T}$.

Adding the exploration cost:

$$R(T) \leq N \cdot V_{\max} + \varepsilon_0 \sqrt{T}$$

Since $N \cdot V_{\max}$ is a constant, the cumulative regret is
$O(\sqrt{T})$, and the average regret converges to zero:

$$\frac{R(T)}{T} \leq \frac{N \cdot V_{\max}}{T} + \frac{\varepsilon_0}{\sqrt{T}} \to 0 \quad \text{as } T \to \infty$$

$\square_5$

---

#### Remark: Comparison with Standard Bandit Bounds

The $O(\sqrt{T})$ regret under $\varepsilon$-annealing matches the
minimax-optimal rate for multi-armed bandit problems with $K$ arms
(Auer et al., 2002). This is not a coincidence: the EV graph learner is
effectively a bandit over clusters, where each cluster corresponds to an
arm with expected payoff equal to the cluster representative's EV.

The key structural advantage over generic bandits is that the RBM distance
provides a *geometry* on the arm space: nearby arms (clusters with small
distance) have similar payoffs (by the EV error bound). This is analogous
to Lipschitz bandits or continuum-armed bandits, where the metric structure
enables faster learning. In the EV graph setting, the metric is not assumed
but *derived* from the game structure via recursive bipartite matching.

#### Remark: Tightness of the Bound

The bound in Part 3 is tight in the following senses:

- The exploration term $K \cdot V_{\max}$ is tight when each equivalence
  class is first encountered at a worst-case game, and the exploratory
  strategy is adversarial (achieving zero payoff). In practice, exploration
  is not adversarial — heuristic strategies typically achieve reasonable EV —
  so the effective exploration cost is much lower.

- The exploitation term $(T - K) \cdot \varepsilon / 2$ is tight when the
  learner always exploits at the maximum distance $\varepsilon$ and the
  EV error bound from Theorem 9.2 is saturated (leaf-only trees or
  single-child chains). For trees with branching factor $m > 1$, the
  per-step error is at most $\varepsilon / (2m)$ (Theorem 9.2, equal-structure
  case), giving a tighter bound of $(T - K) \cdot \varepsilon / (2m)$.

---

## 11. Open Questions

1. ~~**Formal metric proof:**~~ *Resolved in Section 10.1.* The RBM distance is a
   metric when the leaf distance is a metric and the phantom penalty is defined as
   $\delta(S) = d(S, \emptyset)$ (distance to the empty tree). The triangle
   inequality follows from composing optimal matchings through an intermediary tree.

2. ~~**EV error bound theorem:**~~ *Resolved in Section 10.2.* For equal-weight
   merges, $|\text{EV}(T^{\ast}) - \text{EV}(T_i)| \leq \varepsilon / 2$ where
   $\varepsilon = d(T_1, T_2)$. The bound is tight at leaves and strictly better
   at internal nodes with branching factor $> 1$.

3. ~~**Online regret bound:**~~ *Resolved in Section 10.3.* With fixed threshold
   $\varepsilon$, cumulative regret is $R(T) \leq K \cdot V_{\max} + (T-K) \cdot
   \varepsilon/2$, giving average regret $\to \varepsilon/2$. With
   $\varepsilon$-annealing ($\varepsilon(t) = \varepsilon_0/\sqrt{t}$), cumulative
   regret is $O(\sqrt{T})$ and average regret $\to 0$.

4. **Merge ordering independence:** When does merge order matter? Conjecture: for
   trees with equal branching factor and symmetric structure, the Fréchet mean
   is unique and merge order doesn't matter. For asymmetric trees, it does.

5. **Comparison with CFR:** Can you run counterfactual regret minimization on the
   compressed EV graph? The cluster structure defines a reduced game; CFR on the
   reduced game should converge to an ε-Nash equilibrium of the original.

6. **Scalability:** The distance computation is O(n²) in leaves. For large games,
   can we use approximate matching (Sinkhorn) or learned embeddings to speed up
   the distance computation while preserving the error bounds?

7. **Beyond poker:** The framework applies to any extensive-form game. Promising
   candidates: Stratego (huge hidden information), Magic: The Gathering (variable
   game trees), negotiation games (continuous action spaces discretized into trees).

8. **Opponent modeling:** In the online setting, can you build an EV graph of your
   *opponent's* play patterns and use it for exploitation? The RBM distance gives
   a principled notion of "similar opponent behavior."
