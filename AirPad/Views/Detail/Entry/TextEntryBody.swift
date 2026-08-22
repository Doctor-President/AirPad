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

    // SPIKE v2 (`spike-entry-spine`) — in-container heading row. Defaults keep
    // the legacy (non-spine) rendering byte-identical for callers that don't opt
    // in. When `spineMode` is true, row 1 (the derived heading) renders inside
    // the raised panel and the editor folds beneath it, driven by `isExpanded`.
    var isExpanded: Bool = true
    var onToggleExpansion: () -> Void = {}
    var reorderActive: Bool = false
    var headingFont: Font? = nil
    var spineMode: Bool = false

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
        Group {
            if spineMode { spineContainer } else { legacyPanel }
        }
        // editingText tracks item.content whether or not the body is in the tree
        // (spine mode drops the editor when collapsed, but the derived heading
        // still reads editingText), so these live on the OUTER view.
        .onChange(of: item.content) { old, new in
            // Sync the editor when the entry's content changes from OUTSIDE the
            // editor — e.g. PastePad routing pasted text into this (previously
            // empty) entry. Guarded so it only applies when the user hasn't
            // diverged locally (editingText still matches the old stored value),
            // so it never clobbers active typing.
            if editingText == (old ?? "") { editingText = new ?? "" }
        }
        // Capture-mode live signal + substrate mirror — hoisted off the editor so
        // it fires in spine mode whether the note is expanded or collapsed.
        .onChange(of: editingText) { _, newValue in
            store.mirrorPendingItemEdit(itemID: item.id, text: newValue)
            guard router.isCapturing, router.captureNodeID == nodeID else { return }
            router.captureDraftHasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onAppear {
            // R2 (v3.1 ruling) — DISPLAY-TRIM leading blank lines in spine mode so
            // the first non-empty line (the styled title) sits at line 1 and the
            // chevron/grip overlays align to it (consistent with the v2.1 ruling).
            let raw = item.content ?? ""
            editingText = spineMode ? Self.trimmingLeadingBlankLines(raw) : raw
            if shouldAutoFocus {
                didConsumeAutoFocus = true
                store.pendingAutoFocusItemID = nil
            }
        }
    }

    /// R2 — drop leading whitespace-only lines (keeps the rest verbatim).
    private static func trimmingLeadingBlankLines(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    /// Legacy (non-spine) rendering — byte-equivalent to the pre-spike panel for
    /// any caller that doesn't opt into `spineMode`.
    private var legacyPanel: some View {
        notePanel(
            editorCore(text: $editingText)
                // Comfortable internal text padding; the panel sits in the normal
                // inset column (the full-bleed `.padding(.horizontal, -32)` is gone).
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// SPIKE v3 — the in-container heading row. Row 1 = the plain-text render of
    /// the note's first non-empty line (A3); the body renders the content AFTER
    /// that line (A4 — the derived text appears exactly once, never duplicated).
    /// Both inside the unified filled container; the body indents to the shared
    /// text margin so heading and body share a left edge. Collapsed = the same
    /// container at row height (the editor drops out).
    private var spineContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                // Model C — the editor renders the FULL content; paragraph 1 IS the
                // title, styled in-editor (firstParagraphAsTitle). The derived text
                // exists exactly once — it IS line 1 (A4 by construction). Chevron +
                // grip float over line 1 (chevron in the gutter, grip trailing);
                // tapping line 1 edits the title (tap-to-rename free).
                editorCore(text: $editingText, firstParagraphAsTitle: true)
                    .padding(.leading, EntrySpineRow<EmptyView>.textMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) { chevronOverlay }
                    .overlay(alignment: .topTrailing) { gripOverlay }
            } else {
                // Collapsed — the static derived first-line row (plain-text A3),
                // same style/geometry as line 1 so the row reads invariant.
                EntrySpineRow(
                    name: split(editingText).heading,
                    isPlaceholder: split(editingText).placeholder,
                    isExpanded: false,
                    reorderActive: reorderActive,
                    nameFont: headingFont ?? .body,
                    onToggle: onToggleExpansion,
                    trailing: { EmptyView() }
                )
            }
        }
        .entrySpineContainer()
    }

    /// Expanded-state chevron — floats in the gutter, vertically centred on line 1
    /// (which sits at the editor top). Matches the collapsed row's chevron.
    private var chevronOverlay: some View {
        Button(action: onToggleExpansion) {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(reorderActive ? 0.25 : 0.40))
                .rotationEffect(.degrees(90))   // expanded → down
                .frame(width: EntrySpineRow<EmptyView>.textMargin,
                       height: EntrySpineRow<EmptyView>.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reorderActive)
    }

    /// Expanded-state grip — VISUAL ONLY, trailing, tracking line 1. Non-interactive
    /// so touches reach the editor / background recognizer.
    private var gripOverlay: some View {
        Text("⠿")
            .font(.system(size: 14, weight: .regular))
            .tracking(1)
            .foregroundStyle(AppearancePalette.ink.opacity(0.30))
            .frame(height: EntrySpineRow<EmptyView>.rowHeight)
            .allowsHitTesting(false)
    }

    /// Legacy raised-panel chrome (fill + top rim light + drop shadow + clip) —
    /// used ONLY by the non-spine path; spine mode uses `entrySpineContainer()`.
    private func notePanel<V: View>(_ content: V) -> some View {
        content
            .background(noteFill)
            .clipShape(RoundedRectangle(cornerRadius: Panel.cornerRadius, style: .continuous))
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
            .shadow(color: noteShadowColor,
                    radius: noteShadowRadius, x: 0, y: noteShadowYOffset)
    }

    /// The editable text surface + its edit-time hooks (picker). `text` differs
    /// per rendering: legacy binds the FULL content (`$editingText`); spine binds
    /// the body-after-heading (`bodyBinding`). The persistence closures read
    /// `editingText` (the full-content source of truth), so both persist correctly.
    private func editorCore(text: Binding<String>, firstParagraphAsTitle: Bool = false) -> some View {
        RichTextEditor(
            text: text,
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
            onInsertImageTapped: { showPhotoPicker = true },
            // SPIKE v3 Model C — style paragraph 1 as the entry title (spine only).
            firstParagraphAsTitle: firstParagraphAsTitle
        )
        // Inline-image insertion lives on the launcher bar's `image` category
        // (ws-editor-chrome); the picker is presented from here, caret captured
        // at the bar tap.
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await insertPickedImage(newItem) }
        }
    }

    // MARK: - A3 heading derivation + A4 body split

    /// A3 — plain-text RENDER of one markdown line: links → label, `**/*/_/#` and
    /// inline code stripped (decode applies them as attributes, not markers), HTML
    /// tags removed, the display bullet glyph + image attachments dropped,
    /// whitespace collapsed. A pure-markup / blank line renders empty.
    private func plainTextRender(_ line: String) -> String {
        var s = MarkdownCodec.decode(line).string
        s = s.replacingOccurrences(of: "\u{FFFC}", with: "")           // image attachment glyph
        if s.hasPrefix("• ") { s = String(s.dropFirst(2)) }             // display bullet glyph
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)  // HTML tags
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces)
        return s
    }

    /// A3/A4 — split the note into (heading, body). `heading` = the plain-text
    /// render of the first line that renders non-empty (blank + pure-markup lines
    /// skipped). `body` = everything AFTER that line. `prefix` = everything up to
    /// and INCLUDING it (preserved on reconstruction so no content is lost).
    /// Entirely empty / markup-only note → "Untitled" ghost, empty body.
    private func split(_ text: String) -> (heading: String, placeholder: Bool, prefix: String, body: String) {
        let lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let rendered = plainTextRender(lines[i])
            if rendered.isEmpty { continue }
            let prefix = lines[0...i].joined(separator: "\n")
            let body = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
            return (rendered, false, prefix, body)
        }
        return ("Untitled", true, text, "")
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
