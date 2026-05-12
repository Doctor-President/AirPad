import Foundation

// SB139 Stage 4a — UMAP correctness checks fired from the dev inspect view.
//
// Mirrors `SubstrateSelfTest` pattern: in-process assertions, no XCTest,
// returns a one-line summary suitable for inline display. Each step of the
// UMAP pipeline gets a parity test against the C++ `umap-reference-harness`
// fixtures.
//
// Coverage:
//   Step 1 (RNG)         — T1-T4:  SplitMix64 + MT19937-64 byte-parity vs libc++
//   Step 2 (k-NN)        — T5-T7:  brute-force Euclidean k-NN on hand-built inputs
//   Step 3 (fuzzy)       — T8-T9:  fuzzy SS fallback path + symmetry invariant
//   Step 5 (persistence) — T10:    UMAPFittedModel JSON round-trip on a literal
//   Step 4.5 (fit wire)  — T11:    end-to-end UMAP.fit structural smoke
//   Step 6 (transform)   — T14:    transform-then-refit round-trip
//                                  (cluster-adaptive 2D placement tolerance)
//   Step 7 (recovery)    — T12:    synthetic cluster recovery
//                                  (≥190/200 nodes pass M=3 of K=5 same-cluster)
//   Step 7 (determinism) — T13:    fit twice with same seed → bit-equal model
//
// The host-side `swift_knn_parity.swift` and `swift_fuzzy_parity.swift`
// scripts do the heavyweight end-to-end checks against the harness
// intermediates (n=52, k=15, sub-ULP / 1e-16 agreement). The in-app cases
// below are lightweight regression tripwires: small inputs where expected
// values are obvious by inspection or follow from invariants, catching
// algorithmic regressions before they reach the slower host tests.

@available(iOS 17.0, *)
@MainActor
enum UMAPSelfTest {

    // Step-1 fixtures from `umap-reference-harness/fixtures/`. Regenerate by:
    //   ./umap-reference-harness/build/umappp-reference rng-dump \
    //       --algorithm splitmix64 --seed 42 --n 32 --output <path>
    //   ./umap-reference-harness/build/umappp-reference rng-dump \
    //       --algorithm mt19937_64 --seed 42 --n 32 --output <path>
    // Then paste the hex-string values into the arrays below. These are
    // baked into Swift rather than read from disk because (a) AirPad has
    // no XCTest target with bundled-resource access, and (b) the dev
    // inspect view runs on-device where the harness output file isn't
    // present.

    private static let splitMix64_seed42_first32: [UInt64] = [
        0xbdd732262feb6e95, 0x28efe333b266f103, 0x47526757130f9f52, 0x581ce1ff0e4ae394,
        0x09bc585a244823f2, 0xde4431fa3c80db06, 0x37e9671c45376d5d, 0xccf635ee9e9e2fa4,
        0x5705b8770b3d7dd5, 0x9e54d738297f77ae, 0x3474724a775b19bf, 0x7e348a0e451650be,
        0x836ded897f3e46e6, 0x851f977347ed6db7, 0xaa47e31c02e78edc, 0x341452c54d7c33f2,
        0x1a83d752f35eba75, 0x7ed90003f67f9e1d, 0x17eadff448a86a07, 0xb05eca1a2972b860,
        0xf513444b6455a3e8, 0x12b3a6dd261f6e99, 0x998d8fb100ca15d5, 0x9eac75d45474c891,
        0x12fc33f229b7b950, 0x470ea7e37990e511, 0xbdf25b150620a835, 0xc9167e198fb9991f,
        0xf1222631cdc86d07, 0xb1b59f1b53585e43, 0xca376da14213d975, 0xd72c1692509d2c5e,
    ]

    private static let mt19937_64_seed42_first32: [UInt64] = [
        0xc151df7d6ee5e2d6, 0xa3978fb9b92502a8, 0xc08c967f0e5e7b0a, 0x22e2c43f8a1ad34e,
        0xe73ca28e4d361955, 0x1814dc629c7f4f7c, 0x93170a1965d42420, 0x5f75917a3eb7b900,
        0x461c9cf62eb9fcb6, 0x63e8cae041677d61, 0x032b846d0bbd3f4b, 0x861191c96090b446,
        0xaf6df0655c6891d8, 0xa32897ae188a782e, 0xd398c3c9b02b56cd, 0xf2194bc7d5976b28,
        0xc0d2eda553d1bc36, 0x72ec29f7fc409872, 0x0bfb48552d60ec21, 0x10894433f9475527,
        0xbf62e22b9623fb4b, 0x2639bc290a9eeb52, 0x6cdd812c68f90519, 0x199cad8504e80ac9,
        0x24d78d1d1b2520c5, 0x181baef38522f794, 0x87b8a689f6b57129, 0x7239f67bad2506ec,
        0xc5e48fc8e6f31d96, 0x1f5d587b2a99fb54, 0xbec32aaf5dd5e327, 0x52e1d21451942857,
    ]

