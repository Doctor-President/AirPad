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
@available(iOS 17.0, *)
struct SubstrateInspectView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedNodeID: String? = nil
    @State private var pairLeftID: String? = nil
    @State private var pairRightID: String? = nil
    @State private var batchSizeText: String = "10"
    @State private var selfTestResult: String? = nil

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
                    backfillSection
                    Divider().background(Color.white.opacity(0.1))
                    selfTestSection
                }
                .padding(20)
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
            if let s = state {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progressLine(s))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("ok=\(s.succeeded) refused=\(s.guardrailRefused) thin=\(s.thinContent) error=\(s.embedderError) pending=\(s.pendingAfter)")
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
        }
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
