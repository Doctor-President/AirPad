import Foundation

// SB139 Stage 4a — UMAP entry points.
//
// Thin namespace over the UMAP pipeline. The actual algorithm is split into
// `UMAPRandom.swift` (xoshiro256** RNG), `UMAPGraph.swift` (k-NN +
// fuzzy simplicial set), `UMAPOptimization.swift` (SGD), each landing as a
// discrete sub-step per the SB139 Stage 4a checkpoint discipline. Each
// sub-step validates against the libscran/umappp C++ reference harness.
//
// This file currently exposes the API surface that SubstrateLayoutService
// calls into. Implementations precondition-fail so the call graph compiles
// and the dev inspect view can wire up its UI before any UMAP math lands.

enum UMAP {

    /// Fit a UMAP model on a set of (nodeID, 512-dim vector) pairs.
    ///
    /// Heavy compute — caller is expected to dispatch this off the main
    /// thread (`Task.detached`). Deterministic when `rngSeed` matches
    /// across calls.
    ///
    /// **Pipeline (Stage 4a step 4.5 — mirrors the harness `run_fit` in
    /// `umap-reference-harness/src/main.cpp:177-228`):**
    /// 1. Derive `(initSeed, optSeed)` from `rngSeed[0]` via SplitMix64.
    /// 2. Compute k-NN graph (`computeKnnGraph`).
    /// 3. Fuzzy simplicial set (`computeFuzzySimplicialSet`, defaults).
    /// 4. Curve-fit `(a, b)` (`umapFindAB`).
    /// 5. Random init the embedding (`umapRandomInit`, scale=10).
    /// 6. SGD (`umapOptimizeLayout`, num_epochs via `chooseUMAPNumEpochs`).
    /// 7. Cast each `(x, y)` pair to `SubstrateCoord2D` (Double → Float).
    ///
    /// **Seed contract.** `rngSeed` is `[UInt64]` of length 4 to keep the
    /// persisted shape stable across a future RNG swap, but the current
    /// MT19937-64 machinery is single-seed: only `rngSeed[0]` is consumed.
    /// The remaining 3 elements are persisted unchanged. See
    /// `UMAPFittedModel.rngSeed` for the schema rationale.
    ///
    /// **Hardcoded umappp defaults** (not on `UMAPHyperparameters`):
    /// `mixRatio = localConnectivity = bandwidth = gamma = 1.0`,
    /// `initializeRandomScale = 10`, `minKDistScale = 1e-3`. Match
    /// `synth_50x4.json` so harness parity holds. If AirPad ever needs
    /// to tune these, surface them onto `UMAPHyperparameters`.
    ///
    /// **Float-vs-Double note.** SGD runs in Double; coords are cast to
    /// Float at `SubstrateCoord2D` assembly. Bit-exact harness parity is
    /// validated in Double via `scripts/swift_fit_parity.swift` before the
    /// cast. The persisted Float coords lose ~7 ULPs by design (canvas
    /// rendering is single-precision); the persisted model is "fit-state",
    /// not a bit-parity record.
    ///
    /// `targetConstraints` is the cluster-blessing forward-compat hook
    /// (Consultation #1). Non-nil throws `targetConstraintsUnsupported`
    /// in 4a — the parameter exists to avoid a future schema/API
    /// migration if cluster-blessing activates.
    static func fit(
        trainingInputs: [(nodeID: String, vector: [Float])],
        hyperparameters: UMAPHyperparameters,
        rngSeed: [UInt64],
        targetConstraints: TargetConstraints? = nil,
        fitVersion: Int
    ) throws -> UMAPFittedModel {
        if targetConstraints != nil {
            throw UMAPError.targetConstraintsUnsupported
        }
        precondition(!rngSeed.isEmpty, "rngSeed must contain at least one element")
        precondition(hyperparameters.nComponents == 2,
                     "UMAP.fit only supports nComponents == 2 in Stage 4a")
        precondition(trainingInputs.count > hyperparameters.nNeighbors,
                     "trainingInputs count (\(trainingInputs.count)) must exceed nNeighbors (\(hyperparameters.nNeighbors))")

        // Step 1 — seed derivation. Only rngSeed[0] is consumed by the
        // current MT19937-64 + SplitMix64 path; remaining elements are
        // persisted-but-unused (schema-locked in 4a step 5C).
        let (initSeed, optSeed) = deriveUMAPSeeds(from: rngSeed[0])

        // Step 2 — k-NN graph.
        let vectors = trainingInputs.map { $0.vector }
        let knn = computeKnnGraph(vectors: vectors, k: hyperparameters.nNeighbors)

        // Step 3 — fuzzy simplicial set with umappp defaults.
        let fuzzy = computeFuzzySimplicialSet(knn: knn, options: UMAPFuzzyOptions())

        // Step 4 — curve fit (a, b).
        let ab = umapFindAB(
            spread: hyperparameters.spread,
            minDist: hyperparameters.minDist
        )

        // Step 5 — random init the embedding (Double, flat, per-obs strided).
        let numObs = trainingInputs.count
        let numDim = hyperparameters.nComponents
        var embedding = umapRandomInit(
            numObs: numObs,
            numDim: numDim,
            seed: initSeed,
            scale: 10.0
        )

        // Step 6 — SGD.
        let numEpochs = chooseUMAPNumEpochs(
            numObs: numObs,
            override: hyperparameters.nEpochs
        )
        umapOptimizeLayout(
            embedding: &embedding,
            fuzzy: fuzzy,
            numDim: numDim,
            a: ab.a,
            b: ab.b,
            gamma: 1.0,
            initialAlpha: hyperparameters.learningRate,
            negativeSampleRate: Double(hyperparameters.negativeSampleRate),
            numEpochs: numEpochs,
            optimizeSeed: optSeed,
            epochLimit: nil
        )

        // Step 7 — assemble. SubstrateCoord2D is Float; the Double→Float
        // cast is the documented precision floor for persisted coords.
        let inputDimension = trainingInputs[0].vector.count
        var points: [UMAPFittedModel.TrainingPoint] = []
        points.reserveCapacity(numObs)
        for i in 0..<numObs {
            let coord = SubstrateCoord2D(
                x: Float(embedding[i * numDim + 0]),
                y: Float(embedding[i * numDim + 1])
            )
            points.append(.init(
                nodeID: trainingInputs[i].nodeID,
                inputVector: trainingInputs[i].vector,
                coord2D: coord
            ))
        }

        return UMAPFittedModel(
            schemaVersion: UMAPFittedModel.currentSchemaVersion,
            fitVersion: fitVersion,
            fittedAt: Date(),
            hyperparameters: hyperparameters,
            rngSeed: rngSeed,
            inputDimension: inputDimension,
            a: ab.a,
            b: ab.b,
            trainingPoints: points
        )
    }