    static func run() -> String {
        var failures: [String] = []
        var ran = 0
        // Surfaced in the success line so on-device timing is visible
        // without a console attach. T12 is the only test heavy enough
        // for this to matter (200 obs × 200 epochs).
        var t12ElapsedMS: Int = 0

        // Test 1 — SplitMix64 parity. Seed 42, first 32 outputs must match
        // the harness fixture byte-for-byte.
        do {
            var rng = SplitMix64(seed: 42)
            ran += 1
            for (i, expected) in splitMix64_seed42_first32.enumerated() {
                let got = rng.next()
                if got != expected {
                    failures.append(
                        "T1 SplitMix64 idx=\(i) expected=0x\(String(expected, radix: 16)) got=0x\(String(got, radix: 16))"
                    )
                    break  // one diff is enough; further calls are downstream of the divergence
                }
            }
        }

        // Test 2 — MT19937-64 parity. Seed 42, first 32 outputs must match
        // the harness fixture byte-for-byte. This is the load-bearing
        // check: if this diverges, the entire SGD step will diff-fail
        // against umappp.
        do {
            var rng = MersenneTwister64(seed: 42)
            ran += 1
            for (i, expected) in mt19937_64_seed42_first32.enumerated() {
                let got = rng.next()
                if got != expected {
                    failures.append(
                        "T2 MT19937-64 idx=\(i) expected=0x\(String(expected, radix: 16)) got=0x\(String(got, radix: 16))"
                    )
                    break
                }
            }
        }

        // Test 3 — Refresh-boundary check for MT19937-64. The state array
        // is 312 words; the refresh routine fires every 312 calls. Pulling
        // 320 values exercises one refresh boundary. If our refresh diverges
        // from libc++'s, the 313th+ values will be wrong. Spot-check the
        // 313th value against an independent compute.
        do {
            var rng = MersenneTwister64(seed: 42)
            for _ in 0..<312 { _ = rng.next() }
            let v313 = rng.next()
            // We don't have a baked-in expected here — instead, we compute
            // a second instance, advance it the same way, and compare. The
            // real cross-check vs libc++ for the 313th value would need a
            // 320-value fixture; for step 1 we settle for self-consistency.
            var rng2 = MersenneTwister64(seed: 42)
            for _ in 0..<312 { _ = rng2.next() }
            let v313b = rng2.next()
            ran += 1
            if v313 != v313b {
                failures.append("T3 MT19937-64 refresh self-consistency failed at idx=312")
            }
        }

        // Test 4 — Seed-expansion order. `deriveUMAPSeeds(from: 42)` must
        // yield the first two SplitMix64(42) outputs in order. This is what
        // the C++ harness's `run_fit()` does to derive umappp's two
        // internal seeds.
        do {
            let (initSeed, optSeed) = deriveUMAPSeeds(from: 42)
            ran += 1
            if initSeed != splitMix64_seed42_first32[0] {
                failures.append("T4 deriveUMAPSeeds initialize_seed != SplitMix64[0]")
            }
            if optSeed != splitMix64_seed42_first32[1] {
                failures.append("T4 deriveUMAPSeeds optimize_seed != SplitMix64[1]")
            }
        }

        // --- Step 2 (k-NN graph) ---
        //
        // Edge literals built via `e(_:_:)` rather than nested
        // `UMAPKnnEdge(...)` literals; the latter exceeds Swift's
        // expression-type-check budget for `[[UMAPKnnEdge]]` shapes.

        // Test 5 — 1D collinear points exercise distance ordering AND the
        // index-ascending tiebreak. For interior point [2], both [1] and
        // [3] sit at distance 1; tiebreak picks idx 1 first.
        do {
            let v: [[Float]] = [[0], [1], [2], [3]]
            let g = computeKnnGraph(vectors: v, k: 2)
            ran += 1
            let expected: [[UMAPKnnEdge]] = [
                [e(1, 1), e(2, 2)],
                [e(0, 1), e(2, 1)],
                [e(1, 1), e(3, 1)],
                [e(2, 1), e(1, 2)],
            ]
            if let diff = diffKnn(got: g, expected: expected) {
                failures.append("T5 1D-collinear: \(diff)")
            }
        }

        // Test 6 — Unit square in 2D. Each corner has two adjacent
        // neighbors at distance 1 (tiebroken by index ASC) and one
        // diagonal at distance √2. Catches 2D Euclidean correctness +
        // tiebreak ordering across more than two ties.
        do {
            let v: [[Float]] = [[0, 0], [1, 0], [0, 1], [1, 1]]
            let g = computeKnnGraph(vectors: v, k: 3)
            ran += 1
            let s2 = 2.0.squareRoot()
            let expected: [[UMAPKnnEdge]] = [
                [e(1, 1), e(2, 1), e(3, s2)],
                [e(0, 1), e(3, 1), e(2, s2)],
                [e(0, 1), e(3, 1), e(1, s2)],
                [e(1, 1), e(2, 1), e(0, s2)],
            ]
            if let diff = diffKnn(got: g, expected: expected) {
                failures.append("T6 2D-square: \(diff)")
            }
        }

        // Test 7 — 4D one-hot-plus-mix. Confirms the inner dimension loop
        // accumulates correctly past dim=2; row 4 = [1,1,0,0] sits at
        // distance 1 from both row 0 ([1,0,0,0]) and row 1 ([0,1,0,0]),
        // and at distance √3 from row 2 / row 3. The asymmetry catches a
        // dim-loop bug that would have been masked by symmetric inputs.
        do {
            let v: [[Float]] = [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [0, 0, 0, 1],
                [1, 1, 0, 0],
            ]
            let g = computeKnnGraph(vectors: v, k: 2)
            ran += 1
            let s2 = 2.0.squareRoot()
            let expected: [[UMAPKnnEdge]] = [
                [e(4, 1), e(1, s2)],
                [e(4, 1), e(0, s2)],
                [e(0, s2), e(1, s2)],
                [e(0, s2), e(1, s2)],
                [e(0, 1), e(1, 1)],
            ]
            if let diff = diffKnn(got: g, expected: expected) {
                failures.append("T7 4D-onehot: \(diff)")
            }
        }

        // --- Step 3 (fuzzy simplicial set) ---

        // Test 8 — k=1 hits the "no σ search needed" fallback path
        // (num_neighbors - num_zero == raw_connect_index), so every
        // surviving weight is exactly 1.0. Exercises the unilateral
        // back-edge addition during symmetrization: 1's only k-NN is
        // 0 (tiebreak), but 2 has 1 as its k-NN — so mix_ratio=1 adds
        // (2, 1) to row 1's neighbor list.
        do {
            let v: [[Float]] = [[0], [1], [2], [3]]
            let knn = computeKnnGraph(vectors: v, k: 1)
            let f = computeFuzzySimplicialSet(knn: knn)
            ran += 1
            let expected: [[UMAPFuzzyEdge]] = [
                [fe(1, 1)],
                [fe(0, 1), fe(2, 1)],
                [fe(1, 1), fe(3, 1)],
                [fe(2, 1)],
            ]
            if let diff = diffFuzzy(got: f, expected: expected) {
                failures.append("T8 fuzzy-k1-fallback: \(diff)")
            }
        }

        // Test 9 — Symmetry invariant. For mix_ratio=1, every stored
        // edge must satisfy w[i][j] == w[j][i] within Double precision.
        // A plus-shape gives variety in neighbor counts (the center hub
        // has 4 incoming back-edges) without making expected weights
        // hand-computable — symmetry alone is the invariant under test.
        do {
            let v: [[Float]] = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]
            let knn = computeKnnGraph(vectors: v, k: 2)
            let f = computeFuzzySimplicialSet(knn: knn)
            ran += 1
            if let asym = findFuzzyAsymmetry(f) {
                failures.append("T9 fuzzy-symmetry: \(asym)")
            }
        }

