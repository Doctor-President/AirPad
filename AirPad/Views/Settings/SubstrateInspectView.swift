import SwiftUI

/// SB139 Stage 1 — dev-only substrate inspect view. Gated behind a hidden
/// long-press in `SettingsView`'s developer section. Not for end users — must
/// be honest about real numbers, real failures, no friendly facades.
///
/// Sections:
/// 1. Coverage stats — full / partial / failed / unprocessed; per-reason histogram.
/// 2. Selected node — substrate summary, folksonomy, three embeddings (truncated
///    preview), embedding version, failure reason.
/// 3. Pair inspector — pick two nodes, show summary/folksonomy/content cosines
///    plus blended score and which fallback path fired.
/// 4. Backfill control — batch size input, run button, last-run summary.
/// 5. Self-tests — runs the synthetic pair-similarity assertions.
/// 6. Export — dump corpus-wide diagnostic JSON (means + per-node substrate +
///    top-5 neighbors) to Documents and offer share-sheet export.
@available(iOS 17.0, *)
struct SubstrateInspectView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // SB139 Stage 4c1 — bound to the same key FeatureFlags.substrateLayout reads.
    // Dev surface for the flag flip; reversible without code surgery.
    @AppStorage("ff.substrateLayout") private var substrateLayoutFlag = false

    // SB139 Stage 4c1.3 — bound to FeatureFlags.substrateRelaxation. Default
    // TRUE matches the FeatureFlags accessor: backout toggles off, default-on
    // re-enables.
    @AppStorage("ff.substrateRelaxation") private var substrateRelaxationFlag = true

    // Strands — bound to FeatureFlags.strandSnap + StrandService tunables.
    // Doubles persist directly to the keys StrandService reads via
    // UserDefaults.standard.double(forKey:). Default 0 ⇒ service default
    // (the service falls back when stored value is 0/missing).
    @AppStorage("ff.strandSnap") private var strandSnapFlag = false
    @AppStorage("strand.ringRadiusMultiplier") private var strandRingRadiusMultiplier: Double = 0
    @AppStorage("strand.minAngularSeparationDeg") private var strandMinAngularSeparationDeg: Double = 0
    @AppStorage("strand.blendedThreshold") private var strandBlendedThreshold: Double = 0
    @AppStorage("strand.contentThreshold") private var strandContentThreshold: Double = 0
    @AppStorage("strand.dimAlpha") private var strandDimAlpha: Double = 0
    @AppStorage("strand.focalScaleMultiplier") private var strandFocalScaleMultiplier: Double = 0
    @State private var strandRingRadiusMultiplierText: String = ""
    @State private var strandMinAngularSeparationText: String = ""
    @State private var strandBlendedThresholdText: String = ""
    @State private var strandContentThresholdText: String = ""
    @State private var strandDimAlphaText: String = ""
    @State private var strandFocalScaleMultiplierText: String = ""

    @State private var selectedNodeID: String? = nil
    @State private var pairLeftID: String? = nil
    @State private var pairRightID: String? = nil
    @State private var batchSizeText: String = "10"
    @State private var selfTestResult: String? = nil
    @State private var umapSelfTestResult: String? = nil
    @State private var hdbscanSelfTestResult: String? = nil
    @State private var entryMigrationSelfTestResult: String? = nil
    @State private var entryDeletionSelfTestResult: String? = nil
    @State private var entryDeletionSelfTestInProgress: Bool = false
    @State private var exportInProgress: Bool = false
    @State private var exportResult: ExportResult? = nil
    @State private var exportError: String? = nil
    @State private var umapFitInProgress: Bool = false
    @State private var umapFitResult: UMAPFitInspectResult? = nil
    @State private var umapFitError: String? = nil
    @State private var umapShowExcluded: Bool = false
    @State private var umapNNeighborsText: String = ""
    @State private var umapMinDistText: String = ""
    @State private var hdbscanFitInProgress: Bool = false
    @State private var hdbscanFitResult: HDBSCANFitInspectResult? = nil
    @State private var hdbscanFitError: String? = nil
    @State private var hdbscanMinClusterSizeText: String = "8"
    @State private var hdbscanMinSamplesText: String = ""
    @State private var clusterExportInProgress: Bool = false
    @State private var clusterExportResult: ExportResult? = nil
    @State private var clusterExportError: String? = nil

    struct ExportResult: Equatable {
        let url: URL
        let nodeCount: Int
        let elapsed: TimeInterval
    }

    struct ExcludedNodeEntry: Identifiable, Equatable {
        let id: String
        let title: String
        let contentPreview: String
    }

    struct UMAPFitInspectResult: Equatable {
        let included: Int
        let excludedThinContent: [ExcludedNodeEntry]
        let excludedMeta: [ExcludedNodeEntry]
        let excludedNoSubstrate: [ExcludedNodeEntry]
        let elapsed: TimeInterval
        let fitVersion: Int
        let lastActivityAt: Date?
        // Fit identity = fitVersion + hyperparameters. Surface the resolved
        // values so successive sweep runs are self-documenting.
        let hyperparameters: UMAPHyperparameters
        var totalConsidered: Int {
            included + excludedThinContent.count + excludedMeta.count + excludedNoSubstrate.count
        }
        var anyExcluded: Bool {
            !excludedThinContent.isEmpty || !excludedMeta.isEmpty || !excludedNoSubstrate.isEmpty
        }
    }

    struct HDBSCANClusterRow: Identifiable, Equatable {
        let id: Int               // renumbered cluster ID 0..k-1
        let internalID: Int       // HDBSCAN internal ID before renumbering
        let size: Int
        let stabilityScore: Double
        let sampleTitles: [String]
    }

    struct HDBSCANFitInspectResult: Equatable {
        let totalPoints: Int
        let clusterCount: Int
        let noiseCount: Int
        let minClusterSize: Int
        let minSamplesUsed: Int
        let elapsed: TimeInterval
        let clusters: [HDBSCANClusterRow]
        let noiseSampleTitles: [String]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    coverageSection
                    Divider().background(Color.white.opacity(0.1))
                    selectedNodeSection
                    Divider().background(Color.white.opacity(0.1))
                    pairInspectorSection
                    Divider().background(Color.white.opacity(0.1))
                    threadCandidatesSection
                    Divider().background(Color.white.opacity(0.1))
                    backfillSection
                    Divider().background(Color.white.opacity(0.1))
                    selfTestSection
                    Divider().background(Color.white.opacity(0.1))
                    substrateLayoutSection
                    Divider().background(Color.white.opacity(0.1))
                    substrateClusterSection
                    Divider().background(Color.white.opacity(0.1))
                    strandsSection
                    Divider().background(Color.white.opacity(0.1))
                    exportSection
                }
                .padding(20)
                .dismissKeyboardOnTapOutside()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Substrate (dev)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(.black)
    }

    // MARK: - Coverage

    private var coverage: SubstrateCoverage {
        SubstrateCoverage.compute(store.nodes)
    }

    private var coverageSection: some View {
        let c = coverage
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Coverage")
            statRow("Total nodes", "\(c.totalNodes)")
            statRow("Full substrate", "\(c.full)")
            statRow("Partial", "\(c.partial)")
            statRow("Failed (all channels)", "\(c.failedAll)")
            statRow("Unprocessed", "\(c.unprocessed)")
            if !c.failuresByReason.isEmpty {
                Text("Failure reasons")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
                ForEach(c.failuresByReason.sorted(by: { $0.key < $1.key }), id: \.key) { (k, v) in
                    statRow(k, "\(v)")
                }
            }
            if let updated = SubstrateService.shared.meansUpdatedAt {
                statRow("Means recomputed", DateFormatter.substrateLog.string(from: updated))
            } else {
                statRow("Means recomputed", "never")
            }
            statRow("Embedder loaded", SubstrateService.shared.isLoaded ? "yes (dim=\(SubstrateService.shared.dimension))" : "no")
        }
    }

    // MARK: - Selected node

    private var selectedNodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Selected node")
            nodePicker(label: "Node", selection: $selectedNodeID)
            if let id = selectedNodeID, let node = store.nodes.first(where: { $0.id == id }) {
                nodeDetailView(node)
            } else {
                Text("Pick a node above.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private func nodeDetailView(_ node: Node) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            kvRow("title", node.title.isEmpty ? "(empty)" : node.title)
            kvRow("embedding_version", "\(node.embeddingVersion)")
            kvRow("failure_reason", node.embeddingFailureReason ?? "—")
            kvRow("substrate_summary", node.substrateSummary ?? "—")
            kvRow("folksonomy", (node.folksonomy ?? []).isEmpty ? "—" : (node.folksonomy ?? []).joined(separator: ", "))
            kvRow("summary_emb [0..7]", embeddingPreview(node.summaryEmbedding))
            kvRow("folksonomy_emb [0..7]", embeddingPreview(node.folksonomyEmbedding))
            kvRow("ctx_content_emb [0..7]", embeddingPreview(node.contextualContentEmbedding))
        }
    }

    private func embeddingPreview(_ vec: [Float]?) -> String {
        guard let vec, !vec.isEmpty else { return "—" }
        let head = vec.prefix(8).map { String(format: "%+.3f", $0) }.joined(separator: " ")
        return "[\(head) …] dim=\(vec.count)"
    }

    // MARK: - Pair inspector

    private var pairInspectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Pair inspector")
            nodePicker(label: "Left", selection: $pairLeftID)
            nodePicker(label: "Right", selection: $pairRightID)
            if let l = pairLeftID, let r = pairRightID, l != r,
               let lNode = store.nodes.first(where: { $0.id == l }),
               let rNode = store.nodes.first(where: { $0.id == r }) {
                pairScoreView(SubstrateService.shared.pairSimilarity(lNode, rNode))
            } else if let l = pairLeftID, l == pairRightID {
                Text("Pick two distinct nodes.")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.6))
            } else {
                Text("Pick two nodes above.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private func pairScoreView(_ p: PairSimilarity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kvRow("summary cosine", formatCos(p.summaryCos))
            kvRow("folksonomy cosine", formatCos(p.folksonomyCos))
            kvRow("content cosine", formatCos(p.contentCos))
            kvRow("blended", formatCos(p.blended))
            kvRow("path", p.path.rawValue)
        }
    }

    private func formatCos(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.4f", v)
    }

    // MARK: - Thread candidates (SB139 Stage 2)

    private var threadCandidatesSection: some View {
        let tBlend = SubstrateThreadService.blendedThreshold
        let tContent = SubstrateThreadService.contentFallbackThreshold
        let tHeader = "T blend=\(String(format: "%.2f", tBlend)) · content=\(String(format: "%.2f", tContent))"
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Thread candidates  (\(tHeader))")
            if let id = selectedNodeID, let node = store.nodes.first(where: { $0.id == id }) {
                let cands = SubstrateThreadService.candidates(forNode: node, in: store.nodes)
                if cands.isEmpty {
                    Text("No pairs ≥ per-path T.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    let surviving = cands.filter { $0.exclusion == nil }
                    Text("\(surviving.count) surviving · \(cands.count - surviving.count) excluded")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                    ForEach(cands.indices, id: \.self) { i in
                        candidateRow(cands[i])
                    }
                }
            } else {
                Text("Pick a node in the Selected node section above.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func pathLabel(_ path: PairSimilarity.Path) -> (tag: String, T: Double?) {
        switch path {
        case .blendedSummaryFolksonomy: return ("blend", SubstrateThreadService.blendedThreshold)
        case .blendedFromLegacy:        return ("blend·legacy", SubstrateThreadService.blendedThreshold)
        case .contentFallback:          return ("content", SubstrateThreadService.contentFallbackThreshold)
        case .noSignal:                 return ("none", nil)
        }
    }

    @ViewBuilder
    private func candidateRow(_ c: SubstrateThreadService.Candidate) -> some View {
        let dim = c.exclusion != nil
        let label = pathLabel(c.path)
        let pathSuffix: String = {
            guard let T = label.T else { return label.tag }
            return "\(label.tag) T=\(String(format: "%.2f", T))"
        }()
        HStack(alignment: .top, spacing: 8) {
            Text(String(format: "%+.4f", c.blended))
                .font(.caption2.monospaced())
                .foregroundStyle(dim ? .white.opacity(0.4) : .white)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.other.title.isEmpty ? "(untitled)" : c.other.title)
                        .font(.caption2)
                        .foregroundStyle(dim ? .white.opacity(0.4) : .white.opacity(0.85))
                        .lineLimit(1)
                    Text(pathSuffix)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.35))
                }
                if let ex = c.exclusion {
                    Text("excluded: \(ex.rawValue)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Backfill

    private var backfillSection: some View {
        let state = store.substrateBackfill
        let inFlight = state != nil && state?.done == false
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Backfill")
            HStack(spacing: 8) {
                Text("Batch size")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("10", text: $batchSizeText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(width: 80)
                Spacer()
                Button {
                    let n = Int(batchSizeText) ?? 10
                    Task { await store.backfillSubstrate(batchSize: n) }
                } label: {
                    Text(inFlight ? "Running…" : "Run")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(inFlight ? 0.3 : 0.6))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(inFlight)
            }
            let fmErrorCount = store.nodes.filter { $0.embeddingFailureReason == "fm_error" }.count
            HStack(spacing: 8) {
                Spacer()
                Button {
                    Task { await store.retrySubstrateFMErrors() }
                } label: {
                    Text("Retry FM errors (\(fmErrorCount))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange.opacity(fmErrorCount == 0 || inFlight ? 0.3 : 0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(inFlight || fmErrorCount == 0)
            }
            if let s = state {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progressLine(s))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("ok=\(s.succeeded) refused=\(s.guardrailRefused) thin=\(s.thinContent) fm_err=\(s.fmError) emb_err=\(s.embedderError) pending=\(s.pendingAfter)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    if let last = s.lastRunAt {
                        Text("last run: \(DateFormatter.substrateLog.string(from: last))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
        }
    }

    private func progressLine(_ s: SubstrateBackfillState) -> String {
        if s.done { return "done · \(s.batchTotal) attempted" }
        return "\(s.current)/\(s.batchTotal)"
    }

    // MARK: - Self tests

    private var selfTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Self-tests")
            Button {
                selfTestResult = SubstrateSelfTest.run()
            } label: {
                Text("Run synthetic-node assertions")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if let r = selfTestResult {
                Text(r)
                    .font(.caption2)
                    .foregroundStyle(r.contains("FAIL") ? .red.opacity(0.8) : .green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                umapSelfTestResult = UMAPSelfTest.run()
            } label: {
                Text("Run UMAP self-tests")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if let r = umapSelfTestResult {
                Text(r)
                    .font(.caption2)
                    .foregroundStyle(r.contains("FAIL") ? .red.opacity(0.8) : .green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                hdbscanSelfTestResult = HDBSCANSelfTest.run()
            } label: {
                Text("Run HDBSCAN self-tests")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if let r = hdbscanSelfTestResult {
                Text(r)
                    .font(.caption2)
                    .foregroundStyle(r.contains("FAIL") ? .red.opacity(0.8) : .green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                entryMigrationSelfTestResult = EntryMigrationSelfTest.run()
            } label: {
                Text("Run entry-migration self-tests")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if let r = entryMigrationSelfTestResult {
                Text(r)
                    .font(.caption2)
                    .foregroundStyle(r.contains("FAIL") ? .red.opacity(0.8) : .green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                guard !entryDeletionSelfTestInProgress else { return }
                entryDeletionSelfTestInProgress = true
                Task {
                    let r = await EntryDeletionDiagnostic.run()
                    await MainActor.run {
                        entryDeletionSelfTestResult = r
                        entryDeletionSelfTestInProgress = false
                    }
                }
            } label: {
                Text(entryDeletionSelfTestInProgress ? "Running entry-deletion self-tests…" : "Run entry-deletion self-tests")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(entryDeletionSelfTestInProgress)
            if let r = entryDeletionSelfTestResult {
                Text(r)
                    .font(.caption2)
                    .foregroundStyle(r.contains("FAIL") ? .red.opacity(0.8) : .green.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Strands

    private var strandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Strands — engaged-state ring")
            Toggle(isOn: $strandSnapFlag) {
                Text("FeatureFlags.strandSnap")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .tint(.purple)

            strandTunableRow(
                label: "ring_radius_mult",
                placeholder: "1.6",
                text: $strandRingRadiusMultiplierText,
                store: $strandRingRadiusMultiplier
            )
            strandTunableRow(
                label: "min_sep_deg",
                placeholder: "30",
                text: $strandMinAngularSeparationText,
                store: $strandMinAngularSeparationDeg
            )
            strandTunableRow(
                label: "blended_thresh",
                placeholder: "0.50",
                text: $strandBlendedThresholdText,
                store: $strandBlendedThreshold
            )
            strandTunableRow(
                label: "content_thresh",
                placeholder: "0.60",
                text: $strandContentThresholdText,
                store: $strandContentThreshold
            )
            strandTunableRow(
                label: "dim_alpha",
                placeholder: "0.30",
                text: $strandDimAlphaText,
                store: $strandDimAlpha
            )
            strandTunableRow(
                label: "focal_scale_mult",
                placeholder: "0.40",
                text: $strandFocalScaleMultiplierText,
                store: $strandFocalScaleMultiplier
            )
        }
        .onAppear {
            strandRingRadiusMultiplierText = strandRingRadiusMultiplier > 0 ? String(strandRingRadiusMultiplier) : ""
            strandMinAngularSeparationText = strandMinAngularSeparationDeg > 0 ? String(strandMinAngularSeparationDeg) : ""
            strandBlendedThresholdText = strandBlendedThreshold > 0 ? String(strandBlendedThreshold) : ""
            strandContentThresholdText = strandContentThreshold > 0 ? String(strandContentThreshold) : ""
            strandDimAlphaText = strandDimAlpha > 0 ? String(strandDimAlpha) : ""
            strandFocalScaleMultiplierText = strandFocalScaleMultiplier > 0 ? String(strandFocalScaleMultiplier) : ""
        }
    }

    /// Numeric tunable row. Empty text or unparseable input ⇒ writes 0 to the
    /// backing AppStorage, which StrandService reads as "use default."
    private func strandTunableRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        store: Binding<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .keyboardType(.decimalPad)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 80)
                .onChange(of: text.wrappedValue) { _, new in
                    store.wrappedValue = Double(new) ?? 0
                }
            Text(text.wrappedValue.isEmpty ? "default \(placeholder)" : "")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Export")
            HStack(spacing: 8) {
                Button {
                    Task { await runExport() }
                } label: {
                    Text(exportInProgress ? "Exporting…" : "Export diagnostic JSON")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(exportInProgress ? 0.4 : 0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(exportInProgress)

                if let result = exportResult {
                    ShareLink(item: result.url) {
                        Text("Share")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }
                }
            }
            if let result = exportResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported to: \(result.url.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.6))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(result.nodeCount) nodes · \(String(format: "%.2fs", result.elapsed))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if let err = exportError {
                Text("export failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            }

            // Stage 4b cluster diagnostic — joined substrate + UMAP + HDBSCAN
            // export for cluster-validity inspection. Additive to the Stage 1
            // export above; lives here so both diagnostics are reachable from
            // one section.
            HStack(spacing: 8) {
                Button {
                    Task { await runClusterExport() }
                } label: {
                    Text(clusterExportInProgress ? "Exporting…" : "Export cluster diagnostic JSON")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(clusterExportInProgress ? 0.4 : 0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(clusterExportInProgress)

                if let result = clusterExportResult {
                    ShareLink(item: result.url) {
                        Text("Share")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }
                }
            }
            if let result = clusterExportResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported to: \(result.url.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.6))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(result.nodeCount) nodes · \(String(format: "%.2fs", result.elapsed))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if let err = clusterExportError {
                Text("cluster export failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
    }

    @MainActor
    private func runExport() async {
        exportInProgress = true
        exportError = nil
        defer { exportInProgress = false }

        let start = Date()
        let nodes = store.nodes
        let substrate = SubstrateService.shared

        let nodeEntries: [SubstrateExportPayload.NodeEntry] = nodes.map { node in
            SubstrateExportPayload.NodeEntry(
                id: node.id,
                title: String(node.title.prefix(80)),
                contentLength: substrateContentLength(node),
                tags: node.tags,
                substrate: SubstrateExportPayload.NodeEntry.Substrate(
                    summary: node.substrateSummary,
                    folksonomy: node.folksonomy,
                    summaryEmbeddingPresent: node.summaryEmbedding?.isEmpty == false,
                    folksonomyEmbeddingPresent: node.folksonomyEmbedding?.isEmpty == false,
                    contentEmbeddingPresent: node.contextualContentEmbedding?.isEmpty == false,
                    embeddingFailureReason: node.embeddingFailureReason,
                    summaryEmbeddingPreview: previewVec(node.summaryEmbedding),
                    folksonomyEmbeddingPreview: previewVec(node.folksonomyEmbedding),
                    contentEmbeddingPreview: previewVec(node.contextualContentEmbedding),
                    contentFull: node.embeddingFailureReason == "fm_error"
                        ? substrateContentText(node)
                        : nil,
                    fmErrorDetail: node.embeddingFailureReason == "fm_error"
                        ? node.fmErrorDetail
                        : nil
                ),
                top5Neighbors: top5Neighbors(for: node, in: nodes, substrate: substrate)
            )
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = SubstrateExportPayload(
            exportedAt: isoFormatter.string(from: Date()),
            embedderVersion: SubstrateService.currentEmbeddingVersion,
            corpusMeans: SubstrateExportPayload.Means(
                summary: previewVec(substrate.summaryMean),
                folksonomy: previewVec(substrate.folksonomyMean),
                content: previewVec(substrate.contentMean)
            ),
            nodes: nodeEntries
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)

            let docs = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let stamp = exportFilenameTimestamp()
            let url = docs.appendingPathComponent("substrate-diagnostic-\(stamp).json")
            try data.write(to: url, options: .atomic)
            exportResult = ExportResult(
                url: url,
                nodeCount: nodes.count,
                elapsed: Date().timeIntervalSince(start)
            )
        } catch {
            exportError = String(describing: error)
            exportResult = nil
        }
    }

    // MARK: - Cluster diagnostic export (Stage 4b)

    @MainActor
    private func runClusterExport() async {
        clusterExportInProgress = true
        clusterExportError = nil
        defer { clusterExportInProgress = false }

        let start = Date()
        let layout = SubstrateLayoutService.shared
        let substrate = SubstrateService.shared
        let allNodes = store.nodes

        guard let model = layout.fittedModel else {
            clusterExportError = "no fitted UMAP model — run the UMAP fit above first"
            return
        }
        let mcs = Int(hdbscanMinClusterSizeText) ?? 8
        guard mcs >= 2 else {
            clusterExportError = "min_cluster_size must be ≥ 2"
            return
        }
        let trimmed = hdbscanMinSamplesText.trimmingCharacters(in: .whitespaces)
        let minSamplesOverride: Int?
        if trimmed.isEmpty {
            minSamplesOverride = nil
        } else if let parsed = Int(trimmed), parsed >= 1 {
            minSamplesOverride = parsed
        } else {
            clusterExportError = "min_samples must be empty (auto) or ≥ 1"
            return
        }

        // Classify each node into the same buckets SubstrateLayoutService.fit()
        // uses. Order matters — first matching rule wins per the service.
        enum Bucket {
            case included(coord: SubstrateCoord2D)
            case excludedThinContent
            case excludedMeta
            case excludedNoSubstrate
        }
        let coordByNodeID: [String: SubstrateCoord2D] = Dictionary(
            uniqueKeysWithValues: model.trainingPoints.map { ($0.nodeID, $0.coord2D) }
        )
        var bucketByID: [String: Bucket] = [:]
        var orderedIncludedIDs: [String] = []
        for node in allNodes {
            if !substrate.isRankable(node) {
                bucketByID[node.id] = .excludedThinContent
                continue
            }
            if node.isMeta {
                bucketByID[node.id] = .excludedMeta
                continue
            }
            if layout.substrateVector(for: node) == nil {
                bucketByID[node.id] = .excludedNoSubstrate
                continue
            }
            // Included — but if the fitted model predates this node, we
            // may not have a coord. Treat that as "excluded from THIS fit"
            // for export purposes; surfaces as no_substrate_vector bucket
            // in practice this shouldn't fire when fit was just run.
            guard let coord = coordByNodeID[node.id] else {
                bucketByID[node.id] = .excludedNoSubstrate
                continue
            }
            bucketByID[node.id] = .included(coord: coord)
            orderedIncludedIDs.append(node.id)
        }

        // Build coord array in the order included nodes appear in allNodes
        // (deterministic with respect to corpus order, not training-point
        // order — both shapes are valid since HDBSCAN.fit doesn't care).
        let coords: [[Double]] = orderedIncludedIDs.map { id in
            let c = coordByNodeID[id]!
            return [Double(c.x), Double(c.y)]
        }

        let fit: HDBSCAN.FitResult
        if coords.count >= 2 {
            fit = await Task.detached(priority: .userInitiated) {
                HDBSCAN.fit(coords: coords, minClusterSize: mcs, minSamples: minSamplesOverride)
            }.value
        } else {
            clusterExportError = "fit has \(coords.count) included points; need ≥ 2"
            return
        }
        let resolvedMinSamples = resolveMinSamplesUsed(
            override: minSamplesOverride,
            minClusterSize: mcs,
            n: coords.count
        )

        // Map nodeID → cluster output via the included-index sequence.
        var hdbscanByNodeID: [String: ClusterDiagnosticExportPayload.NodeEntry.HDBSCANBlock] = [:]
        for (i, id) in orderedIncludedIDs.enumerated() {
            let label = fit.labels[i]
            hdbscanByNodeID[id] = .init(
                clusterLabel: label,
                membershipProbability: fit.probabilities[i],
                isNoise: label == -1
            )
        }

        // Compute centroids per cluster (renumbered id 0..k-1).
        let k = fit.selectedInternalClusterIDs.count
        var centroidSumX = [Double](repeating: 0, count: k)
        var centroidSumY = [Double](repeating: 0, count: k)
        var centroidCount = [Int](repeating: 0, count: k)
        var clusterMembers = [[Int]](repeating: [], count: k)
        for (i, label) in fit.labels.enumerated() where label >= 0 && label < k {
            centroidSumX[label] += coords[i][0]
            centroidSumY[label] += coords[i][1]
            centroidCount[label] += 1
            clusterMembers[label].append(i)
        }
        var clusterSummaries: [ClusterDiagnosticExportPayload.ClusterSummary] = []
        for n in 0..<k {
            let cnt = max(centroidCount[n], 1)
            clusterSummaries.append(.init(
                clusterID: n,
                size: centroidCount[n],
                stability: fit.selectedClusterStabilityScores[n],
                internalID: fit.selectedInternalClusterIDs[n],
                fmNeighborhoodTitle: nil,  // pipeline not wired (see 4b closeout)
                centroid2D: [centroidSumX[n] / Double(cnt), centroidSumY[n] / Double(cnt)]
            ))
        }

        // Build joined per-node entries.
        let nodeEntries: [ClusterDiagnosticExportPayload.NodeEntry] = allNodes.map { node in
            let bucket = bucketByID[node.id] ?? .excludedNoSubstrate
            let isRankable = substrate.isRankable(node)
            let contentPreview = String(substrateContentText(node).prefix(200))

            let excluded: ClusterDiagnosticExportPayload.NodeEntry.ExcludedFromFit
            let coord: [Double]?
            switch bucket {
            case .included(let c):
                excluded = .included
                coord = [Double(c.x), Double(c.y)]
            case .excludedThinContent:
                excluded = .thinContent
                coord = nil
            case .excludedMeta:
                excluded = .meta
                coord = nil
            case .excludedNoSubstrate:
                excluded = .noSubstrateVector
                coord = nil
            }
            let hdbscanBlock = hdbscanByNodeID[node.id]

            return ClusterDiagnosticExportPayload.NodeEntry(
                nodeID: node.id,
                title: node.title,
                contentPreview: contentPreview,
                tags: node.tags,
                embeddingFailureReason: node.embeddingFailureReason,
                isRankable: isRankable,
                excludedFromFit: excluded,
                substrate: .init(
                    summary: node.substrateSummary,
                    folksonomy: node.folksonomy
                ),
                legacyFM: .init(
                    summary: node.summary,
                    tagSources: node.tagSources.mapValues { $0.source.rawValue },
                    mood: node.mood,
                    domain: node.domain,
                    fmSuggestedNeighborhoodID: node.fmSuggestedNeighborhoodID,
                    contentEmbeddingPresent: node.contentEmbedding?.isEmpty == false
                ),
                umapCoord2D: coord,
                hdbscan: hdbscanBlock
            )
        }

        let nExcluded = bucketByID.values.reduce(into: 0) { acc, b in
            switch b {
            case .included: break
            default: acc += 1
            }
        }
        let nNoise = fit.labels.filter { $0 == -1 }.count

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = ClusterDiagnosticExportPayload(
            schemaVersion: 2,
            exportedAt: isoFormatter.string(from: Date()),
            fitMetadata: .init(
                fitVersion: model.fitVersion,
                fittedAt: isoFormatter.string(from: model.fittedAt),
                nInputPoints: orderedIncludedIDs.count,
                nExcluded: nExcluded,
                nClustersFound: k,
                nNoisePoints: nNoise,
                minClusterSizeUsed: mcs,
                minSamplesUsed: resolvedMinSamples,
                umapHyperparameters: model.hyperparameters
            ),
            clusterSummaries: clusterSummaries,
            nodes: nodeEntries
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)

            let docs = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let stamp = exportFilenameTimestamp()
            let url = docs.appendingPathComponent("substrate-cluster-diagnostic-\(stamp).json")
            try data.write(to: url, options: .atomic)
            clusterExportResult = ExportResult(
                url: url,
                nodeCount: allNodes.count,
                elapsed: Date().timeIntervalSince(start)
            )
        } catch {
            clusterExportError = String(describing: error)
            clusterExportResult = nil
        }
    }

    private func previewVec(_ vec: [Float]?) -> [Float]? {
        guard let vec, !vec.isEmpty else { return nil }
        return Array(vec.prefix(8))
    }

    private func substrateContentText(_ node: Node) -> String {
        // Mirror of CorpusStore.extractNodeContent — kept here so the export
        // doesn't require a CorpusStore-internal accessor.
        node.items.compactMap { item -> String? in
            switch item.type {
            case .text:              return item.content
            case .audio, .video:     return item.transcript
            case .image, .document:  return item.description
            case .link:              return [item.title, item.preview].compactMap { $0 }.joined(separator: " ")
            case .imageVideo:        return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func substrateContentLength(_ node: Node) -> Int {
        substrateContentText(node).count
    }

    private func top5Neighbors(
        for node: Node,
        in allNodes: [Node],
        substrate: SubstrateService
    ) -> [SubstrateExportPayload.Neighbor] {
        // Skip the work entirely when this node itself is unrankable —
        // top-K consumers (Stage 2 threads etc.) shouldn't surface neighbors
        // for thin-content stubs. The diagnostic export reflects that rule.
        guard substrate.isRankable(node) else { return [] }
        var scored: [(Node, Double)] = []
        scored.reserveCapacity(allNodes.count)
        for other in allNodes where other.id != node.id {
            let p = substrate.rankingPairSimilarity(node, other)
            if let blended = p.blended {
                scored.append((other, blended))
            }
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { (other, score) in
                SubstrateExportPayload.Neighbor(
                    id: other.id,
                    title: String(other.title.prefix(80)),
                    blendedCosine: score
                )
            }
    }

    private func exportFilenameTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: Date())
    }

    // MARK: - Stage 4b — substrate layout (UMAP)

    /// SB139 Stage 4c1.3 — diagnostic stats comparing display positions
    /// to truth positions. PBD has no displacement cap, so the diagnostic
    /// surfaces raw mean and max — large numbers indicate dense regions
    /// where projection had to push truth coords apart aggressively.
    private struct RelaxationStats {
        let mean: CGFloat
        let max: CGFloat
        let total: Int
    }

    private func computeRelaxationStats() -> RelaxationStats? {
        let svc = SubstrateLayoutService.shared
        guard let displayMap = svc.displayCanvasPositions,
              let placements = svc.canvasPlacements(),
              !displayMap.isEmpty
        else { return nil }
        let truth = SubstrateCanvasLayoutAdapter.map(placements).positions
        var deltas: [CGFloat] = []
        deltas.reserveCapacity(displayMap.count)
        for (id, disp) in displayMap {
            guard let t = truth[id] else { continue }
            let dx = CGFloat(disp.x - t.x)
            let dy = CGFloat(disp.y - t.y)
            deltas.append((dx * dx + dy * dy).squareRoot())
        }
        guard !deltas.isEmpty else { return nil }
        return RelaxationStats(
            mean: deltas.reduce(0, +) / CGFloat(deltas.count),
            max: deltas.max() ?? 0,
            total: deltas.count
        )
    }

    @ViewBuilder
    private var substrateRelaxationDeltaRows: some View {
        if let s = computeRelaxationStats() {
            statRow("Δ mean", String(format: "%.1f pt", Double(s.mean)))
            statRow("Δ max", String(format: "%.1f pt", Double(s.max)))
            statRow("Relaxed nodes", "\(s.total)")
        } else {
            statRow("Relaxation", "not computed")
        }
    }

    private var substrateLayoutSection: some View {
        let refusedCount = store.nodes.filter { $0.embeddingFailureReason == "guardrail_refused" }.count
        let backfillState = store.substrateBackfill
        let backfillInFlight = backfillState != nil && backfillState?.done == false
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Stage 4b — substrate layout (UMAP)")
            Toggle(isOn: $substrateLayoutFlag) {
                Text("FeatureFlags.substrateLayout")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .tint(.purple)

            Toggle(isOn: $substrateRelaxationFlag) {
                Text("FeatureFlags.substrateRelaxation")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .tint(.purple)

            // SB139 Stage 4c1.3 — truth vs. display delta. Surfaces how
            // much relaxation budget the current fit consumes so T can
            // judge whether seeds are over- or under-relaxed without
            // eyeballing the canvas. Mean |Δ| in pt and the per-node max.
            substrateRelaxationDeltaRows

            // Refused-content fallback chain (ws-refused-content-fallback-chain).
            // Re-embeds every `guardrail_refused` node using legacy summary +
            // user-tags so the substrate vectors share a distribution with
            // blended nodes before UMAP fit. Idempotent. Run this before a
            // fit when validating hypothesis-3 (refused-vs-blended x-distribution).
            Button {
                Task { await store.backfillRefusedNodesFallback() }
            } label: {
                Text(backfillInFlight ? "Backfilling…" : "Backfill refused-node fallback (\(refusedCount))")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity((backfillInFlight || refusedCount == 0) ? 0.4 : 0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(backfillInFlight || refusedCount == 0)

            // Per-fit hyperparameter overrides for the 2026-05-12 density
            // sweep (n_neighbors × min_dist). Empty → UMAP defaults (15,
            // 0.1). Resolved values land in UMAPFitInspectResult and the
            // JSON export's fit_metadata.umap_hyperparameters envelope so
            // sweep runs are self-documenting.
            HStack(spacing: 8) {
                Text("n_neighbors")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("15", text: $umapNNeighborsText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 70)
                Text(umapNNeighborsText.isEmpty ? "default 15" : "")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            HStack(spacing: 8) {
                Text("min_dist")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("0.1", text: $umapMinDistText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 70)
                Text(umapMinDistText.isEmpty ? "default 0.1" : "")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }

            Button {
                Task { await runUMAPFit() }
            } label: {
                Text(umapFitInProgress ? "Fitting…" : "Fit substrate UMAP on corpus")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(umapFitInProgress ? 0.4 : 0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(umapFitInProgress)

            if let r = umapFitResult {
                statRow("Included in fit", "\(r.included) of \(r.totalConsidered)")
                statRow("Excluded — thin_content", "\(r.excludedThinContent.count)")
                statRow("Excluded — meta", "\(r.excludedMeta.count)")
                statRow("Excluded — no substrate vector", "\(r.excludedNoSubstrate.count)")
                statRow("fitVersion", "\(r.fitVersion)")
                statRow("n_neighbors", "\(r.hyperparameters.nNeighbors)")
                statRow("min_dist", String(format: "%.3f", r.hyperparameters.minDist))
                if let t = r.lastActivityAt {
                    statRow("lastActivityAt", DateFormatter.substrateLog.string(from: t))
                }
                statRow("Elapsed", String(format: "%.2fs", r.elapsed))

                if r.anyExcluded {
                    Button {
                        umapShowExcluded.toggle()
                    } label: {
                        Text(umapShowExcluded ? "Hide excluded nodes" : "Show excluded nodes")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if umapShowExcluded {
                        excludedNodesList(r)
                    }
                }
            }

            if let err = umapFitError {
                Text("fit failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func excludedNodesList(_ r: UMAPFitInspectResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !r.excludedThinContent.isEmpty {
                excludedBucketHeader("thin_content", count: r.excludedThinContent.count)
                ForEach(r.excludedThinContent) { excludedNodeRow($0) }
            }
            if !r.excludedMeta.isEmpty {
                excludedBucketHeader("meta", count: r.excludedMeta.count)
                ForEach(r.excludedMeta) { excludedNodeRow($0) }
            }
            if !r.excludedNoSubstrate.isEmpty {
                excludedBucketHeader("no substrate vector", count: r.excludedNoSubstrate.count)
                ForEach(r.excludedNoSubstrate) { excludedNodeRow($0) }
            }
        }
    }

    private func excludedBucketHeader(_ label: String, count: Int) -> some View {
        Text("\(label) (\(count))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 4)
    }

    private func excludedNodeRow(_ en: ExcludedNodeEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(en.title.isEmpty ? "(untitled)" : en.title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            if !en.contentPreview.isEmpty {
                Text(en.contentPreview)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(3)
            }
            Text(en.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.3))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @MainActor
    private func runUMAPFit() async {
        umapFitInProgress = true
        umapFitError = nil
        defer { umapFitInProgress = false }

        // Resolve overrides. Empty text falls through to UMAP defaults
        // (15, 0.1) via UMAPHyperparameters.default. Validation surfaces
        // bad input before fit starts so the user gets immediate feedback.
        var hp = UMAPHyperparameters.default
        let nbrsTrimmed = umapNNeighborsText.trimmingCharacters(in: .whitespaces)
        if !nbrsTrimmed.isEmpty {
            guard let n = Int(nbrsTrimmed), n >= 2 else {
                umapFitError = "n_neighbors must be empty (default 15) or an integer ≥ 2"
                return
            }
            hp.nNeighbors = n
        }
        let mdTrimmed = umapMinDistText.trimmingCharacters(in: .whitespaces)
        if !mdTrimmed.isEmpty {
            guard let d = Double(mdTrimmed), d >= 0.0, d <= 0.99 else {
                umapFitError = "min_dist must be empty (default 0.1) or in [0.0, 0.99]"
                return
            }
            hp.minDist = d
        }

        let start = Date()
        let nodes = store.nodes
        let substrate = SubstrateService.shared
        let layout = SubstrateLayoutService.shared

        var excludedThinContent: [ExcludedNodeEntry] = []
        var excludedMeta: [ExcludedNodeEntry] = []
        var excludedNoSubstrate: [ExcludedNodeEntry] = []
        var included = 0

        // Mirror SubstrateLayoutService.fit()'s filter to surface honest
        // bucket counts. Order matches the service so each node lands in
        // exactly one bucket.
        for node in nodes {
            if !substrate.isRankable(node) {
                excludedThinContent.append(excludedEntry(node))
                continue
            }
            if node.isMeta {
                excludedMeta.append(excludedEntry(node))
                continue
            }
            if layout.substrateVector(for: node) == nil {
                excludedNoSubstrate.append(excludedEntry(node))
                continue
            }
            included += 1
        }

        do {
            let model = try await layout.fit(allNodes: nodes, hyperparameters: hp)
            umapFitResult = UMAPFitInspectResult(
                included: included,
                excludedThinContent: excludedThinContent,
                excludedMeta: excludedMeta,
                excludedNoSubstrate: excludedNoSubstrate,
                elapsed: Date().timeIntervalSince(start),
                fitVersion: model.fitVersion,
                lastActivityAt: layout.lastActivityAt,
                hyperparameters: model.hyperparameters
            )
        } catch {
            umapFitError = String(describing: error)
        }
    }

    private func excludedEntry(_ node: Node) -> ExcludedNodeEntry {
        ExcludedNodeEntry(
            id: node.id,
            title: String(node.title.prefix(80)),
            contentPreview: String(substrateContentText(node).prefix(160))
        )
    }

    // MARK: - Stage 4b — substrate clustering (HDBSCAN)

    private var substrateClusterSection: some View {
        let layout = SubstrateLayoutService.shared
        let modelLoaded = layout.fittedModel != nil
        let pointCount = layout.fittedModel?.trainingPoints.count ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Stage 4b — substrate clustering (HDBSCAN)")
            statRow("Fitted UMAP model", modelLoaded ? "loaded · \(pointCount) points" : "not loaded")

            HStack(spacing: 8) {
                Text("min_cluster_size")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("8", text: $hdbscanMinClusterSizeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 70)
            }
            HStack(spacing: 8) {
                Text("min_samples")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("", text: $hdbscanMinSamplesText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 70)
                Text(hdbscanMinSamplesText.isEmpty
                     ? "auto (= min_cluster_size)"
                     : "")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }

            Button {
                Task { await runHDBSCANFit() }
            } label: {
                Text(hdbscanFitInProgress ? "Clustering…" : "Cluster substrate UMAP coords")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity((hdbscanFitInProgress || !modelLoaded) ? 0.4 : 0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(hdbscanFitInProgress || !modelLoaded)

            if let r = hdbscanFitResult {
                statRow("min_cluster_size used", "\(r.minClusterSize)")
                statRow("min_samples used", "\(r.minSamplesUsed)")
                statRow("Total points", "\(r.totalPoints)")
                statRow("Clusters found", "\(r.clusterCount)")
                statRow("Noise points", "\(r.noiseCount)")
                statRow("Elapsed", String(format: "%.2fs", r.elapsed))
                if !r.clusters.isEmpty {
                    Text("Clusters (id · size · stability)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                    ForEach(r.clusters) { hdbscanClusterRowView($0) }
                }
                if !r.noiseSampleTitles.isEmpty {
                    Text("Noise (first 5)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                    ForEach(Array(r.noiseSampleTitles.enumerated()), id: \.offset) { _, t in
                        Text(t.isEmpty ? "(untitled)" : t)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let err = hdbscanFitError {
                Text("cluster failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hdbscanClusterRowView(_ row: HDBSCANClusterRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("c\(row.id) · n=\(row.size) · s=\(String(format: "%.3f", row.stabilityScore))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("int=\(row.internalID)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(Array(row.sampleTitles.enumerated()), id: \.offset) { _, t in
                Text("  · \(t.isEmpty ? "(untitled)" : t)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func runHDBSCANFit() async {
        hdbscanFitInProgress = true
        hdbscanFitError = nil
        defer { hdbscanFitInProgress = false }

        guard let model = SubstrateLayoutService.shared.fittedModel else {
            hdbscanFitError = "no fitted UMAP model — run the UMAP fit above first"
            return
        }
        let mcs = Int(hdbscanMinClusterSizeText) ?? 8
        guard mcs >= 2 else {
            hdbscanFitError = "min_cluster_size must be ≥ 2"
            return
        }
        // Empty text → nil → auto-defaults to min_cluster_size at the
        // HDBSCAN.fit boundary (matches Python hdbscan_.py:714-715).
        let trimmed = hdbscanMinSamplesText.trimmingCharacters(in: .whitespaces)
        let minSamplesOverride: Int?
        if trimmed.isEmpty {
            minSamplesOverride = nil
        } else if let parsed = Int(trimmed), parsed >= 1 {
            minSamplesOverride = parsed
        } else {
            hdbscanFitError = "min_samples must be empty (auto) or ≥ 1"
            return
        }
        let pts = model.trainingPoints
        guard pts.count >= 2 else {
            hdbscanFitError = "fitted model has \(pts.count) points; need ≥ 2"
            return
        }

        let start = Date()
        let coords: [[Double]] = pts.map { [Double($0.coord2D.x), Double($0.coord2D.y)] }

        let fit = await Task.detached(priority: .userInitiated) {
            HDBSCAN.fit(coords: coords, minClusterSize: mcs, minSamples: minSamplesOverride)
        }.value
        // Resolve what min_samples actually got used (mirrors fit()'s
        // internal default + clamp so the surface is honest).
        let resolvedMinSamples = resolveMinSamplesUsed(
            override: minSamplesOverride,
            minClusterSize: mcs,
            n: coords.count
        )

        let nodesByID = Dictionary(uniqueKeysWithValues: store.nodes.map { ($0.id, $0) })
        let titleFor: (Int) -> String = { idx in
            let id = pts[idx].nodeID
            return nodesByID[id]?.title ?? id
        }

        var indicesByLabel: [Int: [Int]] = [:]
        for (i, label) in fit.labels.enumerated() {
            indicesByLabel[label, default: []].append(i)
        }
        let noiseIndices = indicesByLabel[-1] ?? []
        let noiseSampleTitles = noiseIndices.prefix(5).map { titleFor($0) }

        var clusterRows: [HDBSCANClusterRow] = []
        for n in 0..<fit.selectedInternalClusterIDs.count {
            let members = indicesByLabel[n] ?? []
            let sampleTitles = members.prefix(3).map { titleFor($0) }
            clusterRows.append(HDBSCANClusterRow(
                id: n,
                internalID: fit.selectedInternalClusterIDs[n],
                size: members.count,
                stabilityScore: fit.selectedClusterStabilityScores[n],
                sampleTitles: Array(sampleTitles)
            ))
        }

        hdbscanFitResult = HDBSCANFitInspectResult(
            totalPoints: fit.labels.count,
            clusterCount: fit.selectedInternalClusterIDs.count,
            noiseCount: noiseIndices.count,
            minClusterSize: mcs,
            minSamplesUsed: resolvedMinSamples,
            elapsed: Date().timeIntervalSince(start),
            clusters: clusterRows,
            noiseSampleTitles: Array(noiseSampleTitles)
        )
    }

    /// Mirrors HDBSCAN.fit()'s min_samples resolution + clamp:
    /// `nil → min_cluster_size`, then `min(n - 1, raw)`, floored at 1.
    /// Kept here so the inspect surface and the cluster-export envelope
    /// agree on what *actually* got used.
    private func resolveMinSamplesUsed(
        override: Int?,
        minClusterSize: Int,
        n: Int
    ) -> Int {
        let raw = override ?? minClusterSize
        let clamped = Swift.min(n - 1, raw)
        return clamped == 0 ? 1 : clamped
    }

    // MARK: - Reusable bits

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.5))
            .tracking(1.2)
    }

    private func statRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
        }
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nodePicker(label: String, selection: Binding<String?>) -> some View {
        // Sort nodes by recency; show title + short ID so duplicates are visible.
        let nodes = store.nodes.sorted { $0.createdAt > $1.createdAt }
        return Menu {
            Button("(none)") { selection.wrappedValue = nil }
            ForEach(nodes, id: \.id) { node in
                Button {
                    selection.wrappedValue = node.id
                } label: {
                    Text(menuLabel(for: node))
                }
            }
        } label: {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(selection.wrappedValue.flatMap { id in
                    nodes.first(where: { $0.id == id }).map(menuLabel(for:))
                } ?? "—")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func menuLabel(for node: Node) -> String {
        let title = node.title.isEmpty ? "(untitled)" : node.title
        return "\(String(node.id.prefix(6))) · \(title.prefix(40))"
    }
}

private extension DateFormatter {
    static let substrateLog: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()
}

// MARK: - Diagnostic export payload

/// Snake-cased JSON shape per the SB139 Stage 1 diagnostic export spec.
/// Embedding *previews* are first-8-dim slices, NOT full vectors — this is a
/// sanity-check dump, not a corpus snapshot.
struct SubstrateExportPayload: Encodable {
    let exportedAt: String
    let embedderVersion: Int
    let corpusMeans: Means
    let nodes: [NodeEntry]

    struct Means: Encodable {
        let summary: [Float]?
        let folksonomy: [Float]?
        let content: [Float]?
    }

    struct NodeEntry: Encodable {
        let id: String
        let title: String
        let contentLength: Int
        let tags: [String]
        let substrate: Substrate
        let top5Neighbors: [Neighbor]

        struct Substrate: Encodable {
            let summary: String?
            let folksonomy: [String]?
            let summaryEmbeddingPresent: Bool
            let folksonomyEmbeddingPresent: Bool
            let contentEmbeddingPresent: Bool
            let embeddingFailureReason: String?
            let summaryEmbeddingPreview: [Float]?
            let folksonomyEmbeddingPreview: [Float]?
            let contentEmbeddingPreview: [Float]?
            /// Debug-only: raw content text. Populated *only* when
            /// `embedding_failure_reason == "fm_error"` so we can analyze
            /// content patterns across all FM failures at once. Custom encode
            /// uses `encodeIfPresent` so the key is absent (not null) on
            /// other nodes. Remove once the FM-error pattern is understood.
            let contentFull: String?
            /// Diagnostic-only sidecar populated *only* when
            /// `embedding_failure_reason == "fm_error"`. Captures the raw
            /// error type + Context.debugDescription as observed at call
            /// time so the textual classifier in `processSubstrate` can be
            /// tuned against actual strings instead of inferred ones.
            let fmErrorDetail: FMErrorDetail?

            enum CodingKeys: String, CodingKey {
                case summary
                case folksonomy
                case summaryEmbeddingPresent = "summary_embedding_present"
                case folksonomyEmbeddingPresent = "folksonomy_embedding_present"
                case contentEmbeddingPresent = "content_embedding_present"
                case embeddingFailureReason = "embedding_failure_reason"
                case summaryEmbeddingPreview = "summary_embedding_preview"
                case folksonomyEmbeddingPreview = "folksonomy_embedding_preview"
                case contentEmbeddingPreview = "content_embedding_preview"
                case contentFull = "content_full"
                case fmErrorDetail = "fm_error_detail"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(summary, forKey: .summary)
                try c.encode(folksonomy, forKey: .folksonomy)
                try c.encode(summaryEmbeddingPresent, forKey: .summaryEmbeddingPresent)
                try c.encode(folksonomyEmbeddingPresent, forKey: .folksonomyEmbeddingPresent)
                try c.encode(contentEmbeddingPresent, forKey: .contentEmbeddingPresent)
                try c.encode(embeddingFailureReason, forKey: .embeddingFailureReason)
                try c.encode(summaryEmbeddingPreview, forKey: .summaryEmbeddingPreview)
                try c.encode(folksonomyEmbeddingPreview, forKey: .folksonomyEmbeddingPreview)
                try c.encode(contentEmbeddingPreview, forKey: .contentEmbeddingPreview)
                try c.encodeIfPresent(contentFull, forKey: .contentFull)
                try c.encodeIfPresent(fmErrorDetail, forKey: .fmErrorDetail)
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, title, tags, substrate
            case contentLength = "content_length"
            case top5Neighbors = "top_5_neighbors"
        }
    }

    struct Neighbor: Encodable {
        let id: String
        let title: String
        let blendedCosine: Double

        enum CodingKeys: String, CodingKey {
            case id, title
            case blendedCosine = "blended_cosine"
        }
    }

    enum CodingKeys: String, CodingKey {
        case nodes
        case exportedAt = "exported_at"
        case embedderVersion = "embedder_version"
        case corpusMeans = "corpus_means"
    }
}

// MARK: - Cluster diagnostic export payload (SB139 Stage 4b)

/// Joined diagnostic view for HDBSCAN cluster validation. One JSON per
/// (fit, cluster) pair. Carries substrate inputs + UMAP coords + HDBSCAN
/// cluster outputs per node so the "did recipes cluster together?" class
/// of question is answerable from a single file. See T's 2026-05-12 spec.
struct ClusterDiagnosticExportPayload: Encodable {
    let schemaVersion: Int
    let exportedAt: String
    let fitMetadata: FitMetadata
    let clusterSummaries: [ClusterSummary]
    let nodes: [NodeEntry]

    struct FitMetadata: Encodable {
        let fitVersion: Int
        let fittedAt: String
        let nInputPoints: Int
        let nExcluded: Int
        let nClustersFound: Int
        let nNoisePoints: Int
        let minClusterSizeUsed: Int
        /// Resolved min_samples after `nil → min_cluster_size` default +
        /// `min(n-1, raw)` clamp. Mirrors hdbscan_.py:714-715 + 778-780.
        let minSamplesUsed: Int
        let umapHyperparameters: UMAPHyperparameters

        enum CodingKeys: String, CodingKey {
            case fitVersion = "fit_version"
            case fittedAt = "fitted_at"
            case nInputPoints = "n_input_points"
            case nExcluded = "n_excluded"
            case nClustersFound = "n_clusters_found"
            case nNoisePoints = "n_noise_points"
            case minClusterSizeUsed = "min_cluster_size_used"
            case minSamplesUsed = "min_samples_used"
            case umapHyperparameters = "umap_hyperparameters"
        }
    }

    struct ClusterSummary: Encodable {
        let clusterID: Int
        let size: Int
        let stability: Double
        let internalID: Int
        /// Null when the FM neighborhood-title pipeline hasn't run against
        /// substrate clusters. As of 2026-05-12 the wiring is pending —
        /// existing `NeighborhoodService` operates on Louvain
        /// tag-co-occurrence communities, not HDBSCAN clusters.
        let fmNeighborhoodTitle: String?
        let centroid2D: [Double]

        enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id"
            case size, stability
            case internalID = "internal_id"
            case fmNeighborhoodTitle = "fm_neighborhood_title"
            case centroid2D = "centroid_2d"
        }
    }

    struct NodeEntry: Encodable {
        let nodeID: String
        let title: String
        let contentPreview: String
        let tags: [String]
        let embeddingFailureReason: String?
        let isRankable: Bool
        /// `false` when the node is in the fit; otherwise one of
        /// `"thin_content"`, `"meta"`, `"no_substrate_vector"`. Mirrors the
        /// SubstrateLayoutService.fit() filter buckets exactly.
        let excludedFromFit: ExcludedFromFit
        let substrate: SubstrateBlock
        let legacyFM: LegacyFM
        /// Null for excluded nodes.
        let umapCoord2D: [Double]?
        /// Null for excluded nodes; otherwise the HDBSCAN block.
        let hdbscan: HDBSCANBlock?

        enum ExcludedFromFit: Encodable {
            case included
            case thinContent
            case meta
            case noSubstrateVector

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .included:           try c.encode(false)
                case .thinContent:        try c.encode("thin_content")
                case .meta:               try c.encode("meta")
                case .noSubstrateVector:  try c.encode("no_substrate_vector")
                }
            }
        }

        struct SubstrateBlock: Encodable {
            let summary: String?
            let folksonomy: [String]?
        }

        /// Pre-substrate FM artifacts. The tag/title FM pipeline runs first
        /// in `CorpusStore.processNode` and may succeed even when the
        /// substrate FM refuses on the same content (two distinct refusal
        /// criteria). Surfaced so the refused-content fallback chain can
        /// see which legacy-pipeline outputs survived the substrate refusal.
        struct LegacyFM: Encodable {
            /// `node.summary` — the legacy/tag-pipeline FM summary. Distinct
            /// from `substrate.summary` (which is `node.substrateSummary`).
            /// Non-optional on `Node`; may be empty string if the legacy FM
            /// also refused or the node predates the pipeline.
            let summary: String
            /// Per-tag provenance dictionary mirroring `node.tagSources`.
            /// Values are `"user"`, `"model"`, or `"promoted"`. Tags without
            /// a provenance entry on disk are omitted (legacy nodes
            /// predating `tagSources`). Derive untagged-provenance count
            /// from `len(node.tags) - len(tag_sources)`.
            let tagSources: [String: String]
            let mood: String?
            let domain: String?
            let fmSuggestedNeighborhoodID: String?
            /// `node.contentEmbedding` (SB126 `NLEmbedding.sentenceEmbedding`)
            /// presence. Separate embedder from the contextual embeddings in
            /// the substrate block; populated by the deterministic prefilter
            /// path, not the substrate pipeline.
            let contentEmbeddingPresent: Bool

            enum CodingKeys: String, CodingKey {
                case summary, mood, domain
                case tagSources = "tag_sources"
                case fmSuggestedNeighborhoodID = "fm_suggested_neighborhood_id"
                case contentEmbeddingPresent = "content_embedding_present"
            }
        }

        struct HDBSCANBlock: Encodable {
            let clusterLabel: Int
            let membershipProbability: Double
            let isNoise: Bool

            enum CodingKeys: String, CodingKey {
                case clusterLabel = "cluster_label"
                case membershipProbability = "membership_probability"
                case isNoise = "is_noise"
            }
        }

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case title, tags, substrate, hdbscan
            case contentPreview = "content_preview"
            case embeddingFailureReason = "embedding_failure_reason"
            case isRankable = "is_rankable"
            case excludedFromFit = "excluded_from_fit"
            case legacyFM = "legacy_fm"
            case umapCoord2D = "umap_coord_2d"
        }
    }

    enum CodingKeys: String, CodingKey {
        case nodes
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case fitMetadata = "fit_metadata"
        case clusterSummaries = "cluster_summaries"
    }
}
