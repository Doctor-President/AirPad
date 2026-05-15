#!/usr/bin/env python3
"""HDBSCAN reference harness — CLI shell.

Reads a JSON fixture (2D points with nodeIDs), runs the canonical
Python `hdbscan` package with the pinned configuration
(`algorithm='generic'`, `match_reference_implementation=False`),
writes a JSON output keyed for parity diffing against the Swift port.

Subcommands:
- `fit` — end-to-end HDBSCAN fit. Output: cluster labels +
  probabilities + outlier scores per point.
- `intermediates` — per-phase dump. 4b.1 emits the pairwise
  distance matrix, per-point core distances, and the mutual
  reachability matrix. Subsequent phases (MST, condense tree,
  cluster selection) extend this output as they land.

The bypass-the-orchestrator design for `intermediates` is deliberate:
calling `pairwise_distances` + `mutual_reachability` directly gives
us a sharp per-step parity surface, mirroring how umap-reference-harness
factors per-step parity (`rng-dump`, `find-ab`, etc.).

Usage:
    python3 scripts/hdbscan_reference.py fit \\
        --input fixtures/synth_planted4_2d.json \\
        --output results/synth_planted4_2d.hdbscan.json

    python3 scripts/hdbscan_reference.py intermediates \\
        --input fixtures/synth_planted4_2d.json \\
        --output results/synth_planted4_2d.intermediates.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import hdbscan
import numpy as np

# Internal hdbscan symbols — mirror what `_hdbscan_generic` (in
# hdbscan_.py) calls when algorithm='generic'. Importing them directly
# rather than reaching into the fitted clusterer object means our
# intermediate dump matches the orchestrator's algorithmic surface
# exactly.
from hdbscan._hdbscan_reachability import mutual_reachability
from hdbscan._hdbscan_linkage import mst_linkage_core, label
from hdbscan._hdbscan_tree import condense_tree, compute_stability, get_clusters
from sklearn.metrics import pairwise_distances
from importlib.metadata import version as _pkg_version

_HDBSCAN_PKG_VERSION = _pkg_version("hdbscan")


# Pinned at the harness boundary; surface in the output JSON so a future
# divergence is a config-diff, not a label-divergence. See decisions.md.
ALGORITHM_PATH = "generic"
MATCH_REFERENCE_IMPLEMENTATION = False


def _load_input(path: Path) -> dict[str, Any]:
    with path.open("r") as f:
        payload = json.load(f)

    required = {"hyperparameters", "points"}
    missing = required - payload.keys()
    if missing:
        raise ValueError(f"input {path} missing required keys: {sorted(missing)}")

    # Echo back any pinned-config fields the fixture may have included,
    # but the canonical source of truth is this script's constants — if
    # the fixture disagrees, that's a config drift worth surfacing.
    fixture_algo = payload.get("algorithmPath", ALGORITHM_PATH)
    if fixture_algo != ALGORITHM_PATH:
        raise ValueError(
            f"fixture algorithmPath={fixture_algo!r} disagrees with "
            f"harness pin {ALGORITHM_PATH!r} — refusing to fit"
        )
    fixture_match = payload.get("matchReferenceImplementation", MATCH_REFERENCE_IMPLEMENTATION)
    if fixture_match != MATCH_REFERENCE_IMPLEMENTATION:
        raise ValueError(
            f"fixture matchReferenceImplementation={fixture_match!r} "
            f"disagrees with harness pin {MATCH_REFERENCE_IMPLEMENTATION!r}"
        )

    return payload


def _build_clusterer(hp: dict[str, Any]) -> hdbscan.HDBSCAN:
    return hdbscan.HDBSCAN(
        min_cluster_size=int(hp["min_cluster_size"]),
        min_samples=(None if hp.get("min_samples") is None else int(hp["min_samples"])),
        cluster_selection_method=hp.get("cluster_selection_method", "eom"),
        cluster_selection_epsilon=float(hp.get("cluster_selection_epsilon", 0.0)),
        allow_single_cluster=bool(hp.get("allow_single_cluster", False)),
        algorithm=ALGORITHM_PATH,
        match_reference_implementation=MATCH_REFERENCE_IMPLEMENTATION,
        # Pinning core_dist_n_jobs=1 keeps numerical ordering deterministic;
        # threaded core-distance can shuffle tie-broken neighbors. Reference
        # implementation behavior at small n.
        core_dist_n_jobs=1,
    )


def _do_fit(args: argparse.Namespace) -> None:
    payload = _load_input(Path(args.input))
    hp = payload["hyperparameters"]

    points = payload["points"]
    node_ids = [p["nodeID"] for p in points]
    coords = np.asarray([p["coord"] for p in points], dtype=np.float64)
    if coords.ndim != 2:
        raise ValueError(f"expected 2D coord array, got shape {coords.shape}")

    clusterer = _build_clusterer(hp)
    clusterer.fit(coords)

    labels = clusterer.labels_.tolist()
    probabilities = clusterer.probabilities_.tolist()
    outlier_scores = clusterer.outlier_scores_.tolist()

    output = {
        "fitterVersion": f"hdbscan-{_HDBSCAN_PKG_VERSION}",
        "hyperparameters": {
            "min_cluster_size": int(hp["min_cluster_size"]),
            "min_samples": hp.get("min_samples"),
            "cluster_selection_method": hp.get("cluster_selection_method", "eom"),
            "cluster_selection_epsilon": float(hp.get("cluster_selection_epsilon", 0.0)),
            "allow_single_cluster": bool(hp.get("allow_single_cluster", False)),
        },
        "algorithmPath": ALGORITHM_PATH,
        "matchReferenceImplementation": MATCH_REFERENCE_IMPLEMENTATION,
        "inputDimension": int(coords.shape[1]),
        "points": [
            {
                "nodeID": node_ids[i],
                "clusterLabel": int(labels[i]),
                "probability": float(probabilities[i]),
                "outlierScore": float(outlier_scores[i]),
            }
            for i in range(len(node_ids))
        ],
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(output, f, indent=2, sort_keys=True)
    print(f"wrote {out_path} ({len(node_ids)} points, "
          f"{len(set(labels)) - (1 if -1 in labels else 0)} clusters + "
          f"{labels.count(-1)} noise)")


def _eom_select_mirror(condensed_recarray, stability: dict[int, float]) -> list[int]:
    """Inline mirror of `get_clusters`' EOM branch under our pinned config.

    Returns the sorted-ascending list of selected internal cluster IDs.
    Mutates `stability` in place — eliminated parents get their value
    replaced by the subtree-sum, matching upstream's mutation pattern at
    `_hdbscan_tree.pyx` line 828.

    Scope: only the path reachable under
      `cluster_selection_method='eom'`, `allow_single_cluster=False`,
      `cluster_selection_epsilon=0.0`, `max_cluster_size=0`,
      `cluster_selection_epsilon_max=inf`.

    The Swift port targets this same minimal path; the assertion in
    `_do_intermediates` that this mirror's selection agrees with upstream
    `get_clusters` is the safety net.
    """
    node_list = sorted([int(k) for k in stability.keys()], reverse=True)[:-1]
    cluster_tree = condensed_recarray[condensed_recarray["child_size"] > 1]
    is_cluster = {int(c): True for c in node_list}

    for node in node_list:
        children = cluster_tree["child"][cluster_tree["parent"] == node]
        subtree_stability = float(sum(stability[int(c)] for c in children))
        if subtree_stability > stability[node]:
            # Strict greater — ties go to the parent (line 826 upstream).
            is_cluster[node] = False
            stability[node] = subtree_stability
        else:
            # Descendants in cluster_tree are eliminated; mirror upstream's
            # `bfs_from_cluster_tree(cluster_tree, node)` walk.
            to_process = np.array([node], dtype=np.intp)
            while to_process.shape[0] > 0:
                for sub in to_process:
                    sub_int = int(sub)
                    if sub_int != node and sub_int in is_cluster:
                        is_cluster[sub_int] = False
                to_process = cluster_tree["child"][
                    np.isin(cluster_tree["parent"], to_process)
                ]

    return sorted(c for c in is_cluster if is_cluster[c])


def _resolve_min_points(hp: dict[str, Any], n: int) -> int:
    """Mirror hdbscan_.py orchestrator's min_samples resolution.

    - `min_samples=None` → defaults to `min_cluster_size` (hdbscan_.py:714-715).
    - `match_reference_implementation=False` (our pin) → no decrement.
    - Post-clamp: `min_samples = min(n - 1, min_samples)`.
    - Post-floor: `if min_samples == 0: min_samples = 1`.
    """
    raw = hp.get("min_samples")
    min_samples = int(hp["min_cluster_size"]) if raw is None else int(raw)
    min_samples = min(n - 1, min_samples)
    if min_samples == 0:
        min_samples = 1
    return min_samples


def _do_intermediates(args: argparse.Namespace) -> None:
    payload = _load_input(Path(args.input))
    hp = payload["hyperparameters"]

    points = payload["points"]
    node_ids = [p["nodeID"] for p in points]
    coords = np.asarray([p["coord"] for p in points], dtype=np.float64)
    if coords.ndim != 2:
        raise ValueError(f"expected 2D coord array, got shape {coords.shape}")
    n = coords.shape[0]

    min_points = _resolve_min_points(hp, n)

    # Mirror _hdbscan_generic at metric='minkowski', p=2: calls
    # `pairwise_distances(X, metric='minkowski', p=2)`. sklearn routes
    # minkowski-with-p through scipy.spatial.distance.cdist, which uses
    # the direct `sqrt(sum((x_k - y_k)^2))` formulation (NOT the
    # `||x||² + ||y||² - 2x·y` shortcut that 'euclidean' metric uses).
    # The direct formulation is the bit-exact target for the Swift port.
    distance_matrix = pairwise_distances(coords, metric="minkowski", p=2)

    # Replicates mutual_reachability()'s np.partition step independently,
    # so the dump records core_distances explicitly. The reference call
    # below would recompute these internally; capturing them separately
    # gives the Swift port a finer-grained parity surface.
    clamped_min_points = min(n - 1, min_points)
    core_distances = np.partition(distance_matrix, clamped_min_points, axis=0)[clamped_min_points]

    mr = mutual_reachability(distance_matrix, min_points=min_points, alpha=1.0)

    # Phase B: MST via Prim's on the mutual reachability matrix.
    # mst_linkage_core records each new edge as
    #   [current_node, new_node, current_distances[new_node_index]]
    # — where `current_node` is the most recently added tree node, NOT
    # necessarily the actual MST source of `new_node`. label() ignores
    # that distinction since UF only cares about the component each
    # endpoint belongs to.
    mst_edges = mst_linkage_core(mr)

    # Phase C: sort MST by distance, then UnionFind label() → SLT.
    #
    # Upstream `single_linkage` uses `np.argsort(...)` with default kind
    # (introsort, unstable). On real-valued embeddings ties are rare but
    # not zero — synth_planted4_2d.json has 14/199 edges sharing a
    # distance, putting us inside tie-breaking territory.
    #
    # The harness pins `kind='stable'` (timsort) so that the dumped SLT
    # is deterministic by *original MST discovery order* on ties. The
    # Swift port mirrors with a stable sort (insertion/merge on edge
    # index). This is a deliberate divergence from upstream's unstable
    # default — surfaces as a potential at 4b.4 when cluster labels are
    # compared against `hdbscan.fit()` directly. At `min_cluster_size=8`
    # the cluster boundary is far from any single tied edge, so label
    # drift is not expected; but documenting here so the 4b.4 gate is
    # debuggable if it ever fails.
    sort_order = np.argsort(mst_edges[:, 2], kind="stable")
    mst_edges_sorted = mst_edges[sort_order, :]
    slt = label(mst_edges_sorted)

    # Phase D (4b.3): condense_tree.
    #
    # Upstream `condense_tree(slt, min_cluster_size)` returns a numpy
    # recarray with columns (parent, child, lambda_val, child_size).
    # When two SLT-merged nodes are coincident (distance == 0), lambda
    # is np.inf — standard JSON cannot encode that, so we split into a
    # (lambdaVal: float, isInfiniteLambda: bool) pair per the schema
    # T locked in: lambdaVal carries 0.0 when isInfiniteLambda is true.
    # The flag is the source of truth; the 0.0 sentinel is documentation.
    min_cluster_size = int(hp["min_cluster_size"])
    condensed_recarray = condense_tree(slt, min_cluster_size=min_cluster_size)
    condensed_rows = []
    for row in condensed_recarray:
        lambda_raw = float(row["lambda_val"])
        is_inf = not np.isfinite(lambda_raw)
        condensed_rows.append({
            "parent": int(row["parent"]),
            "child": int(row["child"]),
            "lambdaVal": 0.0 if is_inf else lambda_raw,
            "isInfiniteLambda": is_inf,
            "childSize": int(row["child_size"]),
        })

    # Phase E (4b.4): stability + EOM cluster selection + labels + probabilities.
    #
    # `compute_stability` returns a dict {internal_cluster_id: stability}
    # for every internal cluster. EOM mutates this in place for ELIMINATED
    # parents (replacing their stability with subtree_stability) but leaves
    # SELECTED clusters' values unchanged — we dump both snapshots so the
    # Swift parity gate can diff cleanly either direction.
    #
    # `get_clusters` is the upstream truth source for labels/probs/persistence.
    # It doesn't return cluster_map or the selected-internal-IDs set, so we
    # inline a minimal-EOM mirror to expose those for parity. Our inline
    # mirror only handles the pinned-config path (eom, no epsilon, no
    # max_cluster_size, no allow_single_cluster) — same scope as the Swift
    # port. If unrelated config drifts in, get_clusters' result will diverge
    # from this mirror and we'll catch it at the labels diff.
    stability_pre_eom = compute_stability(condensed_recarray)
    stability_for_mirror = {int(k): float(v) for k, v in stability_pre_eom.items()}
    selected_internal_ids = _eom_select_mirror(condensed_recarray, stability_for_mirror)
    stability_post_eom = dict(stability_for_mirror)
    cluster_map_internal = {c: n for n, c in enumerate(selected_internal_ids)}

    # Upstream `get_clusters` gets its own copy of stability so its in-place
    # mutation doesn't muddy our captured pre/post snapshots.
    stability_for_upstream = {int(k): float(v) for k, v in stability_pre_eom.items()}
    upstream_labels, upstream_probs, upstream_persistence = get_clusters(
        condensed_recarray, stability_for_upstream,
        cluster_selection_method=hp.get("cluster_selection_method", "eom"),
        allow_single_cluster=bool(hp.get("allow_single_cluster", False)),
        match_reference_implementation=MATCH_REFERENCE_IMPLEMENTATION,
        cluster_selection_epsilon=float(hp.get("cluster_selection_epsilon", 0.0)),
    )
    # Sanity check: the inline mirror's selected count must match the
    # upstream label set. If this fails, our mirror has drifted from
    # get_clusters and the bug is here, not in Swift.
    unique_non_noise = sorted(set(int(x) for x in upstream_labels) - {-1})
    assert unique_non_noise == list(range(len(selected_internal_ids))), (
        f"inline EOM mirror disagrees with upstream get_clusters: "
        f"mirror selected k={len(selected_internal_ids)}, "
        f"upstream unique labels={unique_non_noise}"
    )

    # Tie-detection telemetry — purely diagnostic, not consumed by Swift.
    dist_col = mst_edges[:, 2]
    n_tied_pairs = int(np.sum(dist_col[:-1] == np.sort(dist_col)[:-1])) if dist_col.size > 1 else 0
    unique_distances = int(np.unique(dist_col).size)

    output = {
        "fitterVersion": f"hdbscan-{_HDBSCAN_PKG_VERSION}",
        "hyperparameters": {
            "min_cluster_size": int(hp["min_cluster_size"]),
            "min_samples": hp.get("min_samples"),
            "cluster_selection_method": hp.get("cluster_selection_method", "eom"),
            "cluster_selection_epsilon": float(hp.get("cluster_selection_epsilon", 0.0)),
            "allow_single_cluster": bool(hp.get("allow_single_cluster", False)),
        },
        "algorithmPath": ALGORITHM_PATH,
        "matchReferenceImplementation": MATCH_REFERENCE_IMPLEMENTATION,
        "inputDimension": int(coords.shape[1]),
        "minPointsResolved": int(min_points),
        "nodeIDs": node_ids,
        "intermediates": {
            "pairwiseDistance": distance_matrix.tolist(),
            "coreDistances": core_distances.tolist(),
            "mutualReachability": mr.tolist(),
            # MST edges in Prim discovery order — (n-1, 3) [current_node, new_node, dist].
            "mstEdges": mst_edges.tolist(),
            "mstEdgesSortOrder": sort_order.tolist(),
            # SLT after sort + UnionFind label — (n-1, 4) [a, b, dist, size].
            "singleLinkageTree": slt.tolist(),
            # Condensed tree from condense_tree(slt, min_cluster_size).
            # Each row carries the schema T locked in:
            #   parent, child, lambdaVal, isInfiniteLambda, childSize.
            # Rows are in BFS-from-root emission order (preserved on disk).
            "condensedTree": condensed_rows,
            "condensedTreeMinClusterSize": min_cluster_size,
            # Phase E (4b.4) — stability + EOM + labels + probabilities.
            #
            # `stabilityPreEOM` is `compute_stability(condensed)`'s output
            # before EOM mutation: dict {internal_cluster_id: stability}
            # for every internal cluster (root inclusive).
            #
            # `stabilityPostEOM` captures the mutated state after our
            # inline EOM mirror: identical to pre for SELECTED clusters,
            # subtree-sum-replaced for ELIMINATED parents.
            #
            # Swift parity gate diffs the dicts by sorted key, treating
            # each (clusterID, value) pair as bit-exact. JSON requires
            # string keys → coerce via `str(int(...))` on serialization.
            "stabilityPreEOM": {str(int(k)): float(v) for k, v in stability_pre_eom.items()},
            "stabilityPostEOM": {str(int(k)): float(v) for k, v in stability_post_eom.items()},
            "selectedInternalClusterIDs": list(selected_internal_ids),
            "clusterMap": {str(int(c)): int(n) for c, n in cluster_map_internal.items()},
            "labels": [int(x) for x in upstream_labels],
            "probabilities": [float(x) for x in upstream_probs],
            # `selectedClusterStabilityScores` is `get_stability_scores`'s
            # output: length-k array indexed by renumbered cluster ID
            # (0..k-1). NOT the raw stability dict — this one is normalized
            # by (cluster_size * max_lambda). Per-cluster persistence
            # surface for the dev inspect view.
            "selectedClusterStabilityScores": [float(x) for x in upstream_persistence],
            # Tie-breaking telemetry (not consumed by Swift; surface for diagnostics).
            "mstDistanceUniqueCount": unique_distances,
            "mstDistanceTotalCount": int(dist_col.size),
        },
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(output, f, indent=2, sort_keys=True)
    n_inf_rows = sum(1 for r in condensed_rows if r["isInfiniteLambda"])
    n_noise = sum(1 for x in upstream_labels if int(x) == -1)
    print(f"wrote {out_path} (n={n}, minPointsResolved={min_points}, "
          f"distance_matrix={distance_matrix.shape}, "
          f"core_distances range=[{core_distances.min():.6f}, {core_distances.max():.6f}], "
          f"mr range=[{mr.min():.6f}, {mr.max():.6f}], "
          f"mst_unique_distances={unique_distances}/{dist_col.size}, "
          f"condensed_rows={len(condensed_rows)} (infinite λ: {n_inf_rows}), "
          f"clusters={len(selected_internal_ids)} (noise: {n_noise}))")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fit = sub.add_parser("fit", help="end-to-end HDBSCAN fit on the input fixture")
    p_fit.add_argument("--input", required=True, help="path to input JSON")
    p_fit.add_argument("--output", required=True, help="path to output JSON")
    p_fit.set_defaults(func=_do_fit)

    p_int = sub.add_parser("intermediates", help="per-phase intermediate dump for Swift parity")
    p_int.add_argument("--input", required=True, help="path to input JSON")
    p_int.add_argument("--output", required=True, help="path to output JSON")
    p_int.set_defaults(func=_do_intermediates)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