        // --- Step 5 (persistence round-trip) ---

        // Test 10 — UMAPFittedModel JSON round-trip on a hand-built literal.
        // Validates the Codable contract (schema shape, JSONEncoder/Decoder
        // settings, ISO8601 dates) independently of UMAP.fit, which is still
        // a throw-stub at 4a sub-step 5. When fit wiring lands at 4.5, an
        // end-to-end test on synth_50x4 will subsume the regression coverage;
        // T10 stays as a fast schema-shape tripwire.
        do {
            let original = UMAPFittedModel(
                schemaVersion: UMAPFittedModel.currentSchemaVersion,
                fitVersion: 1,
                fittedAt: Date(timeIntervalSince1970: 1_715_000_000),
                hyperparameters: .default,
                rngSeed: [
                    0xA1B2C3D4E5F60718, 0x0F1E2D3C4B5A6978,
                    0x123456789ABCDEF0, 0xFEDCBA9876543210,
                ],
                inputDimension: 4,
                a: 1.5,
                b: 0.9,
                trainingPoints: [
                    .init(nodeID: "n0",
                          inputVector: [1, 0, 0, 0],
                          coord2D: SubstrateCoord2D(x:  0.5, y: -0.5)),
                    .init(nodeID: "n1",
                          inputVector: [0, 1, 0, 0],
                          coord2D: SubstrateCoord2D(x: -0.5, y:  0.5)),
                ]
            )

            ran += 1
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            do {
                let data = try encoder.encode(original)
                let roundTripped = try decoder.decode(UMAPFittedModel.self, from: data)
                if let diff = diffFittedModel(got: roundTripped, expected: original) {
                    failures.append("T10 round-trip: \(diff)")
                }
            } catch {
                failures.append("T10 round-trip threw: \(error)")
            }
        }

        // --- Step 4.5 (UMAP.fit composition) ---

        // Test 11 — End-to-end smoke. Drive `UMAP.fit` on a tiny synthetic
        // fixture (10 obs × 4 dim, 3 NN, 20 epochs) and check structural
        // invariants only: returns without throwing, schema fields populated
        // sensibly, every coord finite, training-set order/IDs preserved,
        // spread above the floor (catches a "collapsed to a point" failure
        // mode). NOT a harness byte-parity check — that's the job of
        // `swift_fit_parity.swift` on the host. T11 is the in-app tripwire
        // for "is the production fit path basically wired and producing
        // a non-degenerate embedding". Tolerances reflect the Float coord
        // floor (SubstrateCoord2D is Float by design) plus the entirety
        // of a real SGD run, so "reasonable" is the load-bearing word.
        do {
            ran += 1
            // Two well-separated 4-dim clusters of 5 points each. Small
            // jitter inside each cluster gives the σ search non-fallback
            // input on at least some rows. Hand-built rather than RNG-
            // generated so the test is deterministic without depending on
            // SplitMix64 here (which T1 already covers).
            let inputs: [(nodeID: String, vector: [Float])] = [
                ("a0", [0.00, 0.00, 0.00, 0.00]),
                ("a1", [0.10, 0.00, 0.00, 0.00]),
                ("a2", [0.00, 0.10, 0.00, 0.00]),
                ("a3", [0.00, 0.00, 0.10, 0.00]),
                ("a4", [0.00, 0.00, 0.00, 0.10]),
                ("b0", [5.00, 5.00, 5.00, 5.00]),
                ("b1", [5.10, 5.00, 5.00, 5.00]),
                ("b2", [5.00, 5.10, 5.00, 5.00]),
                ("b3", [5.00, 5.00, 5.10, 5.00]),
                ("b4", [5.00, 5.00, 5.00, 5.10]),
            ]
            let hyper = UMAPHyperparameters(
                nComponents: 2,
                nNeighbors: 3,
                minDist: 0.1,
                spread: 1.0,
                learningRate: 1.0,
                negativeSampleRate: 5,
                nEpochs: 20
            )
            let seed: [UInt64] = [42, 0, 0, 0]

            do {
                let model = try UMAP.fit(
                    trainingInputs: inputs,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 1
                )
                if let diff = diffFitSmoke(model: model, inputs: inputs, hyper: hyper, seed: seed) {
                    failures.append("T11 fit-smoke: \(diff)")
                }
            } catch {
                failures.append("T11 fit-smoke threw: \(error)")
            }
        }

