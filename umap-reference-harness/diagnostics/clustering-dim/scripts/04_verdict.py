#!/usr/bin/env python3
"""
Read the diagnostic + control results and render a verdict.

The brief framed the question as: "embedder fault vs pipeline (2D collapse) fault?"
The controls (script 03) revealed a third axis the brief didn't anticipate: the
whitening configuration is rank-saturating at this (N=120, D=512) regime,
which makes the embedder-vs-2D framing un-measurable from the primary diagnostics
alone. The verdict articulates all three.
"""
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent / "results"


def main():
    sweep = json.load(open(RESULTS / "sweep_results.json"))
    controls = json.load(open(RESULTS / "controls_results.json"))

    n = sweep["nPoints"]
    keep_shipped = sweep["whiteningKeep"]
    raw_stats = controls["raw"]["cosineStats"]
    cutoff_sweep = controls["whiteningCutoffSweep"]
    raw_sweep = controls["rawSweep"]
    whitened_sweep = sweep["configs"]

    def cluster_summary(labels):
        a = np.asarray(labels)
        n_total = len(a)
        n_noise = int((a == -1).sum())
        n_clusters = int(a.max() + 1) if (a >= 0).any() else 0
        return n_clusters, n_noise, n_total

    lines = []
    lines.append("# Verdict — clustering-dimensionality-diagnostic\n")
    lines.append("**Brief workstream:** ws-embedder-evaluation. **Goal:** decide whether recipe-")
    lines.append("scatter wrong-membership comes from clustering on 2D UMAP output (pipeline bug,")
    lines.append("free fix) or NLContextualEmbedding's compressed geometry (embedder bug, swap).")
    lines.append("")
    lines.append(f"**Corpus snapshot:** N = {n} rankable nodes, D = 512 (block-pooled).")
    lines.append("Block-pooled vector coverage = 100% (every kept node had a block sidecar).")
    lines.append("Dropped: 4 meta, 7 thin_content. 27 guardrail-refused nodes were kept (they")
    lines.append("have block embeddings via the content/block path, same as shipped).\n")

    lines.append("## Headline\n")
    lines.append("**Neither answer the brief proposed is correct in isolation. The shipped")
    lines.append("`SubstrateWhitening` configuration is mathematically degenerate at AirPad's")
    lines.append("(N=120, D=512) regime — it destroys all pairwise distance information before")
    lines.append("UMAP runs, making the embedder-vs-2D question un-measurable from the")
    lines.append("currently-shipped pipeline alone.** Underneath that, the embedder DOES have a")
    lines.append("real ceiling (raw geometry tops out at ~2–4 clusters total), but the bottleneck")
    lines.append("is being doubled by a fixable pipeline bug. Order of operations: fix whitening")
    lines.append("first, then re-measure the embedder ceiling against actually-non-degenerate input.\n")

    lines.append("## Evidence\n")

    # 1. The whitening saturation finding
    lines.append("### 1. The shipped whitening produces an isotropic point cloud.\n")
    lines.append("With N=120 and the 1e-6 relative singular-value cutoff in `SubstrateWhitening`,")
    lines.append(f"`keep = {keep_shipped}` (= N − 1 = full rank of the centered matrix). Dividing every")
    lines.append("surviving singular component by its σ produces a whitened cloud where:")
    lines.append("")
    lines.append("| keep | pairwise cosine p10 | p50 | p90 | spread (p90−p10) |")
    lines.append("|---:|---:|---:|---:|---:|")
    lines.append(f"| raw (no whitening) | {raw_stats['p10']:+.4f} | {raw_stats['p50']:+.4f} | "
                 f"{raw_stats['p90']:+.4f} | {raw_stats['p90']-raw_stats['p10']:.4f} |")
    for w in cutoff_sweep:
        if "p10" not in w:
            continue
        marker = "  ← **shipped**" if w["keep"] == keep_shipped else ""
        lines.append(f"| {w['keep']} | {w['p10']:+.4f} | {w['p50']:+.4f} | "
                     f"{w['p90']:+.4f} | {w['p90']-w['p10']:.4f}{marker} |")
    lines.append("")
    lines.append("At the shipped `keep=119` cutoff, all 14,280 off-diagonal pairs have cosine ≈ −0.0083")
    lines.append("(= −1/N exactly, the algebraic signature of `whitened = U[:, :keep]` from the centered")
    lines.append("SVD when `keep = N − 1`). Every point is equidistant from every other point in")
    lines.append("Euclidean space too. UMAP's k-NN graph cannot bind on anything; HDBSCAN sees random")
    lines.append("density. The cluster membership produced by the shipped pipeline is essentially RNG-")
    lines.append("driven (UMAP's spectral init breaks ties pseudo-randomly via floating-point).\n")

    lines.append("This is not the embedder's compressed cone. The embedder produces real, low-spread")
    lines.append(f"structure (raw p10–p90 = {raw_stats['p90']-raw_stats['p10']:.3f}, matching prior")
    lines.append("measurement of 0.153). The whitening pass takes that low-spread structure and")
    lines.append("over-corrects it to zero spread.\n")

    # 2. Raw-input UMAP+HDBSCAN sweep
    lines.append("### 2. Bypassing whitening recovers some — but limited — structure.\n")
    lines.append("With whitening **disabled** (UMAP run directly on raw block-pooled vectors, cosine")
    lines.append("metric to respect the embedder's cone geometry):\n")
    lines.append("| nComponents | clusters | noise | noise rate |")
    lines.append("|---:|---:|---:|---:|")
    for r in raw_sweep:
        nc_count, n_noise, n_total = cluster_summary(r["labels"])
        lines.append(f"| {r['n_components']} | {nc_count} | {n_noise} | {n_noise/n_total:.0%} |")
    lines.append("")
    lines.append("Compared against the whitened sweep (the shipped pipeline path):\n")
    lines.append("| nComponents | clusters | noise | noise rate |")
    lines.append("|---:|---:|---:|---:|")
    for r in whitened_sweep:
        nc_count, n_noise, n_total = cluster_summary(r["labels"])
        lines.append(f"| {r['nComponents']} | {nc_count} | {n_noise} | {n_noise/n_total:.0%} |")
    lines.append("")
    lines.append("Raw-input results are stable across dimensionality (mostly one giant cluster of")
    lines.append("~112 + 8 outliers, with a 4-cluster split at nC=8). Whitened results are unstable")
    lines.append("(3 → 4 → 2 → 3 → 0 clusters) because the whitened input is degenerate noise — RNG")
    lines.append("drives the count.\n")
    lines.append("**Implication for the brief's framing:** the brief's nC=2 vs higher comparison")
    lines.append("can't distinguish embedder from pipeline because BOTH branches of the comparison")
    lines.append("are running on the degenerate input. The raw control is the apples-to-apples")
    lines.append("dimensionality test, and it shows nC has almost no effect — the cluster count is")
    lines.append("set by the embedder, not the projection dim.\n")

    # 3. Raw neighbor inspection
    lines.append("### 3. Embedder ceiling: raw neighbors are partially coherent.\n")
    lines.append("Top-cosine neighbors on raw block-pooled vectors (see `neighbors_raw.md` for")
    lines.append("the full per-node listing). Eyeball summary:\n")
    lines.append("- **Tech/feature nodes find tech/feature neighbors well.** `✨QuikCapture` →")
    lines.append("  `Network-Aware Dashboard`, `Universal Canvas Tap Model`, `Web Clipper` — all")
    lines.append("  AirPad/feature-flavored.")
    lines.append("- **Concrete-object nodes find related concrete objects.** `Vertical Farming")
    lines.append("  Future` → `Eco-Friendly Tech Lifecycle`, `Sky Cities`, `Sustainable Living`.")
    lines.append("- **Abstract/idea nodes scatter.** `Food as a Human Right` → `Diet Coke")
    lines.append("  Psychology`, `Golf Satire with Psychopathy`, `Optimistic Dog Series` — none")
    lines.append("  food-related. The cone-compression bites hardest for abstract/short-summary nodes.\n")
    lines.append("Top-10 cosines all sit in the +0.78–+0.94 band — every pair is \"very similar\".")
    lines.append("That's the compressed-cone signature: the embedder can rank, but the absolute")
    lines.append("separation is too narrow for HDBSCAN's density estimator to find robust clusters.")
    lines.append("This is the embedder ceiling. Even with whitening fixed, raw-input clustering")
    lines.append("tops out at 2–4 clusters (table above), and most members go into one giant bucket.\n")

    # 4. Verdict
    lines.append("## Verdict — order of fixes\n")
    lines.append("**(1) Pipeline fix: tighten `SubstrateWhitening`'s cutoff. Free; immediate.**")
    lines.append("The 1e-6 *relative* cutoff is the wrong rule at this regime. With N ≪ D, the")
    lines.append("centered matrix has rank N−1 and every surviving σ contributes a noise axis. Cap")
    lines.append("`keep` at something much smaller — e.g. `min(N/4, 30)` or an absolute σ floor")
    lines.append("based on the noise estimate. The whitening cutoff sweep shows:")
    lines.append("")
    lines.append("- keep ≤ 50 restores a healthy bipolar cosine distribution (p10 ≈ −0.14, p90 ≈ +0.14).")
    lines.append("- keep ≈ 20–30 lands in the ~0.5 spread band the `SubstrateWhitening` docstring")
    lines.append("  describes as the geometric headroom HDBSCAN needs.")
    lines.append("")
    lines.append("This needs to happen FIRST, before any further evaluation. Whatever cluster")
    lines.append("membership the app currently produces is RNG, not signal. (The `keep=20–30` zone")
    lines.append("matches the dimensionality-sweep dims the brief asked about — once whitening is")
    lines.append("fixed, the brief's nC sweep becomes the right second-pass diagnostic.)\n")
    lines.append("**(2) Re-measure the embedder ceiling on actually-whitened input.**")
    lines.append("Raw-input controls show the embedder produces ~2–4 cluster signal and one giant")
    lines.append("bucket. The whitening was supposed to lift that ceiling. Re-run the sweep with")
    lines.append("tightened whitening and check whether recipe-scatter membership becomes coherent.")
    lines.append("Re-run this diagnostic harness as the verification — the scripts are re-runnable")
    lines.append("any time.\n")
    lines.append("**(3) Embedder swap only if (1)+(2) still don't recover recipe membership.**")
    lines.append("The compressed cone IS real for abstract/short-summary nodes (see #3 above).")
    lines.append("If post-fix membership still scatters recipes across clusters, the bottleneck is")
    lines.append("genuinely the embedder and BGE-small/E5/etc become the next experiment. But that's")
    lines.append("step 3, not step 1 — the prior memory `feedback_nlcontextual_embedding_cluster_ceiling`")
    lines.append("recorded the ceiling diagnosis BEFORE whitening shipped, and the present diagnostic")
    lines.append("shows whitening as shipped is not actually exercising the embedder's geometry.\n")

    lines.append("## What the brief's framing missed\n")
    lines.append("The brief's two-axis framing (\"embedder vs 2D collapse\") was correct as far as")
    lines.append("it went, but the controls revealed that BOTH axes of the brief's framing measure")
    lines.append("the same degenerate input. Diagnostic A (whitened cosine neighbors) returns")
    lines.append("constant −1/N for every pair, which is neither \"recipe neighbors are recipes\"")
    lines.append("nor \"recipe neighbors are tech\" — it's the absence of any neighborhood structure")
    lines.append("at all. Diagnostic B's nC=2 vs higher comparison is similarly un-measurable")
    lines.append("because the whitened input is rotation-invariant random noise; HDBSCAN's output")
    lines.append("depends on UMAP's RNG, not on nC. The brief's `nComponents=2 should reproduce")
    lines.append("the bad membership` baseline was checked: it produces 3 clusters with 43% noise,")
    lines.append("but those clusters are not stable across reruns and have no semantic meaning.\n")
    lines.append("The diagnostic-as-spec'd would have given a false negative on the pipeline-bug")
    lines.append("axis: \"whitened neighbors are random, embedder is broken.\" The controls catch it.\n")

    lines.append("## Files\n")
    lines.append("- `neighbors.md` — diagnostic A as spec'd (whitened cosine top-10). Reads as")
    lines.append("  uniform noise; see verdict above.")
    lines.append("- `neighbors_raw.md` — control A0 (raw cosine top-10). The actual embedder output.")
    lines.append("- `sweep.md` — diagnostic B as spec'd (whitening → UMAP@{2..15} → HDBSCAN).")
    lines.append("- `sweep_raw.md` — control B0 (no whitening). The apples-to-apples nC sweep.")
    lines.append("- `whitening_sweep.md` — control A1 (cosine geometry at keep ∈ {5,10,20,50,119}).")
    lines.append("- `sweep_results.json`, `controls_results.json` — machine-readable for re-analysis.")

    (RESULTS / "verdict.md").write_text("\n".join(lines))
    print(f"wrote {RESULTS / 'verdict.md'}")


if __name__ == "__main__":
    main()
