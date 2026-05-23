import SwiftUI
import UIKit

/// Reusable rich-text editor for AirPad. Wraps `UITextView` via `UIViewRepresentable`.
///
/// API surface is intentionally minimal so the component can be dropped into any
/// text-capture surface (NodeDetailView text items now, QuikCapture later, etc.):
///
/// - `text`: `Binding<String>` carrying the markdown content. Plain text is valid markdown,
///   so existing plain-text items pass through unchanged.
/// - `placeholder`: optional dim text shown when the editor is empty.
/// - `minHeight`: minimum vertical size; the editor grows past this with content.
/// - `onBeginEditing` / `onEndEditing`: lifecycle hooks the consumer can use to drive
///   save-on-defocus or other side effects. Persistence is the consumer's responsibility.
///
/// Height grows inline with content (via `sizeThatFits` + `isScrollEnabled = false`),
/// so the editor lives inside an outer `ScrollView` without its own inner scroll.
/// This is the Stage 2.1 inline-growth contract; Stage 2.2 must not regress it.
///
/// The keyboard toolbar is wired internally in Stage 2.2 step 2+; consumers get it for
/// free by adopting this component.
struct RichTextEditor: UIViewRepresentable {

    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 44
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil
    /// When true, the editor calls `becomeFirstResponder` once on first appearance.
    /// Used by the in-node "+" → Text path so a newly appended empty entry lands
    /// the user directly in the editor with the keyboard up. Consumers should
    /// clear the upstream trigger (e.g. `store.pendingAutoFocusItemID`) on
    /// `.onAppear` so subsequent renders don't re-focus.
    var autoFocusOnAppear: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RichTextUIView {
        let textView = RichTextUIView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .white
        textView.tintColor = .white
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.placeholderText = placeholder
        textView.minHeight = minHeight
        textView.attributedText = MarkdownCodec.decode(text)
        // Seed typingAttributes so the first keystroke into an empty editor renders white.
        // UIKit derives typingAttributes from the surrounding character on each cursor move,
        // but with no characters it falls back to system defaults — which on our dark
        // surfaces means black-on-black. Set them explicitly here and re-apply whenever
        // attributedText is replaced.
        textView.typingAttributes = Self.defaultTypingAttributes
        context.coordinator.attachToolbar(to: textView)
        if autoFocusOnAppear {
            // Dispatch so the view is in the window/responder chain before we
            // try to become first responder. Without the hop, becomeFirstResponder
            // is called during view construction and silently fails.
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        }
        return textView
    }

    func updateUIView(_ uiView: RichTextUIView, context: Context) {
        context.coordinator.parent = self
        // The binding carries markdown. Only re-render if the binding's markdown differs
        // from what's currently in the editor — otherwise we'd clobber typing in progress
        // (textViewDidChange pushes new markdown out, SwiftUI calls updateUIView, and we'd
        // re-decode and reset the cursor on every keystroke).
        let currentMarkdown = MarkdownCodec.encode(uiView.attributedText ?? NSAttributedString())
        if currentMarkdown != text {
            let previousRange = uiView.selectedRange
            uiView.attributedText = MarkdownCodec.decode(text)
            let length = uiView.attributedText.length
            let clampedLocation = min(previousRange.location, length)
            let clampedLength = min(previousRange.length, length - clampedLocation)
            uiView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            // After replacing attributedText, typingAttributes inherit from the new
            // surrounding character — or default to system attrs if the text is empty.
            // Re-seed for the empty case so the next keystroke stays white.
            if length == 0 {
                uiView.typingAttributes = Self.defaultTypingAttributes
            }
        }
        uiView.placeholderText = placeholder
        uiView.minHeight = minHeight
    }

