import SwiftUI

/// Block-level citation sheet — presented when the user taps a Source
/// chip on an Ask response. Shows the actual passages that fed the
/// prompt so the user can verify what the model was looking at without
/// leaving the Librarian context. "Open Note" hands navigation back to
/// the host NavigationStack (same pattern as retrieval rows).
///
/// The chip row dedupes by `nodeID`, but a single node can carry
/// multiple matched blocks — this sheet is where those multiple
/// passages surface, numbered to align with the inline `[N]` markers
/// in the Ask response prose.
///
/// `blocks` is the *full* list of citations for the Ask response; the
/// sheet filters in-place so the bracket numbers stay stable with the
/// model's inline markers (i.e. if block 3 in the full set belongs to
/// the displayed node, it shows as `[3]`, not `[1]`).
struct CitationSheet: View {

    let nodeID: String
    let allCitations: [BlockMatch]
    let onOpenNote: () -> Void

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Bracket numbers in the prose are 1-indexed across the *full*
    /// citation list, so pull the 1-indexed positions of this node's
    /// blocks before filtering — `[1, 3, 5]` rather than re-indexing
    /// to `[1, 2, 3]`.
    private var matchesForNode: [(bracketIndex: Int, match: BlockMatch)] {
        allCitations.enumerated().compactMap { idx, match in
            match.nodeID == nodeID ? (idx + 1, match) : nil
        }
    }

    private var node: Node? {
        store.nodes.first { $0.id == nodeID }
    }

    private var nodeTitle: String {
        node?.title ?? "Untitled"
    }

    private var dotColor: Color {
        guard let primary = node?.primaryTag,
              let storeTag = store.tags.first(where: { $0.name == primary }),
              let color = Color(hex: storeTag.colorHex)
        else { return .gray.opacity(0.6) }
        return color
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    ForEach(matchesForNode, id: \.bracketIndex) { entry in
                        pullQuote(bracketIndex: entry.bracketIndex, match: entry.match)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onOpenNote()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Open")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            Text(nodeTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pullQuote(bracketIndex: Int, match: BlockMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("[\(bracketIndex)]")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))

            Text(match.block.text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
        }
    }
}
