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

    // ws-entry-containers — the note ALWAYS renders as the in-container heading
    // row (row 1 = the derived/edited title, the editor folds beneath it), driven
    // by `isExpanded`. Rendered exclusively by `EntryCard`.
    var isExpanded: Bool = true
    var onToggleExpansion: () -> Void = {}
    var reorderActive: Bool = false
    var headingFont: Font? = nil
    /// ws-entry-containers — the shared entry-level options (promote / rename /
    /// duplicate / copy / backlink / delete), EntryCard-owned. Combined below Read
    /// Aloud into the note's "..." menu (`noteGripMenu`). Nil → Read Aloud only.
    var optionsMenu: AnyView? = nil
    /// ws-entry-containers (4b) — the reorder grip drag handle (EntryCard's
    /// `dragRecognizer`), forwarded to the collapsed row's grip. Nil → no grip.
    var gripDragHandle: AnyView? = nil

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

    private var shouldAutoFocus: Bool {
        !didConsumeAutoFocus && store.pendingAutoFocusItemID == item.id
    }

    var body: some View {
        container
        // editingText tracks item.content whether or not the editor is in the tree
        // (collapsed drops the editor, but the derived heading still reads
        // editingText), so these live on the OUTER view.
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
            // DISPLAY-TRIM leading blank lines so the first non-empty line (the
            // styled title) sits at line 1 and the chevron/grip overlays align to it.
            editingText = Self.trimmingLeadingBlankLines(item.content ?? "")
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

    /// The in-container heading row. Row 1 = the note's first non-empty line: the
    /// LIVE editor's first paragraph when expanded (title styled in place), the
    /// derived plain-text render when collapsed. The derived text appears exactly
    /// once. Body indents to the shared text margin. Collapsed = the same container
    /// at row height (the editor drops out).
    private var container: some View {
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
                    // Expanded: "..." ONLY (no grip — reorder is a collapsed-row
                    // gesture), positioned at the SAME x it holds when collapsed.
                    .overlay(alignment: .topTrailing) { optionsOverlay }
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
                    trailing: { EmptyView() },
                    optionsMenu: noteGripMenu,
                    gripDragHandle: gripDragHandle
                )
            }
        }
        .entrySpineContainer()
    }

    /// The note's grip options menu — Read Aloud (the note-specific action, which
    /// needs the LIVE `editingText`, so it stays here rather than in EntryCard)
    /// followed by the shared entry-level options (`optionsMenu`, EntryCard-owned).
    private var noteGripMenu: AnyView {
        let tts = SpeechSynthesisService.shared
        let text = editingText
        let speaking = tts.activeToken == item.id && tts.isSpeaking && !tts.isPaused
        return AnyView(
            Group {
                Button {
                    tts.toggle(token: item.id, text: text)
                } label: {
                    Label(speaking ? "Pause reading" : "Read aloud",
                          systemImage: speaking ? "pause.fill" : "speaker.wave.2.fill")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let optionsMenu {
                    Divider()
                    optionsMenu
                }
            }
        )
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

    /// Expanded-state "..." options button — TAP-ONLY menu (Read Aloud + entry
    /// options), tracking line 1 at the trailing edge. The `.trailing` padding =
    /// the reserved grip-slot width + the row gap (10), so it holds the SAME
    /// x-position as the collapsed row's "..." (which sits just left of the grip
    /// slot). No grip in the expanded state — reorder is a collapsed-row gesture.
    private var optionsOverlay: some View {
        Menu { noteGripMenu } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(reorderActive ? 0.2 : 0.55))
                .frame(width: EntrySpineRow<EmptyView>.optionsWidth,
                       height: EntrySpineRow<EmptyView>.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reorderActive)
        .padding(.trailing, EntrySpineRow<EmptyView>.gripSlotWidth + 10)
        .accessibilityIdentifier("entryOptions")
    }

    /// The editable text surface + its edit-time hooks (picker). The persistence
    /// closures read `editingText` (the full-content source of truth).
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