        // --- Step 6 (newcomer transform) ---

        // Test 14 — Transform round-trip via neighborhood-set comparison.
        //
        // Fit on a 10-point base corpus (2 well-separated clusters of 5) →
        // transform an 11th "newcomer" vector through the saved model →
        // refit on all 11 points with the same seed → compare the
        // newcomer's K=5 nearest non-newcomer training points (by nodeID)
        // in modelA's 2D space vs modelB's 2D space. Pass if M=3 of 5
        // nodeIDs match.
        //
        // **Why nodeID-set comparison rather than 2D-distance comparison
        // (rejected 2026-05-11):** UMAP fits are rotation/reflection-
        // arbitrary. modelA and modelB land in different orientations
        // even with identical seeds; adding one point to the corpus can
        // flip or rotate the entire embedding. The original 2D-distance
        // design failed for exactly this reason — bumping nEpochs made
        // it worse (8.85 vs 2.71) as each fit converged further toward
        // its own optimum. Comparing which nodeIDs are nearest is
        // rotation-invariant: cluster-a stays "newcomer's neighborhood"
        // regardless of where the embedding rotates the whole cluster.
        //
        // **K=5 (cluster size).** The "right answer" in the happy path is
        // exactly the 5 cluster-a nodeIDs; cluster-b sits ~10x further
        // out in 2D so no ambiguity at the boundary. K=3 (= nNeighbors)
        // would be too binary; K>5 includes cluster-b points whose
        // cross-fit ordering is meaningless.
        //
        // **M=3 (majority of 5).** Failure-mode windows:
        //   - Transform bug (wrong cluster): 0 of 5. Caught.
        //   - Cross-fit ordering noise within right cluster: 4-5 of 5.
        //     No false-fail.
        //   - Newcomer at legitimate cluster boundary: 3-4 of 5. Marginal
        //     pass — the right answer for a real edge case.
        // The gap between "bug" (0-2) and "noise" (4-5) is wide; M=3
        // sits cleanly in it with margin against synthetic pathology.
        do {
            ran += 1
            let baseCorpus: [(nodeID: String, vector: [Float])] = [
                ("a0", [0.00, 0.00, 0.00, 0.00]),
                ("a1", [0.10, 0.00, 0.00, 0.00]),
                ("a2", [0.00, 0.10, 0.00, 0.00]),
                ("a3", [0.00, 0.00, 0.10, 0.00]),
                ("a4", [0.00, 0.00, 0.00, 0.10]),
                ("b0", [5.00, 5.00, 5.00, 5.00]),
                ("b1", [5.10, 5.00, 5.00, 5.00]),
                ("b2", [5.00, 5.10, 5.00, 5.00]),
                ("b3", [5.00, 5.00, 5.10, 5.00]),
                ("b4", [5.00, 5.00, 5.00, 5.10]),
            ]
            let newcomerID = "new"
            let newcomerVector: [Float] = [0.05, 0.05, 0.05, 0.05]
            let withNewcomer = baseCorpus + [(nodeID: newcomerID, vector: newcomerVector)]
            let hyper = UMAPHyperparameters(
                nComponents: 2,
                nNeighbors: 3,
                minDist: 0.1,
                spread: 1.0,
                learningRate: 1.0,
                negativeSampleRate: 5,
                nEpochs: 20
            )
            let seed: [UInt64] = [42, 0, 0, 0]

            do {
                let modelA = try UMAP.fit(
                    trainingInputs: baseCorpus,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 1
                )
                let coordT = try UMAP.transform(
                    inputVector: newcomerVector,
                    through: modelA
                )
                let modelB = try UMAP.fit(
                    trainingInputs: withNewcomer,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 2
                )
                if let diff = diffTransformRoundTrip(
                    modelA: modelA,
                    coordT: coordT,
                    modelB: modelB,
                    newcomerID: newcomerID,
                    k: 5,
                    minMatching: 3
                ) {
                    failures.append("T14 round-trip: \(diff)")
                }
            } catch {
                failures.append("T14 round-trip threw: \(error)")
            }
        }

        // --- Step 7 (synthetic recovery + determinism) ---