    /// Project a single new point through an existing fitted model.
    ///
    /// Standard "naive UMAP transform" (Stage 4a step 6): find the input
    /// vector's k-NN in the saved training-set 512-dim vectors, smoothed-
    /// exponential weighting via the same σ-search machinery as fit-time
    /// fuzzy SS, weighted-average their 2D coords. No re-optimization —
    /// existing positions stay frozen. Stage 4 design contract: "New
    /// nodes project through the saved model — they land at their honest
    /// spot without disturbing existing positions."
    ///
    /// Heavy lifting lives in `umapTransform` (`UMAPTransform.swift`);
    /// this wrapper handles the boundary precondition + the Double→Float
    /// cast at SubstrateCoord2D assembly.
    ///
    /// No C++ reference parity surface — umappp ships no transform
    /// method (verified 2026-05-11). Correctness gated by T14
    /// transform-then-refit round-trip self-test instead.
    static func transform(
        inputVector: [Float],
        through model: UMAPFittedModel
    ) throws -> SubstrateCoord2D {
        if inputVector.count != model.inputDimension {
            throw UMAPError.dimensionMismatch(
                expected: model.inputDimension,
                got: inputVector.count
            )
        }
        let (x, y) = umapTransform(inputVector: inputVector, through: model)
        return SubstrateCoord2D(x: Float(x), y: Float(y))
    }
}
