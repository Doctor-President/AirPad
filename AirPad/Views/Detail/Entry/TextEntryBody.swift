import SwiftUI
import PhotosUI

/// Stage 3.1a commit (b) — body slot for `.text` entries. Renders inside an
/// `EntryCard`, so the card supplies title row, chrome, and timestamps;
/// this view is responsible only for the editable text surface itself.
///
/// The note is a **raised rounded panel**: same warm tone as the detail
/// surface (`NoteTypography.background` — clean white in light, warm near-black
/// in dark), lifted off that matched ground by light rather than colour — a
/// soft drop shadow plus a top-edge rim light. It sits in the normal inset
/// column (no full-bleed hack). `.text` entries only.
///
/// Inline-append: when a fresh empty entry is created via the in-node "+"
/// → Text menu, `CorpusStore.appendEmptyTextItem` flags its ID on
/// `pendingAutoFocusItemID`. We consume that flag on first appearance and
/// pass `autoFocusOnAppear: true` to the editor so it raises the keyboard
/// directly — no sheet, no extra tap.
struct TextEntryBody: View {

    let item: NodeItem
    let nodeID: String

    /// Raised-panel styling. The panel and the detail surface share a tone, so
    /// these light cues (shadow + rim) are what make the note float — all
    /// tunable so T can dial the lift on device.
    private enum Panel {
        static let cornerRadius: CGFloat = 24       // generous rounded panel
        static let shadowOpacity: Double = 0.35     // soft black drop shadow
        static let shadowRadius: CGFloat = 12       // shadow blur
        static let shadowY: CGFloat = 4             // shadow downward offset
        static let rimOpacity: Double = 0.10        // top-edge white rim light
        static let rimWidth: CGFloat = 1            // rim hairline width
    }

    @Environment(CorpusStore.self) private var store
    @State private var editingText = ""
    @State private var didConsumeAutoFocus = false
    /// Photos-picker selection for inserting an inline image into the note.
    @State private var pickerItem: PhotosPickerItem? = nil

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
            documentFont: .sourceSerif4,
            // Inline images: resolve a token's item id → image for rendering.
            resolveImage: { await store.inlineImage(forItemID: $0, nodeID: nodeID) }
        )
        // Comfortable internal text padding; the panel sits in the normal inset
        // column (the full-bleed `.padding(.horizontal, -32)` hack is gone).
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matched-tone fill, clipped to the rounded panel.
        .background(Color(NoteTypography.background))
        .clipShape(RoundedRectangle(cornerRadius: Panel.cornerRadius, style: .continuous))
        // Top-edge rim light: brightest along the upper edge, fading down the
        // sides, so the panel reads as catching ambient light from above. On a
        // same-tone surface this is the load-bearing "float" cue.
        .overlay(
            RoundedRectangle(cornerRadius: Panel.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(Panel.rimOpacity), Color.white.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: Panel.rimWidth
                )
        )
        // Soft drop shadow lifts the panel off the matched-gray ground.
        .shadow(color: .black.opacity(Panel.shadowOpacity),
                radius: Panel.shadowRadius, x: 0, y: Panel.shadowY)
        // Insert-image affordance: a small photos picker in the panel's top-right
        // (empty corner on a left-aligned note). Picking inserts the image inline
        // at the cursor.
        .overlay(alignment: .topTrailing) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(NoteTypography.foreground).opacity(0.5))
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await insertPickedImage(newItem) }
        }
        .onAppear {
            editingText = item.content ?? ""
            if shouldAutoFocus {
                didConsumeAutoFocus = true
                store.pendingAutoFocusItemID = nil
            }
        }
    }

    /// Persist the picked image as an `.imageVideo` item, then append its token
    /// to the note's markdown and save — the editor's decode path renders the
    /// attachment, and the standalone entry is de-dup'd out of the payload list.
    private func insertPickedImage(_ pickerItem: PhotosPickerItem) async {
        defer { self.pickerItem = nil }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self) else { return }
        // UIImage decodes by content, so the stored extension is cosmetic; jpg
        // keeps the filename simple. (Format-accurate extension is a later nicety.)
        let ext = "jpg"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do { try data.write(to: tmp) } catch { return }
        guard let id = await store.addInlineImageItem(nodeID: nodeID, sourceURL: tmp, fileExtension: ext) else { return }

        // Append the token on its own line, then persist so it lands in
        // item.content. NOTE: appends at the end of the note for now — reliable;
        // cursor-precise insertion is a follow-up (needs cursor↔markdown mapping).
        let token = MarkdownCodec.imageToken(itemID: id)
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = trimmed.isEmpty ? token : editingText + "\n\n" + token
        editingText = newText
        await store.updateTextItem(itemID: item.id, newContent: newText, nodeID: nodeID)
    }
}