    /// Default typing attributes for an empty editor — body font, white foreground.
    /// Used as a floor so the first keystroke into a freshly created entry is legible
    /// against the app's dark chrome.
    private static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.white
        ]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextUIView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        guard width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, minHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        let state = RichTextEditorState()
        private weak var textView: UITextView?
        private var toolbarHost: UIHostingController<RichTextToolbar>?

        init(parent: RichTextEditor) {
            self.parent = parent
            super.init()
            wireStateCommands()
        }

        // MARK: Toolbar wiring

        func attachToolbar(to textView: UITextView) {
            self.textView = textView
            let host = UIHostingController(rootView: RichTextToolbar(state: state))
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear

            let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
            container.autoresizingMask = .flexibleWidth
            container.backgroundColor = .clear
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            textView.inputAccessoryView = container
            self.toolbarHost = host
        }

        private func wireStateCommands() {
            state.dismissKeyboard = { [weak self] in
                self?.textView?.resignFirstResponder()
            }
            state.toggleBold = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleFontTrait(.traitBold, in: tv)
            }
            state.toggleItalic = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleFontTrait(.traitItalic, in: tv)
            }
            state.toggleInlineCode = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleInlineCode(in: tv)
            }
            state.toggleUnderline = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleSimpleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: tv)
            }
            state.toggleStrikethrough = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleSimpleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, in: tv)
            }
            state.toggleBulletList = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.toggleKind(.bullet), in: tv)
            }
            state.toggleNumberedList = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.toggleKind(.numbered), in: tv)
            }
            state.indent = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.indent, in: tv)
            }
            state.outdent = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.outdent, in: tv)
            }
            state.insertLink = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.beginLinkEntry(in: tv)
            }
            state.undo = { [weak self] in
                guard let self, let tv = self.textView else { return }
                tv.undoManager?.undo()
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
            state.redo = { [weak self] in
                guard let self, let tv = self.textView else { return }
                tv.undoManager?.redo()
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
        }

        // MARK: Undo registration (step 7)

        /// Registers an undo step that restores the textView to its current state.
        /// Call this BEFORE applying a custom mutation (formatting toggle, list mutation,
        /// link insertion). NSUndoManager handles redo automatically by re-registering
        /// the inverse when this closure runs during an undo operation.
        ///
        /// UITextView's built-in typing undo is independent of this and works out of the box;
        /// this helper covers our `attributedText`-assignment mutations which bypass it.
        private func captureUndoSnapshot(in textView: UITextView) {
            let before = (textView.attributedText.copy() as? NSAttributedString) ?? NSAttributedString()
            let beforeSel = textView.selectedRange
            textView.undoManager?.registerUndo(withTarget: textView) { [weak self] tv in
                guard let self else { return }
                self.captureUndoSnapshot(in: tv)  // chain for redo
                tv.attributedText = before
                let clamped = min(beforeSel.location, before.length)
                tv.selectedRange = NSRange(location: clamped, length: 0)
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
        }

        /// Encodes the textView's attributed string to markdown and pushes it through the
        /// binding. Use this instead of `parent.text = textView.text` to keep the binding
        /// authoritative as markdown rather than raw display text.
        private func pushBinding(from textView: UITextView) {
            parent.text = MarkdownCodec.encode(textView.attributedText ?? NSAttributedString())
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            pushBinding(from: textView)
            refreshActiveState(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshActiveState(in: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            refreshActiveState(in: textView)
            parent.onBeginEditing?()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEndEditing?()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                return !handleReturnKey(in: textView, range: range)
            }
            return true
        }

        // MARK: Active-state derivation

        /// Reads `typingAttributes` (UITextView keeps these in sync with the cursor /
        /// start of the current selection) to populate the toolbar's active-state flags.
        /// List state is derived from the current paragraph's prefix in the raw text.
        private func refreshActiveState(in textView: UITextView) {
            let typing = textView.typingAttributes
            let font = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let traits = font.fontDescriptor.symbolicTraits
            state.isBold = traits.contains(.traitBold)
            state.isItalic = traits.contains(.traitItalic)
            // Inline-code state is tracked via custom marker because `.traitMonoSpace`
            // doesn't always round-trip cleanly through `withSymbolicTraits` on monospaced
            // system fonts; the marker is the source of truth.
            state.isInlineCode = (typing[.airpadInlineCode] as? Bool) == true
                || traits.contains(.traitMonoSpace)
            state.isUnderline = (typing[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            state.isStrikethrough = (typing[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false

            // List detection: parse the paragraph containing the cursor.
            let info = currentParagraphInfo(in: textView)
            switch info.kind {
            case .bullet:
                state.isBulletList = true
                state.isNumberedList = false
            case .numbered:
                state.isBulletList = false
                state.isNumberedList = true
            case nil:
                state.isBulletList = false
                state.isNumberedList = false
            }

            // Undo / redo availability — bridged from UITextView's undoManager,
            // which covers built-in typing and our explicit captureUndoSnapshot calls.
            state.canUndo = textView.undoManager?.canUndo ?? false
            state.canRedo = textView.undoManager?.canRedo ?? false

            // typingAttributes inherit from the preceding char. If that char is a `•`
            // carrying `.airpadBulletGlyph`, freshly typed content would silently inherit
            // the marker — which the encoder would later rewrite to `-`. Strip it so the
            // marker stays scoped to the actual bullet glyph chars.
            if textView.typingAttributes[.airpadBulletGlyph] != nil {
                var typing = textView.typingAttributes
                typing.removeValue(forKey: .airpadBulletGlyph)
                textView.typingAttributes = typing
            }
        }

        // MARK: List parsing (step 5)

        fileprivate enum ListKind: Equatable {
            case bullet
            case numbered(Int)

            var isNumbered: Bool {
                if case .numbered = self { return true }
                return false
            }
        }

        fileprivate struct LineInfo {
            let indent: Int        // count of leading "  " groups (0 = top level)
            let kind: ListKind?    // nil = not a list line
            let prefixLength: Int  // total chars consumed by indent + marker (0 if no marker)
        }

        /// Parses a single line (without its trailing newline) for indent + list marker.
        fileprivate static func parseLine(_ line: String) -> LineInfo {
            var work = Substring(line)
            var indent = 0
            while work.hasPrefix("  "), indent < 5 {
                work = work.dropFirst(2)
                indent += 1
            }
            let indentChars = indent * 2

            // `▪\u{FE0E} ` is 3 UTF-16 code units (glyph + VS + space); the other
            // bullet forms are 2. Check the VS-bearing form first so it doesn't get
            // shadowed by a more-permissive prefix.
            if work.hasPrefix("▪\u{FE0E} ") {
                return LineInfo(indent: indent, kind: .bullet, prefixLength: indentChars + 3)
            }
            if work.hasPrefix("- ")
                || work.hasPrefix("• ")
                || work.hasPrefix("◦ ")
                || work.hasPrefix("▪ ")
            {
                return LineInfo(indent: indent, kind: .bullet, prefixLength: indentChars + 2)
            }

            // Numbered: digits + ". " + space
            var digitCount = 0
            var iter = work.startIndex
            while iter < work.endIndex, work[iter].isASCII, work[iter].isNumber, digitCount < 6 {
                digitCount += 1
                iter = work.index(after: iter)
            }
            if digitCount > 0, iter < work.endIndex, work[iter] == "." {
                let afterDot = work.index(after: iter)
                if afterDot < work.endIndex, work[afterDot] == " " {
                    if let n = Int(work.prefix(digitCount)) {
                        return LineInfo(indent: indent, kind: .numbered(n), prefixLength: indentChars + digitCount + 2)
                    }
                }
            }

            return LineInfo(indent: indent, kind: nil, prefixLength: 0)
        }

        private func currentParagraphInfo(in textView: UITextView) -> LineInfo {
            let text = textView.text ?? ""
            let nsText = text as NSString
            let cursorRange = NSRange(location: min(textView.selectedRange.location, nsText.length), length: 0)
            let pRange = nsText.paragraphRange(for: cursorRange)
            // Strip trailing newline if present (paragraphRange includes the \n)
            var line = nsText.substring(with: pRange)
            if line.hasSuffix("\n") { line.removeLast() }
            return Self.parseLine(line)
        }

        // MARK: List mutation (step 5)

        fileprivate enum ListMutationMode {
            case toggleKind(TargetKind)  // toggle bullet/numbered on/off
            case indent
            case outdent

            enum TargetKind { case bullet, numbered }
        }

        /// Single entry point for list-affecting toolbar commands. Mutates every paragraph
        /// in the expanded selection range, runs a renumbering pass over the full document,
        /// and writes the result back to the text view (preserving selection where possible).
        fileprivate func applyListMutation(_ mode: ListMutationMode, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let attrText = textView.attributedText ?? NSAttributedString()
            let text = textView.text ?? ""
            let nsText = text as NSString
            let selRange = textView.selectedRange
            guard nsText.length >= 0 else { return }
            let workingRange = nsText.paragraphRange(for: selRange)

            // Gather paragraphs (range without trailing newline, line text, parsed info).
            var paragraphs: [(range: NSRange, line: String, info: LineInfo)] = []
            nsText.enumerateSubstrings(in: workingRange, options: .byParagraphs) { substring, substringRange, _, _ in
                let line = substring ?? ""
                paragraphs.append((substringRange, line, Self.parseLine(line)))
            }
            // Empty workingRange — cursor sits on a trailing empty line (or the whole
            // document is empty). `enumerateSubstrings` emits nothing in that case, so
            // synthesize a zero-length paragraph so the mutation still inserts the prefix
            // at the cursor location.
            if paragraphs.isEmpty {
                let emptyInfo = LineInfo(indent: 0, kind: nil, prefixLength: 0)
                paragraphs.append((NSRange(location: workingRange.location, length: 0), "", emptyInfo))
            }

            // Decide direction for toggleKind: if every paragraph already matches the target
            // kind, the toggle removes; else it applies.
            let removeAll: Bool = {
                if case .toggleKind(let target) = mode {
                    return paragraphs.allSatisfy { p in
                        switch (target, p.info.kind) {
                        case (.bullet, .bullet): return true
                        case (.numbered, .numbered(_)): return true
                        default: return false
                        }
                    }
                }
                return false
            }()

            // Build new mutable text. Process paragraphs in order; track offset delta so
            // we can re-anchor the cursor afterwards.
            let mutable = NSMutableAttributedString(attributedString: attrText)
            var runningDelta = 0

            for paragraph in paragraphs {
                let shifted = NSRange(location: paragraph.range.location + runningDelta, length: paragraph.range.length)
                let info = paragraph.info

                // Compute new prefix
                let (newIndent, newKind): (Int, ListKind?) = {
                    switch mode {
                    case .toggleKind(let target):
                        if removeAll {
                            return (0, nil)
                        }
                        // Apply target kind at existing indent (or 0 if not a list yet).
                        let baseIndent = info.indent
                        switch target {
                        case .bullet: return (baseIndent, .bullet)
                        case .numbered: return (baseIndent, .numbered(1))
                        }
                    case .indent:
                        guard info.kind != nil else { return (info.indent, info.kind) }  // only indent list items
                        return (min(info.indent + 1, 5), info.kind)
                    case .outdent:
                        guard info.kind != nil else { return (info.indent, info.kind) }
                        if info.indent == 0 {
                            return (0, nil)  // exit list at top
                        }
                        return (info.indent - 1, info.kind)
                    }
                }()

                let newPrefix: String
                switch newKind {
                case .bullet:
                    // Display-form bullet glyph. The `airpadBulletGlyph` marker is added
                    // below so the markdown encoder substitutes it back to `-` for storage.
                    let glyph = MarkdownCodec.bulletGlyph(forIndent: newIndent)
                    newPrefix = String(repeating: "  ", count: newIndent) + glyph + " "
                case .numbered:
                    // Placeholder "1." — the renumbering pass fixes the actual number afterward.
                    newPrefix = String(repeating: "  ", count: newIndent) + "1. "
                case nil:
                    newPrefix = ""
                }

                // Replace old prefix with new prefix on this paragraph.
                let oldPrefixRange = NSRange(location: shifted.location, length: info.prefixLength)
                mutable.replaceCharacters(in: oldPrefixRange, with: newPrefix)

                // `replaceCharacters(in:with: String)` inherits attributes from the surrounding
                // text, which can carry a stale bullet marker onto the new prefix. Scrub the
                // whole new-prefix range first, then tag only the `•` glyph (if present).
                let newPrefixLength = (newPrefix as NSString).length
                let newPrefixRange = NSRange(location: shifted.location, length: newPrefixLength)
                if newPrefixLength > 0 {
                    mutable.removeAttribute(.airpadBulletGlyph, range: newPrefixRange)
                }
                if case .bullet = newKind {
                    let glyphLen = MarkdownCodec.bulletGlyphUTF16Length(forIndent: newIndent)
                    let bulletLocation = shifted.location + newIndent * 2
                    let bulletRange = NSRange(location: bulletLocation, length: glyphLen)
                    if bulletRange.upperBound <= mutable.length {
                        mutable.addAttribute(.airpadBulletGlyph, value: true, range: bulletRange)
                    }
                }

                runningDelta += newPrefixLength - info.prefixLength
            }

            // Run the document-wide renumbering pass so numbered blocks are 1, 2, 3...
            let renumberedDelta = renumberLists(in: mutable)

            textView.attributedText = mutable
            // Re-anchor cursor: original location + delta from list mutation +
            // delta contributed by renumbering that occurred at or before the cursor.
            let newLength = mutable.length
            let proposedLocation = selRange.location + runningDelta + renumberedDelta.deltaBeforeOrAt(selRange.location + runningDelta)
            let clampedLocation = max(0, min(proposedLocation, newLength))
            textView.selectedRange = NSRange(location: clampedLocation, length: 0)

            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        /// Walks the whole document, finds contiguous numbered list paragraphs at the same
        /// indent level, and rewrites their numeric prefix to 1, 2, 3, ... A counter is
        /// kept per indent level and reset when the contiguous run breaks (non-numbered
        /// paragraph at that level encountered).
        ///
        /// Returns a `DeltaMap` recording offset shifts so callers can re-anchor selection.
        @discardableResult
        private func renumberLists(in attrString: NSMutableAttributedString) -> DeltaMap {
            let nsText = attrString.string as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            // Collect paragraph metadata in document order.
            struct ParaMeta {
                let range: NSRange
                let info: LineInfo
            }
            var paragraphs: [ParaMeta] = []
            nsText.enumerateSubstrings(in: fullRange, options: .byParagraphs) { substring, substringRange, _, _ in
                let line = substring ?? ""
                paragraphs.append(ParaMeta(range: substringRange, info: Self.parseLine(line)))
            }

            // Walk, computing the desired prefix for numbered lines. Track counter per indent.
            var counter: [Int: Int] = [:]
            var lastWasNumberedAtIndent: [Int: Bool] = [:]

            var mutations: [(range: NSRange, newPrefix: String, oldPrefixLength: Int)] = []

            for p in paragraphs {
                switch p.info.kind {
                case .numbered(_):
                    let indent = p.info.indent
                    if !(lastWasNumberedAtIndent[indent] ?? false) {
                        counter[indent] = 1
                    }
                    let n = counter[indent] ?? 1
                    let newPrefix = "\(String(repeating: "  ", count: indent))\(n). "
                    let prefixRange = NSRange(location: p.range.location, length: p.info.prefixLength)
                    mutations.append((prefixRange, newPrefix, p.info.prefixLength))
                    counter[indent] = n + 1
                    lastWasNumberedAtIndent[indent] = true
                    // Numbered runs at deeper indents are interrupted by a parent line.
                    for key in lastWasNumberedAtIndent.keys where key > indent {
                        lastWasNumberedAtIndent[key] = false
                    }
                default:
                    // Non-list (or bullet) line breaks the numbered streak at every indent
                    // level shallower than or equal to this paragraph's indent.
                    for key in lastWasNumberedAtIndent.keys where key >= p.info.indent {
                        lastWasNumberedAtIndent[key] = false
                    }
                }
            }

            // Apply mutations from end to start so earlier ranges aren't invalidated.
            var deltaMap = DeltaMap()
            for m in mutations.reversed() {
                let oldLength = m.range.length
                let newLength = (m.newPrefix as NSString).length
                attrString.replaceCharacters(in: m.range, with: m.newPrefix)
                let delta = newLength - oldLength
                if delta != 0 {
                    deltaMap.add(at: m.range.location, delta: delta)
                }
            }
            return deltaMap
        }

        /// Sparse map of offset deltas: for a location, sum all deltas applied at or
        /// before that location (so callers can re-anchor a cursor that lived past
        /// some renumbered prefixes).
        private struct DeltaMap {
            private var entries: [(location: Int, delta: Int)] = []
            mutating func add(at location: Int, delta: Int) {
                entries.append((location, delta))
            }
            func deltaBeforeOrAt(_ location: Int) -> Int {
                entries.reduce(0) { acc, entry in
                    entry.location <= location ? acc + entry.delta : acc
                }
            }
        }

        // MARK: Return-key list continuation (step 5)

        /// Called from `textView(_:shouldChangeTextIn:replacementText:)`. If the user is
        /// pressing Return inside a list line, continue the list on the new line (Notes
        /// behavior). If the current line is an empty list item (just the marker), Return
        /// exits the list instead.
        ///
        /// Returns true if the change was handled here and the default insertion should be
        /// suppressed; returns false to let UITextView handle the change normally.
        fileprivate func handleReturnKey(in textView: UITextView, range: NSRange) -> Bool {
            let text = textView.text ?? ""
            let nsText = text as NSString
            let cursorParagraph = nsText.paragraphRange(for: NSRange(location: range.location, length: 0))
            var line = nsText.substring(with: cursorParagraph)
            if line.hasSuffix("\n") { line.removeLast() }
            let info = Self.parseLine(line)
            guard info.kind != nil else { return false }

            // Use UTF-16 length for parity with `info.prefixLength`. `Character.count`
            // groups `▪\u{FE0E}` as one grapheme; UTF-16 length is the right unit here.
            let isEmptyListLine = ((line as NSString).length == info.prefixLength)
            if isEmptyListLine {
                captureUndoSnapshot(in: textView)
                // Empty list item + Enter → strip the prefix, exit the list, no new line.
                let prefixRange = NSRange(location: cursorParagraph.location, length: info.prefixLength)
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
                mutable.deleteCharacters(in: prefixRange)
                renumberLists(in: mutable)
                textView.attributedText = mutable
                let newLoc = max(0, cursorParagraph.location)
                textView.selectedRange = NSRange(location: newLoc, length: 0)
                refreshActiveState(in: textView)
                pushBinding(from: textView)
                return true
            }

            captureUndoSnapshot(in: textView)
            // Otherwise: insert \n + same-indent marker (number gets renumbered after).
            let indentStr = String(repeating: "  ", count: info.indent)
            let isBulletContinuation: Bool
            let markerStr: String
            switch info.kind! {
            case .bullet:
                markerStr = MarkdownCodec.bulletGlyph(forIndent: info.indent) + " "
                isBulletContinuation = true
            case .numbered:
                markerStr = "1. "  // renumber pass corrects
                isBulletContinuation = false
            }
            let insertion = "\n" + indentStr + markerStr

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            mutable.replaceCharacters(in: range, with: insertion)

            // Scrub any stale bullet marker inherited from surrounding text, then tag the
            // `•` glyph (if this is a bullet continuation) so the encoder maps it to `-`.
            let insertedLength = (insertion as NSString).length
            let insertedRange = NSRange(location: range.location, length: insertedLength)
            if insertedLength > 0 {
                mutable.removeAttribute(.airpadBulletGlyph, range: insertedRange)
            }
            if isBulletContinuation {
                let glyphLen = MarkdownCodec.bulletGlyphUTF16Length(forIndent: info.indent)
                let bulletLocation = range.location + 1 + info.indent * 2  // \n + indent
                let bulletRange = NSRange(location: bulletLocation, length: glyphLen)
                if bulletRange.upperBound <= mutable.length {
                    mutable.addAttribute(.airpadBulletGlyph, value: true, range: bulletRange)
                }
            }

            renumberLists(in: mutable)
            textView.attributedText = mutable
            let newCursor = range.location + (insertion as NSString).length
            textView.selectedRange = NSRange(location: min(newCursor, mutable.length), length: 0)
            refreshActiveState(in: textView)
            pushBinding(from: textView)
            return true
        }

        // MARK: Link entry (step 6)

        /// Presents a `UIAlertController` for link entry — pragmatic Notes-shaped UX.
        /// Putting an editable field inside `inputAccessoryView` would steal first-responder
        /// and dismiss the keyboard mid-entry; the alert keeps things clean and we restore
        /// the textView's first-responder afterwards so editing continues seamlessly.
        ///
        /// - If a selection exists, only the URL field is shown; the selection becomes link text.
        /// - If no selection, both Title and URL fields are shown; the title text is inserted.
        fileprivate func beginLinkEntry(in textView: UITextView) {
            let range = textView.selectedRange
            let nsText = (textView.text ?? "") as NSString
            let hasSelection = (range.length > 0)
            let selectedText: String? = hasSelection ? nsText.substring(with: range) : nil
            let savedRange = NSRange(location: range.location, length: range.length)

            let alert = UIAlertController(title: "Add Link", message: nil, preferredStyle: .alert)
            if !hasSelection {
                alert.addTextField { tf in
                    tf.placeholder = "Title"
                    tf.autocapitalizationType = .sentences
                }
            }
            alert.addTextField { tf in
                tf.placeholder = "https://..."
                tf.keyboardType = .URL
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak textView] _ in
                textView?.becomeFirstResponder()
            })
            alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let title: String
                let urlString: String
                if hasSelection {
                    title = selectedText ?? ""
                    urlString = alert.textFields?.first?.text ?? ""
                } else {
                    title = alert.textFields?.first?.text ?? ""
                    urlString = alert.textFields?.last?.text ?? ""
                }
                self.commitLinkEntry(
                    savedRange: savedRange,
                    title: title,
                    urlString: urlString,
                    hasSelection: hasSelection,
                    in: textView
                )
                textView.becomeFirstResponder()
            })

            guard var presenter = textView.window?.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
        }

        private func commitLinkEntry(
            savedRange: NSRange,
            title: String,
            urlString: String,
            hasSelection: Bool,
            in textView: UITextView
        ) {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: normalized) else { return }

            captureUndoSnapshot(in: textView)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            if hasSelection {
                mutable.addAttribute(.link, value: url, range: savedRange)
                mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: savedRange)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: savedRange)
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: savedRange.location + savedRange.length, length: 0)
            } else {
                let visible = title.isEmpty ? normalized : title
                let attrs: [NSAttributedString.Key: Any] = [
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: UIFont.preferredFont(forTextStyle: .body)
                ]
                let inserted = NSAttributedString(string: visible, attributes: attrs)
                mutable.replaceCharacters(in: savedRange, with: inserted)
                textView.attributedText = mutable
                let endLoc = savedRange.location + (visible as NSString).length
                textView.selectedRange = NSRange(location: endLoc, length: 0)
            }
            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        // MARK: Inline attribute toggles (step 3)

        /// Toggles a font symbolic trait (bold / italic) across the current selection,
        /// or on `typingAttributes` when there's no selection. Notes' "if uniform, invert;
        /// else set" semantics.
        fileprivate func toggleFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()

            if range.length == 0 {
                var typing = textView.typingAttributes
                let font = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let hasTrait = font.fontDescriptor.symbolicTraits.contains(trait)
                let isCode = (typing[.airpadInlineCode] as? Bool) == true
                typing[.font] = composeFont(togglingTrait: trait, currentlyOn: hasTrait, code: isCode, base: font)
                textView.typingAttributes = typing
            } else {
                let uniformOn = isTraitUniformlyApplied(trait, in: attrText, range: range)
                let target = !uniformOn

                let mutable = NSMutableAttributedString(attributedString: attrText)
                mutable.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                    let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                    let isCode = (attrs[.airpadInlineCode] as? Bool) == true
                    let newFont = composeFont(togglingTrait: trait, currentlyOn: !target, code: isCode, base: font)
                    mutable.addAttribute(.font, value: newFont, range: subRange)
                }
                let preservedSelection = range
                textView.attributedText = mutable
                textView.selectedRange = preservedSelection

                var typing = textView.typingAttributes
                let typingFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let typingIsCode = (typing[.airpadInlineCode] as? Bool) == true
                typing[.font] = composeFont(togglingTrait: trait, currentlyOn: !target, code: typingIsCode, base: typingFont)
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            // attributedText assignment doesn't fire textViewDidChange — push the new
            // string out to the binding manually.
            pushBinding(from: textView)
        }

        /// Inline code is a font-family swap plus a marker attribute. The marker is the
        /// detection source of truth (independent of font introspection quirks); the
        /// monospaced font is for rendering.
        fileprivate func toggleInlineCode(in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()
            let markerKey = NSAttributedString.Key.airpadInlineCode

            if range.length == 0 {
                var typing = textView.typingAttributes
                let isOn = (typing[markerKey] as? Bool) == true
                let baseFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let traits = baseFont.fontDescriptor.symbolicTraits
                if isOn {
                    typing.removeValue(forKey: markerKey)
                    typing[.font] = buildBodyFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                } else {
                    typing[markerKey] = true
                    typing[.font] = buildMonoFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                }
                textView.typingAttributes = typing
            } else {
                let uniformOn = isMarkerUniformlyApplied(markerKey, in: attrText, range: range)
                let target = !uniformOn
                let mutable = NSMutableAttributedString(attributedString: attrText)
                mutable.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                    let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                    let traits = font.fontDescriptor.symbolicTraits
                    let bold = traits.contains(.traitBold)
                    let italic = traits.contains(.traitItalic)
                    if target {
                        mutable.addAttribute(markerKey, value: true, range: subRange)
                        mutable.addAttribute(.font, value: buildMonoFont(bold: bold, italic: italic), range: subRange)
                    } else {
                        mutable.removeAttribute(markerKey, range: subRange)
                        mutable.addAttribute(.font, value: buildBodyFont(bold: bold, italic: italic), range: subRange)
                    }
                }
                textView.attributedText = mutable
                textView.selectedRange = range

                var typing = textView.typingAttributes
                let typingFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let traits = typingFont.fontDescriptor.symbolicTraits
                if target {
                    typing[markerKey] = true
                    typing[.font] = buildMonoFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                } else {
                    typing.removeValue(forKey: markerKey)
                    typing[.font] = buildBodyFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                }
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        /// Toggles a simple attribute (underline / strikethrough) that doesn't require font
        /// recomposition.
        fileprivate func toggleSimpleAttribute(_ key: NSAttributedString.Key, value: Any, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()

            if range.length == 0 {
                var typing = textView.typingAttributes
                if typing[key] != nil {
                    typing.removeValue(forKey: key)
                } else {
                    typing[key] = value
                }
                textView.typingAttributes = typing
            } else {
                let uniformOn = isAttributeUniformlyApplied(key, in: attrText, range: range)
                let mutable = NSMutableAttributedString(attributedString: attrText)
                if uniformOn {
                    mutable.removeAttribute(key, range: range)
                } else {
                    mutable.addAttribute(key, value: value, range: range)
                }
                textView.attributedText = mutable
                textView.selectedRange = range

                var typing = textView.typingAttributes
                if uniformOn {
                    typing.removeValue(forKey: key)
                } else {
                    typing[key] = value
                }
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        // MARK: Uniformity checks

        private func isTraitUniformlyApplied(
            _ trait: UIFontDescriptor.SymbolicTraits,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                if !font.fontDescriptor.symbolicTraits.contains(trait) {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        private func isAttributeUniformlyApplied(
            _ key: NSAttributedString.Key,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if value == nil {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        private func isMarkerUniformlyApplied(
            _ key: NSAttributedString.Key,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if (value as? Bool) != true {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        // MARK: Font composition

        /// Returns a font that has `trait` toggled relative to `currentlyOn`, preserving
        /// the other bold/italic trait and the code/non-code family.
        private func composeFont(
            togglingTrait trait: UIFontDescriptor.SymbolicTraits,
            currentlyOn: Bool,
            code: Bool,
            base: UIFont
        ) -> UIFont {
            let traits = base.fontDescriptor.symbolicTraits
            let bold = trait == .traitBold ? !currentlyOn : traits.contains(.traitBold)
            let italic = trait == .traitItalic ? !currentlyOn : traits.contains(.traitItalic)
            return code
                ? buildMonoFont(bold: bold, italic: italic)
                : buildBodyFont(bold: bold, italic: italic)
        }

        private func buildBodyFont(bold: Bool, italic: Bool) -> UIFont {
            let body = UIFont.preferredFont(forTextStyle: .body)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            guard !traits.isEmpty else { return body }
            if let desc = body.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: desc, size: body.pointSize)
            }
            return body
        }

        private func buildMonoFont(bold: Bool, italic: Bool) -> UIFont {
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            let mono = UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic, let desc = mono.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: desc, size: size)
            }
            return mono
        }
    }
}

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Marker for inline-code spans. Detection source of truth (independent of font
    /// introspection quirks); the corresponding monospaced font is for rendering.
    static let airpadInlineCode = NSAttributedString.Key("airpadInlineCode")

    /// Marker placed on a `•` character that represents a markdown `-` bullet in storage.
    /// The textView always displays `• `; the `MarkdownCodec` strips the marker and
    /// substitutes `-` back when encoding so the on-disk JSON remains pure markdown.
    /// User-typed literal `•` chars (no marker) are preserved as-is — only marker-bearing
    /// glyphs are mapped to hyphens.
    static let airpadBulletGlyph = NSAttributedString.Key("airpadBulletGlyph")
}

// MARK: - Toolbar state

/// Observable bag of formatting state and command closures the toolbar reads and invokes.
/// The `Coordinator` owns this and rewires the closures as commands are implemented in
/// subsequent stage-2.2 steps.
@MainActor
@Observable
final class RichTextEditorState {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var isInlineCode = false
    var isBulletList = false
    var isNumberedList = false
    var canUndo = false
    var canRedo = false

    var toggleBold: () -> Void = {}
    var toggleItalic: () -> Void = {}
    var toggleUnderline: () -> Void = {}
    var toggleStrikethrough: () -> Void = {}
    var toggleInlineCode: () -> Void = {}
    var toggleBulletList: () -> Void = {}
    var toggleNumberedList: () -> Void = {}
    var indent: () -> Void = {}
    var outdent: () -> Void = {}
    var insertLink: () -> Void = {}
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var dismissKeyboard: () -> Void = {}
}

// MARK: - Toolbar view

/// Keyboard-attached formatting toolbar. Hosted via `UIHostingController` inside the
/// `UITextView`'s `inputAccessoryView`. Buttons read active-state from `RichTextEditorState`
/// and invoke the matching command closure.
struct RichTextToolbar: View {
    @Bindable var state: RichTextEditorState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    button(icon: "bold", active: state.isBold, action: state.toggleBold)
                    button(icon: "italic", active: state.isItalic, action: state.toggleItalic)
                    button(icon: "underline", active: state.isUnderline, action: state.toggleUnderline)
                    button(icon: "strikethrough", active: state.isStrikethrough, action: state.toggleStrikethrough)
                    separator
                    button(icon: "list.bullet", active: state.isBulletList, action: state.toggleBulletList)
                    button(icon: "list.number", active: state.isNumberedList, action: state.toggleNumberedList)
                    button(icon: "decrease.indent", active: false, action: state.outdent)
                    button(icon: "increase.indent", active: false, action: state.indent)
                    separator
                    button(icon: "chevron.left.forwardslash.chevron.right", active: state.isInlineCode, action: state.toggleInlineCode)
                    button(icon: "link", active: false, action: state.insertLink)
                    separator
                    button(icon: "arrow.uturn.backward", active: false, enabled: state.canUndo, action: state.undo)
                    button(icon: "arrow.uturn.forward", active: false, enabled: state.canRedo, action: state.redo)
                }
                .padding(.horizontal, 10)
            }
            separator
            button(icon: "keyboard.chevron.compact.down", active: false, action: state.dismissKeyboard)
                .padding(.trailing, 6)
        }
        .frame(height: 48)
        .background(
            Capsule(style: .continuous).fill(Color(white: 0.12))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func button(
        icon: String,
        active: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(enabled ? (active ? Color.white : Color.white.opacity(0.75)) : Color.white.opacity(0.3))
                .background(active ? Color.white.opacity(0.18) : Color.clear)
                .clipShape(Capsule(style: .continuous))
        }
        .disabled(!enabled)
    }
}

