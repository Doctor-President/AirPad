import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.text` entries. Renders inside an
/// `EntryCard`, so the card supplies title row, chrome, and timestamps;
/// this view is responsible only for the editable text surface itself.
///
/// The RichTextEditor keeps a subtle inset background so it reads as an
/// input field rather than blending into the card body — same affordance
/// the pre-3.1a row had.
///
/// Inline-append: when a fresh empty entry is created via the in-node "+"
/// → Text menu, `CorpusStore.appendEmptyTextItem` flags its ID on
/// `pendingAutoFocusItemID`. We consume that flag on first appearance and
/// pass `autoFocusOnAppear: true` to the editor so it raises the keyboard
/// directly — no sheet, no extra tap.
struct TextEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var editingText = ""
    @State private var didConsumeAutoFocus = false

    private var shouldAutoFocus: Bool {
        !didConsumeAutoFocus && store.pendingAutoFocusItemID == item.id
    }

    var body: some View {
        RichTextEditor(
            text: $editingText,
            onEndEditing: {
                guard editingText != (item.content ?? "") else { return }
                Task {
                    await store.updateTextItem(
                        itemID: item.id,
                        newContent: editingText,
                        nodeID: nodeID
                    )
                }
            },
            autoFocusOnAppear: shouldAutoFocus
        )
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            editingText = item.content ?? ""
            if shouldAutoFocus {
                didConsumeAutoFocus = true
                store.pendingAutoFocusItemID = nil
            }
        }
    }
}
