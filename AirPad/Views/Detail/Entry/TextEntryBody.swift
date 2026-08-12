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
        static let shadowRadius: CGFloat = 12       // (dark) shadow blur
        static let shadowY: CGFloat = 4             // (dark) shadow downward offset
        // Light (bake 2026-08-12, ground B): T device-dialed warm lift (#43372A hue,
        // reused from the card shadow) off the same-colour ground — separation is
        // the shadow, not hue. Dark keeps shadowRadius/shadowY above.
        static let lightShadowOpacity: Double = 0.143
        static let lightShadowRadius:  CGFloat = 5.6
        static let lightShadowY:       CGFloat = 0
        static let rimOpacity: Double = 0.10        // top-edge white rim light
        static let rimWidth: CGFloat = 1            // rim hairline width
    }

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var editingText = ""
    @State private var didConsumeAutoFocus = false
    /// Photos-picker selection for inserting an inline image into the note.
    @State private var pickerItem: PhotosPickerItem? = nil
    /// Present the picker from a Button so we can capture the caret BEFORE it opens.
    @State private var showPhotoPicker = false
    /// Bridge to ask the editor to insert an image at a remembered caret.
    @State private var imageInsertion = InlineImageInsertion()

    // Note-primitive separation (bake 2026-08-12, ground B — T device-dialed). LIGHT:
    // the note fills with the SAME card surface (#FFFFFA) as the detail ground, so it
    // has no hue boundary and lifts purely by the drop shadow — a warm occlusion at
    // T's dialed values. DARK: the shipped `bgElevated` + `panelShadow`, unchanged.
    @Environment(\.colorScheme) private var colorScheme

    /// Note panel fill. Light: the card surface (#FFFFFA), matching the detail ground
    /// → separation is lift, not hue. Dark: `bgElevated` (#1A1A1A).
    private var noteFill: Color {
        colorScheme == .light
            ? Color(hexString: CardSurfaceResolved.resolvedCardBackgroundHex)   // #FFFFFA — = detail ground
            : AppearancePalette.bgElevated
    }
    /// Note lift shadow. Light: the card's warm occlusion hue (#43372A, reused from
    /// the card shadow path) at T's dialed strength. Dark: `panelShadow` (black@0.35).
    private var noteShadowColor: Color {
        colorScheme == .light
            ? Color(hexString: CardSurfaceStore.read(.shadowHex)).opacity(Panel.lightShadowOpacity)
            : AppearancePalette.panelShadow
    }
    private var noteShadowRadius: CGFloat {
        colorScheme == .light ? Panel.lightShadowRadius : Panel.shadowRadius
    }
    private var noteShadowYOffset: CGFloat {
        colorScheme == .light ? Panel.lightShadowY : Panel.shadowY
    }

    private var shouldAutoFocus: Bool {
        !didConsumeAutoFocus && store.pendingAutoFocusItemID == item.id
    }

    var body: some View {
        RichTextEditor(
            text: $editingText,
            onEndEditing: {
                // ws-card-catalog Change B — capture the text synchronously here
                // so a Done/dismiss that tears the view down before this Task runs
                // still persists the right body (the @State may be gone by then).
                let text = editingText
                guard text != (item.content ?? "") else { return }
                Task {
                    await store.updateTextItem(
                        itemID: item.id,
                        newContent: text,
                        nodeID: nodeID
                    )
                }
            },
            onChecklistMutated: {
                // A checkbox tap updates the on-screen text but never defocuses
                // the field, so onEndEditing (the usual save) never fires. Persist
                // now so the tick survives an immediate app close / relaunch.
                let text = editingText
                guard text != (item.content ?? "") else { return }
                Task {
                    await store.updateTextItem(
                        itemID: item.id,
                        newContent: text,
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
            resolveImage: { await store.inlineImage(forItemID: $0, nodeID: nodeID) },
            // photo-at-caret: the editor wires this so we can capture the caret + splice.
            inlineImageInsertion: imageInsertion,
            // Launcher bar `image` category → present the picker. The editor already
            // captured the caret at the tap (state.insertImage); this just presents.
            onInsertImageTapped: { showPhotoPicker = true }
        )
        // Comfortable internal text padding; the panel sits in the normal inset
        // column (the full-bleed `.padding(.horizontal, -32)` hack is gone).
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ws-dark-light-mode + note-primitive bake — the raised note panel fill.
        // DARK #1A1A1A (identical to the matched-tone ground; lifts by shadow + rim).
        // LIGHT: the card surface #FFFFFA — the SAME colour as the detail ground, so
        // the note has no hue boundary and lifts purely by the shadow below. The note
        // TEXT stays on NoteTypography (adaptive, preserved) — only the panel fill here.
        .background(noteFill)
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
        // The drop shadow is the note's ONLY separation on light (note == ground).
        // Themed: DARK black@0.35 / r12 / y4 (`panelShadow`, identical). LIGHT: the
        // card's warm occlusion hue (#43372A) at T's dialed lift — see Panel.lightShadow*.
        .shadow(color: noteShadowColor,
                radius: noteShadowRadius, x: 0, y: noteShadowYOffset)
        // Inline-image insertion now lives on the launcher bar's `image` category
        // (ws-editor-chrome) — the orphaned top-right card button is gone. The picker
        // is still presented from here; the caret was captured at the bar tap.
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await insertPickedImage(newItem) }
        }
        // Capture mode: feed the live "has typed text" signal so the Cancel↔Done
        // pill flips as the user types (content only persists on end-editing).
        .onChange(of: editingText) { _, newValue in
            guard router.isCapturing, router.captureNodeID == nodeID else { return }
            router.captureDraftHasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: item.content) { old, new in
            // Sync the editor when the entry's content changes from OUTSIDE the
            // editor — e.g. PastePad routing pasted text into this (previously
            // empty) entry. Guarded so it only applies when the user hasn't
            // diverged locally (editingText still matches the old stored value),
            // so it never clobbers active typing. Mirrors NodeDetailView's
            // editedTitle/editedSummary reconciliation.
            if editingText == (old ?? "") { editingText = new ?? "" }
        }
        .onAppear {
            editingText = item.content ?? ""
            if shouldAutoFocus {
                didConsumeAutoFocus = true
                store.pendingAutoFocusItemID = nil
            }
        }
    }

    /// Persist the picked image as an `.imageVideo` item, then insert its token at
    /// the caret remembered when the photo button was tapped — the editor splices a
    /// placeholder attachment there and re-encodes (encode walks runs in order, so
    /// the token lands in place; no cursor↔markdown mapping). Falls back to appending
    /// (today's behaviour) for an empty note or if the text changed while the picker
    /// was up. The decode path renders the attachment; the standalone entry is
    /// de-dup'd out of the payload list.
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

        if imageInsertion.insert(itemID: id) {
            // Editor spliced at the caret + pushed the binding; `editingText` is the
            // new markdown with the token in place. Persist it.
            await store.updateTextItem(itemID: item.id, newContent: editingText, nodeID: nodeID)
        } else {
            // Fallback (empty note, or text changed while the picker was up): append.
            let token = MarkdownCodec.imageToken(itemID: id)
            let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = trimmed.isEmpty ? token : editingText + "\n\n" + token
            editingText = newText
            await store.updateTextItem(itemID: item.id, newContent: newText, nodeID: nodeID)
        }
    }
}