/// `UITextView` subclass providing:
/// - placeholder rendering via an overlay `UILabel` that hides when text is non-empty,
/// - `intrinsicContentSize` and a `minHeight` floor so SwiftUI sizing can drive inline growth.
///
/// Subclassing rather than composing because we need to observe `text` / `attributedText`
/// changes and update the placeholder visibility from a single source of truth.
final class RichTextUIView: UITextView {

    private let placeholderLabel = UILabel()

    var placeholderText: String = "" {
        didSet {
            placeholderLabel.text = placeholderText
            updatePlaceholderVisibility()
        }
    }

    var minHeight: CGFloat = 44 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChangeNotification),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var text: String! {
        didSet { updatePlaceholderVisibility() }
    }

    override var attributedText: NSAttributedString! {
        didSet { updatePlaceholderVisibility() }
    }

    override var intrinsicContentSize: CGSize {
        let proposedWidth = bounds.width > 0 ? bounds.width : UIView.layoutFittingExpandedSize.width
        let fitted = sizeThatFits(CGSize(width: proposedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(fitted.height, minHeight))
    }

    private func setupPlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = font
        placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.35)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: textContainerInset.left + textContainer.lineFragmentPadding
            ),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(textContainerInset.right + textContainer.lineFragmentPadding)
            )
        ])
    }

    @objc private func textDidChangeNotification() {
        updatePlaceholderVisibility()
        invalidateIntrinsicContentSize()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.font = font
        placeholderLabel.isHidden = !(text?.isEmpty ?? true)
    }
}