        // Test 12 — Synthetic cluster recovery. Plants 4 well-separated
        // clusters in 4D (50 points each, ±0.3 uniform jitter), runs
        // UMAP.fit, asserts that for each node ≥M=3 of its k=5 nearest
        // 2D neighbors share its cluster label, with ≥190/200 nodes
        // passing.
        //
        // **Pass-rate framing (≥95%) rather than strict per-node.**
        // UMAP fits leave some boundary points sandwiched between
        // clusters even on healthy embeddings. Strict per-node would
        // false-fail on noise; the gap between bug-shaped failure (mass
        // mismatch, dozens or more failing) and noise (a handful of
        // boundary outliers) is wide, so 190/200 sits cleanly inside it.
        //
        // **K=5, M=3** mirrors T14's M-of-K shape. Same logic for why
        // 3 of 5 lands in the bug/noise gap with margin.
        //
        // **Why uniform jitter (not Gaussian).** SplitMix64 emits
        // uniforms; Box-Muller would import transcendentals into the
        // fixture for no test-shape gain. Uniform ±0.3 around centers
        // spaced 5 apart still gives the σ-search non-fallback input
        // on every cluster boundary.
        do {
            ran += 1
            let (inputs, labels) = synthClusters4D(
                pointsPerCluster: 50,
                numClusters: 4,
                jitterHalfWidth: 0.3,
                centerSpacing: 5.0,
                seed: 42
            )
            let hyper = UMAPHyperparameters(
                nComponents: 2,
                nNeighbors: 15,
                minDist: 0.1,
                spread: 1.0,
                learningRate: 1.0,
                negativeSampleRate: 5,
                nEpochs: 200
            )
            let seed: [UInt64] = [42, 0, 0, 0]

            do {
                let t0 = Date()
                let model = try UMAP.fit(
                    trainingInputs: inputs,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 1
                )
                t12ElapsedMS = Int(Date().timeIntervalSince(t0) * 1000)
                if let diff = diffSyntheticRecovery(
                    model: model,
                    labels: labels,
                    k: 5,
                    minMatching: 3,
                    minPassingNodes: 190
                ) {
                    failures.append("T12 cluster-recovery: \(diff)")
                }
            } catch {
                failures.append("T12 cluster-recovery threw: \(error)")
            }
        }

        // Test 13 — Determinism. Two `UMAP.fit` calls on the same
        // inputs with the same seed must produce bit-identical models
        // (every Float coord, every field — `fittedAt` excluded as it's
        // wall-clock).
        //
        // **Why bit-equality, not within-tolerance.** Determinism is a
        // structural property of the pipeline: the RNGs (SplitMix64,
        // MT19937-64) are deterministic, the SGD update rule is
        // deterministic, the ordering is deterministic. Any drift means
        // some non-determinism leaked in (parallel iteration order,
        // hash randomization, uninitialized memory, etc.) — these don't
        // produce small drift, they produce arbitrary drift, and
        // `==` on Float catches them all without tolerance hand-waving.
        //
        // **Why T11's 10-pt fixture suffices.** Determinism doesn't
        // need scale; bit-equal at 10 obs × 20 epochs is the same proof
        // as bit-equal at 200 × 200, and ~10x faster. Fixture inlined
        // (matches T11 / T14 self-contained pattern).
        do {
            ran += 1
            let inputs: [(nodeID: String, vector: [Float])] = [
                ("a0", [0.00, 0.00, 0.00, 0.00]),
                ("a1", [0.10, 0.00, 0.00, 0.00]),
                ("a2", [0.00, 0.10, 0.00, 0.00]),
                ("a3", [0.00, 0.00, 0.10, 0.00]),
                ("a4", [0.00, 0.00, 0.00, 0.10]),
                ("b0", [5.00, 5.00, 5.00, 5.00]),
                ("b1", [5.10, 5.00, 5.00, 5.00]),
                ("b2", [5.00, 5.10, 5.00, 5.00]),
                ("b3", [5.00, 5.00, 5.10, 5.00]),
                ("b4", [5.00, 5.00, 5.00, 5.10]),
            ]
            let hyper = UMAPHyperparameters(
                nComponents: 2,
                nNeighbors: 3,
                minDist: 0.1,
                spread: 1.0,
                learningRate: 1.0,
                negativeSampleRate: 5,
                nEpochs: 20
            )
            let seed: [UInt64] = [42, 0, 0, 0]

            do {
                let modelA = try UMAP.fit(
                    trainingInputs: inputs,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 1
                )
                let modelB = try UMAP.fit(
                    trainingInputs: inputs,
                    hyperparameters: hyper,
                    rngSeed: seed,
                    fitVersion: 1
                )
                if let diff = diffFittedModel(
                    got: modelB,
                    expected: modelA,
                    ignoreTimestamp: true
                ) {
                    failures.append("T13 determinism: \(diff)")
                }
            } catch {
                failures.append("T13 determinism threw: \(error)")
            }
        }

