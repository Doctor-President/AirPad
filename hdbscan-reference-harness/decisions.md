# HDBSCAN reference harness — decisions log

Chronological record of harness-scoped decisions whose rationale is not
recoverable from code or git history alone. Newest entries on top.

---

## 2026-05-12 — Initial scoping decisions (4b.0 scaffolding)

Three pinning decisions land alongside the harness scaffolding so they
echo into every JSON the harness emits and every Swift call site at the
service boundary. Echoing in JSON means a future divergence between
harness and Swift surfaces in the diff as a config mismatch, not as a
silent algorithmic deviation that wastes triage time.

### Decision 1 — `algorithm='generic'` (NOT `'best'`)

**What.** The Python `hdbscan.HDBSCAN` constructor accepts an `algorithm`
parameter governing how the minimum spanning tree is built. The harness
pins `'generic'`, which uses classical Prim's on the full pairwise
distance matrix.

**Why not `'best'`.** `'best'` dispatches by input dimension:
- ≤ 60D → KDTree-based Boruvka with **approximate MST** (alpha-tree
  approximation, controlled by `leaf_size`).
- > 60D → BallTree variant of the same.

The Swift port mirrors Python's `_hdbscan_generic` end-to-end. A Boruvka
mirror is multi-week work for no product benefit: AirPad's post-UMAP
input is 2D and a few hundred points; the classical Prim's MST is
microseconds and exact. Pinning `'generic'` keeps harness and port on
the same algorithmic surface.

**Why echo in JSON.** The output JSON's `algorithmPath` field is
written by both the Python reference and (eventually) the Swift port.
A future case where someone flips one side to `'best'` without the
other surfaces as `algorithmPath: "generic"` vs `algorithmPath: "boruvka_kdtree"`
in the diff — a one-line spot rather than a "labels don't match,
why?" expedition.

### Decision 2 — `match_reference_implementation=False`

**What.** `hdbscan.HDBSCAN(match_reference_implementation=False)`.

**Why.** From the package docstring: "There exists a `reference
implementation` of HDBSCAN that slightly differs from the version
available on this package. ... This parameter has been provided as a
means to compare the two implementations." The "reference" is the
original Campello et al. publication code; the current package is the
McInnes/Healy/Astels improvement. We match the *current* algorithm —
that's the algorithm everyone in academic + applied use targets in
2026.

**Why echo in JSON.** Same reason as Decision 1 — a future flip
surfaces as a config diff, not a label divergence.

### Decision 3 — `min_cluster_size=8` as the default hyperparameter seed

**What.** The CLI default and the AirPad service-boundary default both
seed `min_cluster_size = 8`. Tunable from the dev inspect view's
Stage 4b section.

**Why 8 and not the Python library default of 5.** AirPad's corpus
geometry post-UMAP is dense at the small-cluster end — 5-point
clusters would be barely-distinguishable noise pockets at the typical
corpus scale (200–600 nodes). 8 is the smallest size where a cluster
reads as "a coherent region" rather than "a knot of three plus their
neighbors." If real-corpus geometry shows we drift this needs to bump
to 10–12, that's a one-line change in `FeatureFlags` adjacent surface
(no flag yet — direct hyperparameter on the service).

**Why echo in JSON.** All hyperparameters echo in the output so the
fit is reproducible from the JSON alone.

---

## Reference reading — what the harness mirrors

Python `hdbscan` source (cloned to `/tmp/hdbscan-source/hdbscan/` at
scoping time, 2026-05-12) — the four phase files:

- `_hdbscan_reachability.pyx` — `mutual_reachability()`. Dense path is
  three lines of NumPy: pairwise distance, core distance per point,
  element-wise max(dist, core_i, core_j).
- `_hdbscan_linkage.pyx` — `mst_linkage_core()`. Prim's algorithm.
  Tie-breaking is `np.argmin` semantics (first minimum wins).
- `_hdbscan_tree.pyx` — `condense_tree`, `compute_stability`,
  `get_clusters` (EOM selection), `do_labelling`, `get_probabilities`.
- `hdbscan_.py` — orchestration. The `algorithm='best'` dispatcher
  lives here; `algorithm='generic'` routes through
  `_hdbscan_generic`.

The harness invokes the package's top-level `hdbscan.HDBSCAN` fitter,
not the internal phase functions. Per-phase intermediates (mutual
reachability matrix, MST edges, condensed tree) are accessible on the
fitted `clusterer` object — intermediates dump lands at 4b.1+.