// MARK: - Markdown codec

/// Lossless markdown encode/decode for the editor's attributed-text representation.
///
/// **Encode** walks every attribute run in the attributed string and emits markdown
/// markers around runs that carry our tracked attributes:
/// - `**…**` bold (font with `.traitBold`)
/// - `*…*` italic (font with `.traitItalic`)
/// - `~~…~~` strikethrough (`.strikethroughStyle`)
/// - `<u>…</u>` underline (`.underlineStyle`) — markdown has no native underline
/// - `` `…` `` inline code (`.airpadInlineCode` marker; other formats don't nest in code)
/// - `[…](url)` link (`.link` attribute)
/// - List markers (`- ` / `N. `) round-trip as literal text since the editor stores them
///   as plain characters at line start; no special handling needed.
///
/// **Decode** parses the same markers back into attributes. Special characters in literal
/// text are escaped on encode (`\*`, `` \` ``, `\~`, `\[`, `\<`, `\\`) so plain text containing
/// markdown-reserved chars round-trips correctly.
///
/// Plain text → encode → plain text is the lossless invariant: text without attributes
/// has no markers emitted, only escapes for reserved chars, which decode back to the
/// original characters.
///
/// **Bullet glyph substitution (Stage 2.2.1):** the editor displays `• ` at the start of
/// bulleted lines while the storage form stays `- `. The substitution is driven by the
/// `.airpadBulletGlyph` marker attribute placed on the `•` char: encode rewrites
/// marker-bearing `•` → `-`; decode walks paragraphs and substitutes `- ` → `• ` (adding
/// the marker) at line start, with optional leading indent. Literal `•` chars typed by
/// the user (no marker) are preserved as-is.
@MainActor
enum MarkdownCodec {