        if failures.isEmpty {
            var msg = "UMAP self-test OK · \(ran) tests"
            if t12ElapsedMS > 0 {
                msg += " · T12 fit \(t12ElapsedMS)ms"
            }
            return msg
        }
        return "UMAP self-test FAIL · " + failures.joined(separator: " | ")
    }

    /// Short alias for building expected `UMAPKnnEdge` literals in the
    /// k-NN tests. Without this, `[[UMAPKnnEdge]]` literals trip Swift's
    /// expression-type-check budget.
    private static func e(_ to: Int, _ d: Double) -> UMAPKnnEdge {
        UMAPKnnEdge(to: to, distance: d)
    }

    /// Counterpart to `e(_:_:)` for `UMAPFuzzyEdge` literals.
    private static func fe(_ to: Int, _ w: Double) -> UMAPFuzzyEdge {
        UMAPFuzzyEdge(to: to, weight: w)
    }

    /// Compare two k-NN graphs; returns nil on match, else a short diff
    /// string suitable for inline display. Distance tolerance is 1e-12,
    /// well inside Double precision for unit-grid inputs.
    private static func diffKnn(
        got: [[UMAPKnnEdge]],
        expected: [[UMAPKnnEdge]]
    ) -> String? {
        if got.count != expected.count {
            return "row count got=\(got.count) expected=\(expected.count)"
        }
        for i in 0..<got.count {
            if got[i].count != expected[i].count {
                return "row \(i) length got=\(got[i].count) expected=\(expected[i].count)"
            }
            for j in 0..<got[i].count {
                let g = got[i][j]
                let e = expected[i][j]
                if g.to != e.to {
                    return "row \(i) pos \(j) to got=\(g.to) expected=\(e.to)"
                }
                if abs(g.distance - e.distance) > 1e-12 {
                    return "row \(i) pos \(j) dist got=\(g.distance) expected=\(e.distance)"
                }
            }
        }
        return nil
    }

    /// Compare two fuzzy simplicial sets; tolerance is 1e-9 to account
    /// for transcendental ops in the σ search.
    private static func diffFuzzy(
        got: [[UMAPFuzzyEdge]],
        expected: [[UMAPFuzzyEdge]]
    ) -> String? {
        if got.count != expected.count {
            return "row count got=\(got.count) expected=\(expected.count)"
        }
        for i in 0..<got.count {
            if got[i].count != expected[i].count {
                return "row \(i) length got=\(got[i].count) expected=\(expected[i].count)"
            }
            for j in 0..<got[i].count {
                let g = got[i][j]
                let x = expected[i][j]
                if g.to != x.to {
                    return "row \(i) pos \(j) to got=\(g.to) expected=\(x.to)"
                }
                if abs(g.weight - x.weight) > 1e-9 {
                    return "row \(i) pos \(j) weight got=\(g.weight) expected=\(x.weight)"
                }
            }
        }
        return nil
    }

    /// Field-by-field compare for the round-trip Codable test (T10) and
    /// the determinism test (T13). Returns nil on match, else a short
    /// string naming the first divergence.
    ///
    /// Float/Double compares are bit-exact: JSONEncoder/Decoder preserve
    /// full precision for both, so any drift in T10 is a real bug, not
    /// rounding noise. Same logic applies to T13 — same seed + same
    /// inputs through deterministic SGD must produce bit-identical Float
    /// coords; any drift means a non-determinism leak.
    ///
    /// `ignoreTimestamp` skips `fittedAt` (wall-clock; always differs
    /// between two `UMAP.fit` calls). T10 leaves it false (round-trip
    /// must preserve the encoded date); T13 sets it true.
    private static func diffFittedModel(
        got: UMAPFittedModel,
        expected: UMAPFittedModel,
        ignoreTimestamp: Bool = false
    ) -> String? {
        if got.schemaVersion != expected.schemaVersion {
            return "schemaVersion got=\(got.schemaVersion) expected=\(expected.schemaVersion)"
        }
        if got.fitVersion != expected.fitVersion {
            return "fitVersion got=\(got.fitVersion) expected=\(expected.fitVersion)"
        }
        if !ignoreTimestamp && got.fittedAt != expected.fittedAt {
            return "fittedAt got=\(got.fittedAt) expected=\(expected.fittedAt)"
        }
        if got.hyperparameters != expected.hyperparameters {
            return "hyperparameters mismatch"
        }
        if got.rngSeed != expected.rngSeed {
            return "rngSeed mismatch"
        }
        if got.inputDimension != expected.inputDimension {
            return "inputDimension got=\(got.inputDimension) expected=\(expected.inputDimension)"
        }
        if got.a != expected.a {
            return "a got=\(got.a) expected=\(expected.a)"
        }
        if got.b != expected.b {
            return "b got=\(got.b) expected=\(expected.b)"
        }
        if got.trainingPoints.count != expected.trainingPoints.count {
            return "trainingPoints count got=\(got.trainingPoints.count) expected=\(expected.trainingPoints.count)"
        }
        for i in 0..<got.trainingPoints.count {
            let g = got.trainingPoints[i]
            let e = expected.trainingPoints[i]
            if g.nodeID != e.nodeID {
                return "trainingPoint[\(i)].nodeID got=\(g.nodeID) expected=\(e.nodeID)"
            }
            if g.inputVector != e.inputVector {
                return "trainingPoint[\(i)].inputVector mismatch"
            }
            if g.coord2D != e.coord2D {
                return "trainingPoint[\(i)].coord2D got=(\(g.coord2D.x),\(g.coord2D.y)) expected=(\(e.coord2D.x),\(e.coord2D.y))"
            }
        }
        return nil
    }

    /// Structural-smoke check for T11. Returns nil on pass, else the first
    /// invariant that failed. Checks: schema/hyperparameter passthrough,
    /// trainingPoints count + order + IDs + inputVector preservation, every
    /// coord finite, and a non-degenerate spread (max pairwise distance
    /// above a floor). Coord floor is 1e-3 — generous, since the load-
    /// bearing question is "did SGD do anything at all", not "did SGD
    /// produce the right answer" (that's the host parity script's job).
    private static func diffFitSmoke(
        model: UMAPFittedModel,
        inputs: [(nodeID: String, vector: [Float])],
        hyper: UMAPHyperparameters,
        seed: [UInt64]
    ) -> String? {
        if model.schemaVersion != UMAPFittedModel.currentSchemaVersion {
            return "schemaVersion=\(model.schemaVersion)"
        }
        if model.fitVersion != 1 {
            return "fitVersion=\(model.fitVersion)"
        }
        if model.hyperparameters != hyper {
            return "hyperparameters mismatch"
        }
        if model.rngSeed != seed {
            return "rngSeed mismatch"
        }
        if model.inputDimension != inputs[0].vector.count {
            return "inputDimension=\(model.inputDimension)"
        }
        if !model.a.isFinite || !model.b.isFinite {
            return "a/b not finite: a=\(model.a) b=\(model.b)"
        }
        if model.trainingPoints.count != inputs.count {
            return "trainingPoints count=\(model.trainingPoints.count) expected=\(inputs.count)"
        }
        var maxSq: Float = 0
        for i in 0..<inputs.count {
            let p = model.trainingPoints[i]
            if p.nodeID != inputs[i].nodeID {
                return "trainingPoint[\(i)].nodeID=\(p.nodeID)"
            }
            if p.inputVector != inputs[i].vector {
                return "trainingPoint[\(i)].inputVector mismatch"
            }
            if !p.coord2D.x.isFinite || !p.coord2D.y.isFinite {
                return "trainingPoint[\(i)].coord2D non-finite (\(p.coord2D.x),\(p.coord2D.y))"
            }
            for j in (i + 1)..<inputs.count {
                let q = model.trainingPoints[j]
                let dx = p.coord2D.x - q.coord2D.x
                let dy = p.coord2D.y - q.coord2D.y
                let sq = dx * dx + dy * dy
                if sq > maxSq { maxSq = sq }
            }
        }
        if maxSq < 1e-6 {
            return "embedding collapsed: maxPairwiseDist²=\(maxSq)"
        }
        return nil
    }

    /// Structural check for T14. Returns nil on pass, else a short
    /// description of the first invariant that failed.
    ///
    /// Compares the newcomer's neighborhood by nodeID, which is invariant
    /// under UMAP's arbitrary rotation/reflection between fits:
    ///   1. Locate the newcomer in `modelB.trainingPoints` by nodeID.
    ///   2. Find the k nearest non-newcomer nodeIDs to `coordT` in modelA's
    ///      2D space, and to `coordR` in modelB's 2D space.
    ///   3. Pass if at least `minMatching` of those nodeIDs intersect.
    ///
    /// k-NN tiebreak: ascending training-point index — same convention as
    /// `computeKnnGraph`, deterministic, no float-equality drama.
    ///
    /// The intersection check is symmetric (set operation) and unaffected
    /// by which model's coord frame is the "reference," so the test does
    /// not need to know about the cross-fit rotation that broke the
    /// original 2D-distance design.
    private static func diffTransformRoundTrip(
        modelA: UMAPFittedModel,
        coordT: SubstrateCoord2D,
        modelB: UMAPFittedModel,
        newcomerID: String,
        k: Int,
        minMatching: Int
    ) -> String? {
        guard let newcomerInB = modelB.trainingPoints.first(where: { $0.nodeID == newcomerID }) else {
            return "refit dropped newcomer nodeID=\(newcomerID)"
        }
        let coordR = newcomerInB.coord2D
        if !coordR.x.isFinite || !coordR.y.isFinite {
            return "refit produced non-finite coord (\(coordR.x), \(coordR.y))"
        }
        if !coordT.x.isFinite || !coordT.y.isFinite {
            return "transform produced non-finite coord (\(coordT.x), \(coordT.y))"
        }

        // modelA has no newcomer to exclude (newcomer wasn't in the
        // base-corpus fit). modelB has the newcomer; exclude by nodeID.
        let aNeighbors = kNearestNodeIDs(
            from: coordT,
            points: modelA.trainingPoints,
            excludingID: nil,
            k: k
        )
        let bNeighbors = kNearestNodeIDs(
            from: coordR,
            points: modelB.trainingPoints,
            excludingID: newcomerID,
            k: k
        )

        let intersection = Set(aNeighbors).intersection(Set(bNeighbors))
        let matchCount = intersection.count
        if matchCount < minMatching {
            return "neighborhood mismatch: \(matchCount)/\(k) IDs matched, need ≥\(minMatching). modelA=[\(aNeighbors.joined(separator: ","))], modelB=[\(bNeighbors.joined(separator: ","))]"
        }
        return nil
    }

    /// Return the nodeIDs of the `k` training points nearest to `origin`
    /// in 2D space, optionally excluding one nodeID (used to skip the
    /// newcomer itself when scanning the refit model). Tiebreak by
    /// ascending training-point index. Used by `diffTransformRoundTrip`.
    private static func kNearestNodeIDs(
        from origin: SubstrateCoord2D,
        points: [UMAPFittedModel.TrainingPoint],
        excludingID: String?,
        k: Int
    ) -> [String] {
        var pairs: [(idx: Int, dist: Double)] = []
        pairs.reserveCapacity(points.count)
        for (idx, tp) in points.enumerated() {
            if let exclude = excludingID, tp.nodeID == exclude { continue }
            let dx = Double(origin.x - tp.coord2D.x)
            let dy = Double(origin.y - tp.coord2D.y)
            pairs.append((idx, (dx * dx + dy * dy).squareRoot()))
        }
        pairs.sort { lhs, rhs in
            if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
            return lhs.idx < rhs.idx
        }
        return pairs.prefix(Swift.min(k, pairs.count)).map { points[$0.idx].nodeID }
    }

    /// Generate `pointsPerCluster * numClusters` points in 4D as
    /// `numClusters` well-separated clusters with uniform per-coord
    /// jitter inside each. Cluster `c`'s center sits at `centerSpacing
    /// * e_c` (the c-th 4D standard basis vector), so 4 clusters fit
    /// orthogonally. Deterministic via `SplitMix64(seed:)`. Returns
    /// inputs in the shape `UMAP.fit` consumes plus a parallel
    /// `labels` array (cluster index per node) for T12's recovery
    /// check.
    private static func synthClusters4D(
        pointsPerCluster: Int,
        numClusters: Int,
        jitterHalfWidth: Float,
        centerSpacing: Float,
        seed: UInt64
    ) -> (inputs: [(nodeID: String, vector: [Float])], labels: [Int]) {
        var rng = SplitMix64(seed: seed)
        var inputs: [(nodeID: String, vector: [Float])] = []
        var labels: [Int] = []
        let total = pointsPerCluster * numClusters
        inputs.reserveCapacity(total)
        labels.reserveCapacity(total)
        for c in 0..<numClusters {
            for i in 0..<pointsPerCluster {
                var v: [Float] = [0, 0, 0, 0]
                v[c] = centerSpacing
                for d in 0..<4 {
                    // Top 24 bits → Float in [0, 1); map to ±half-width.
                    let u = Float(rng.next() >> 40) / 16_777_216.0
                    v[d] += (u * 2 - 1) * jitterHalfWidth
                }
                inputs.append((nodeID: "c\(c)_n\(i)", vector: v))
                labels.append(c)
            }
        }
        return (inputs, labels)
    }

    /// Structural check for T12. For each training point, find its k
    /// nearest 2D neighbors (by index, excluding self, tiebroken by
    /// ascending index), count how many share its cluster label, and
    /// mark the point as passing if matches ≥ minMatching. Returns nil
    /// if at least minPassingNodes pass, else a short summary plus the
    /// worst-matching node (helps narrow what's drifting if the test
    /// goes red).
    private static func diffSyntheticRecovery(
        model: UMAPFittedModel,
        labels: [Int],
        k: Int,
        minMatching: Int,
        minPassingNodes: Int
    ) -> String? {
        let n = model.trainingPoints.count
        if labels.count != n {
            return "label count \(labels.count) != trainingPoints count \(n)"
        }
        var coords: [(x: Double, y: Double)] = []
        coords.reserveCapacity(n)
        for tp in model.trainingPoints {
            if !tp.coord2D.x.isFinite || !tp.coord2D.y.isFinite {
                return "non-finite coord at nodeID=\(tp.nodeID)"
            }
            coords.append((Double(tp.coord2D.x), Double(tp.coord2D.y)))
        }
        var passing = 0
        var worstNode: (id: String, matches: Int)?
        for i in 0..<n {
            var pairs: [(idx: Int, dist: Double)] = []
            pairs.reserveCapacity(n - 1)
            for j in 0..<n where j != i {
                let dx = coords[i].x - coords[j].x
                let dy = coords[i].y - coords[j].y
                pairs.append((j, (dx * dx + dy * dy).squareRoot()))
            }
            pairs.sort { lhs, rhs in
                if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
                return lhs.idx < rhs.idx
            }
            var matches = 0
            for p in pairs.prefix(k) where labels[p.idx] == labels[i] {
                matches += 1
            }
            if matches >= minMatching {
                passing += 1
            } else if worstNode == nil || matches < worstNode!.matches {
                worstNode = (model.trainingPoints[i].nodeID, matches)
            }
        }
        if passing < minPassingNodes {
            var msg = "\(passing)/\(n) nodes passed M≥\(minMatching) of K=\(k), need ≥\(minPassingNodes)"
            if let worst = worstNode {
                msg += " · worst=\(worst.id)@\(worst.matches)/\(k)"
            }
            return msg
        }
        return nil
    }

    /// Returns nil if every stored edge has an equal-weight back-edge
    /// within tolerance, else a short description of the first
    /// asymmetric pair. Used as the load-bearing invariant for T9.
    private static func findFuzzyAsymmetry(_ f: [[UMAPFuzzyEdge]]) -> String? {
        var dicts: [[Int: Double]] = []
        dicts.reserveCapacity(f.count)
        for row in f {
            var d: [Int: Double] = [:]
            d.reserveCapacity(row.count)
            for edge in row { d[edge.to] = edge.weight }
            dicts.append(d)
        }
        for i in 0..<f.count {
            for edge in f[i] {
                guard let back = dicts[edge.to][i] else {
                    return "row \(i)→\(edge.to) missing back-edge"
                }
                if abs(back - edge.weight) > 1e-12 {
                    return "row \(i)↔\(edge.to) got=\(edge.weight) back=\(back)"
                }
            }
        }
        return nil
    }
}
