import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.text` entries. Renders inside an
/// `EntryCard`, so the card supplies title row, chrome, and timestamps;
/// this view is responsible only for the editable text surface itself.
///
/// The RichTextEditor sits on the adaptive Note background (`NoteTypography`)
/// — clean white in light, warm near-black in dark — so it reads as a real
/// document surface and flips correctly with the system appearance.
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
            autoFocusOnAppear: shouldAutoFocus,
            documentStyle: true,
            // Source Serif 4 is the Note typography default (SB121). Lora stays
            // bundled for the forthcoming user-selectable font picker.
            documentFont: .sourceSerif4
        )
        .padding(12)
        .background(Color(NoteTypography.background))
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