    // MARK: Bullet glyph depth cascade
    //
    // Notes-style depth cascade — `•` at level 0, `◦` at level 1, `▪` at level 2+.
    // `•` (U+2022) and `◦` (U+25E6) render as text by default. `▪` (U+25AA) has
    // emoji-presentation-default on iOS — without the U+FE0E text variation selector
    // it paints as a color emoji square rather than a plain glyph. The VS makes the
    // depth-2 glyph 2 UTF-16 code units; consumers must use `bulletGlyphUTF16Length`
    // rather than assuming 1.
    static func bulletGlyph(forIndent depth: Int) -> String {
        switch depth {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪\u{FE0E}"
        }
    }

    static func bulletGlyphUTF16Length(forIndent depth: Int) -> Int {
        return (bulletGlyph(forIndent: depth) as NSString).length
    }

    // MARK: Encoding

    private static let escapeChars: Set<Character> = ["*", "`", "~", "[", "<", "\\"]

    static func encode(_ attr: NSAttributedString) -> String {
        guard attr.length > 0 else { return "" }
        // Pre-pass: strip the display-only bullet glyph substitution so the markdown
        // we emit uses the canonical `-` storage form.
        let normalized = substituteBulletGlyphsForStorage(attr)
        var result = ""
        result.reserveCapacity(normalized.length)
        let nsString = normalized.string as NSString
        let fullRange = NSRange(location: 0, length: normalized.length)

        normalized.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let runText = nsString.substring(with: range)
            let escaped = escape(runText)

            let isCode = (attrs[.airpadInlineCode] as? Bool) == true
            let linkURL = attrs[.link] as? URL
            let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let traits = font.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic)
            let isUnderline = (attrs[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            let isStrike = (attrs[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false

            // Inline code is atomic: other inline markers don't nest inside backticks.
            // (Markdown spec: backtick spans are literal.) We still respect links since
            // a link can wrap a code span semantically. Inside the code body, escape `\`
            // first then `` ` `` so the decoder's un-escape pass round-trips correctly.
            let middle: String
            if isCode {
                var body = runText.replacingOccurrences(of: "\\", with: "\\\\")
                body = body.replacingOccurrences(of: "`", with: "\\`")
                middle = "`" + body + "`"
            } else {
                var open = ""
                var close = ""
                if isBold { open += "**"; close = "**" + close }
                if isItalic { open += "*"; close = "*" + close }
                if isUnderline { open += "<u>"; close = "</u>" + close }
                if isStrike { open += "~~"; close = "~~" + close }
                middle = open + escaped + close
            }

            if let url = linkURL {
                result += "[\(middle)](\(url.absoluteString))"
            } else {
                result += middle
            }
        }
        return result
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(where: { escapeChars.contains($0) }) else { return s }
        var out = ""
        out.reserveCapacity(s.count + 4)
        for ch in s {
            if escapeChars.contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    // MARK: Decoding

    static func decode(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var state = DecoderState()
        decode(markdown, into: result, state: &state, linkURL: nil)
        // Post-pass: apply the display-only bullet glyph substitution so the user sees
        // `• ` instead of literal `- ` at the start of bulleted lines.
        return substituteBulletGlyphsForDisplay(result)
    }

    // MARK: Bullet glyph substitution (Stage 2.2.1)

    /// Display-form: walk paragraphs and replace `- ` at paragraph start (with optional
    /// `"  "` indent groups before it) with the depth-appropriate glyph (`•` / `◦` / `▪`),
    /// marking the glyph char with `.airpadBulletGlyph` so the inverse pass can find it.
    private static func substituteBulletGlyphsForDisplay(_ attr: NSAttributedString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        let ns = mut.string as NSString
        guard ns.length > 0 else { return mut }
        // Collect hyphen ranges first along with the indent depth so we can pick the
        // matching glyph. Mutating during enumeration of the underlying string is fragile.
        var hits: [(range: NSRange, indent: Int)] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byParagraphs
        ) { sub, range, _, _ in
            guard let s = sub else { return }
            let chars = Array(s)
            var idx = 0
            while idx + 1 < chars.count, chars[idx] == " ", chars[idx + 1] == " " {
                idx += 2
            }
            if idx + 1 < chars.count, chars[idx] == "-", chars[idx + 1] == " " {
                let depth = idx / 2
                hits.append((NSRange(location: range.location + idx, length: 1), depth))
            }
        }
        // Apply from end to start so earlier ranges stay valid. Replacements at depth 2+
        // may grow the string (1 char `-` → 2 char `▪\u{FE0E}`); reverse-order iteration
        // keeps earlier hit locations correct.
        for hit in hits.reversed() {
            let glyph = bulletGlyph(forIndent: hit.indent)
            let glyphLen = (glyph as NSString).length
            mut.mutableString.replaceCharacters(in: hit.range, with: glyph)
            let glyphRange = NSRange(location: hit.range.location, length: glyphLen)
            mut.addAttribute(.airpadBulletGlyph, value: true, range: glyphRange)
        }
        return mut
    }

    /// Storage-form: find chars carrying the `.airpadBulletGlyph` marker; if they are
    /// `•` (which they should be — the marker is only ever set on `•` chars), swap
    /// back to `-` and drop the marker. Other markers and content are left intact.
    private static func substituteBulletGlyphsForStorage(_ attr: NSAttributedString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        let fullRange = NSRange(location: 0, length: mut.length)
        var hits: [NSRange] = []
        mut.enumerateAttribute(.airpadBulletGlyph, in: fullRange, options: []) { value, range, _ in
            if (value as? Bool) == true {
                hits.append(range)
            }
        }
        for range in hits.reversed() {
            let chunk = (mut.string as NSString).substring(with: range)
            // Depth 0/1: chunk is a single glyph char (`•` or `◦`).
            // Depth 2+: chunk is `▪\u{FE0E}` (2 UTF-16 units). Either way, if the leading
            // char is a known bullet glyph, replace the whole marker range with `-` so the
            // VS doesn't leak into storage.
            let first = chunk.first
            if first == "•" || first == "◦" || first == "▪" {
                mut.mutableString.replaceCharacters(in: range, with: "-")
            }
            mut.removeAttribute(.airpadBulletGlyph, range: range)
        }
        return mut
    }

    private struct DecoderState {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
    }

    private static func decode(
        _ source: String,
        into out: NSMutableAttributedString,
        state: inout DecoderState,
        linkURL: URL?
    ) {
        let scalars = Array(source)
        var i = 0
        let count = scalars.count

        while i < count {
            let ch = scalars[i]

            // Escape sequence: \<char> is literal char
            if ch == "\\", i + 1 < count {
                let next = scalars[i + 1]
                out.append(NSAttributedString(string: String(next), attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 2
                continue
            }

            // Bold: **
            if ch == "*", i + 1 < count, scalars[i + 1] == "*" {
                state.bold.toggle()
                i += 2
                continue
            }

            // Strikethrough: ~~
            if ch == "~", i + 1 < count, scalars[i + 1] == "~" {
                state.strike.toggle()
                i += 2
                continue
            }

            // Underline open/close
            if ch == "<", let close = matchTag(scalars, at: i) {
                switch close {
                case .openUnderline: state.underline = true
                case .closeUnderline: state.underline = false
                }
                i += close.length
                continue
            }

            // Italic: *
            if ch == "*" {
                state.italic.toggle()
                i += 1
                continue
            }

            // Inline code: `…`
            if ch == "`" {
                let codeStart = i + 1
                var j = codeStart
                while j < count {
                    if scalars[j] == "\\", j + 1 < count {
                        j += 2
                        continue
                    }
                    if scalars[j] == "`" { break }
                    j += 1
                }
                if j < count {
                    // Extract code body, un-escape any \` inside
                    var body = ""
                    var k = codeStart
                    while k < j {
                        if scalars[k] == "\\", k + 1 < count {
                            body.append(scalars[k + 1])
                            k += 2
                        } else {
                            body.append(scalars[k])
                            k += 1
                        }
                    }
                    out.append(NSAttributedString(string: body, attributes: currentAttrs(state: state, code: true, linkURL: linkURL)))
                    i = j + 1
                    continue
                }
                // Unmatched backtick: treat literally
                out.append(NSAttributedString(string: "`", attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 1
                continue
            }

            // Link: [text](url)
            if ch == "[" {
                if let parsed = parseLink(scalars, from: i) {
                    var innerState = state  // inherit current inline state
                    decode(parsed.text, into: out, state: &innerState, linkURL: parsed.url)
                    i = parsed.endIndex
                    continue
                }
                // Not a link; treat literal
                out.append(NSAttributedString(string: "[", attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 1
                continue
            }

            // Literal character
            out.append(NSAttributedString(string: String(ch), attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
            i += 1
        }
    }

    private enum TagMatch {
        case openUnderline
        case closeUnderline
        var length: Int {
            switch self {
            case .openUnderline: return 3
            case .closeUnderline: return 4
            }
        }
    }

    private static func matchTag(_ scalars: [Character], at i: Int) -> TagMatch? {
        let count = scalars.count
        if i + 2 < count, scalars[i] == "<", scalars[i + 1] == "u", scalars[i + 2] == ">" {
            return .openUnderline
        }
        if i + 3 < count, scalars[i] == "<", scalars[i + 1] == "/", scalars[i + 2] == "u", scalars[i + 3] == ">" {
            return .closeUnderline
        }
        return nil
    }

    private struct LinkParse {
        let text: String
        let url: URL
        let endIndex: Int  // first index after the closing `)`
    }

    private static func parseLink(_ scalars: [Character], from start: Int) -> LinkParse? {
        let count = scalars.count
        // Find matching `]` accounting for escape sequences
        var j = start + 1
        var textChars: [Character] = []
        while j < count {
            if scalars[j] == "\\", j + 1 < count {
                textChars.append(scalars[j])
                textChars.append(scalars[j + 1])
                j += 2
                continue
            }
            if scalars[j] == "]" { break }
            textChars.append(scalars[j])
            j += 1
        }
        guard j < count, scalars[j] == "]" else { return nil }
        let urlOpen = j + 1
        guard urlOpen < count, scalars[urlOpen] == "(" else { return nil }
        let urlStart = urlOpen + 1
        var k = urlStart
        while k < count, scalars[k] != ")" {
            k += 1
        }
        guard k < count, scalars[k] == ")" else { return nil }
        let urlString = String(scalars[urlStart..<k])
        guard let url = URL(string: urlString) else { return nil }
        return LinkParse(text: String(textChars), url: url, endIndex: k + 1)
    }

    private static func currentAttrs(state: DecoderState, code: Bool, linkURL: URL?) -> [NSAttributedString.Key: Any] {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let font: UIFont
        if code {
            let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: state.bold ? .bold : .regular)
            if state.italic, let desc = mono.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: desc, size: body.pointSize)
            } else {
                font = mono
            }
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if state.bold { traits.insert(.traitBold) }
            if state.italic { traits.insert(.traitItalic) }
            if !traits.isEmpty, let desc = body.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: desc, size: body.pointSize)
            } else {
                font = body
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        if state.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if state.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if code {
            attrs[.airpadInlineCode] = true
        }
        if let url = linkURL {
            attrs[.link] = url
            attrs[.foregroundColor] = UIColor.systemBlue
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }
}
