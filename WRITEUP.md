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
   - $\delta(S) = \text{max\_leaf\_value}(S)$ — worst-case payoff loss
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
$T_1$ and $T_2$ with small distance, produce a representative tree $T^*$ that
captures their shared structure.

### Construction (bottom-up)

Given the optimal matching $M$ between children of $n_1$ and $n_2$:

- **Matched pairs** $(c_1^i, c_2^j) \in M$: recursively merge their subtrees.
  The merged child represents both original children.

- **Phantoms** (unmatched children from the larger set): either:
  - **Keep**: include in $T^*$ at reduced weight (they represent structure
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

Full tree: ~$10^{18}$ nodes. Even with perfect play, far too large for exact
computation.

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

## 8. Open Questions

1. **Tight bounds on location:** Is $\Omega(n)$ per step tight, or can
   incremental/amortized techniques beat it? The structure of game trees
   (alternating chance/decision) may help.

2. **Metric properties:** Under what conditions on $\delta$ is this a true
   metric? Is there a canonical choice of phantom penalty?

3. **Merge well-definedness:** Is the merge operation associative? Does the
   order of merging affect the final EV graph? (Likely yes — this connects to
   the theory of Fréchet means in metric spaces.)

4. **Approximation quality:** If you play using the strategy from
   $G_\varepsilon$ (with approximate location), how much EV do you lose
   compared to the exact game-theoretic solution? Can you bound the
   exploitability as a function of $\varepsilon$?

5. **Relationship to CFR:** Counterfactual Regret Minimization is the standard
   algorithm for poker AI. Does the EV graph structure interact usefully with
   CFR — e.g., can you run CFR on the compressed graph and get convergence
   guarantees?

6. **Beyond poker:** The distance and compression framework applies to any
   extensive-form game. Are there games where the location problem is easier
   (e.g., games with more regularity in the tree structure)?
