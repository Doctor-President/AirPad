import UIKit

#if DEBUG
/// live-26 (3) — a note whose first paragraph is shown as its title ("+" Capture, the entry view) stores that line as
/// PLAIN text: the title's bold is display only. Before, the title face (bold) went through `MarkdownCodec.encode` like
/// any bold run, so every new note's first line was stored as `**…**` (live-25 (2)'s layer (a)). Through the REAL editor
/// passes (`NoteTypography.applyInPlace` + `styleFirstParagraphAsEntryTitle` + `MarkdownCodec.encode`) on a UITextView:
/// a new note's first line stores plain and still LOOKS the title; bold the user chose (a format-bar bold, a note stored
/// with `**…**` before) stays exactly as stored; Markdown typed by hand stays literal (escaped).
/// `-NoteTitleStorageSelfTest`.
enum NoteTitleStorageSelfTest {
    @MainActor static func run() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func restyle(_ tv: UITextView, _ font: NoteFontChoice) {
            NoteTypography.applyInPlace(to: tv, font: font)
            NoteTypography.styleFirstParagraphAsEntryTitle(tv, font: font)
        }
        func editor(_ markdown: String, _ font: NoteFontChoice) -> UITextView {
            let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            tv.font = NoteTypographyHelper.bodyFont   // the editor's typing font (an empty note)
            tv.attributedText = MarkdownCodec.decode(markdown)
            restyle(tv, font)
            return tv
        }
        func stored(_ tv: UITextView) -> String { MarkdownCodec.encode(tv.attributedText ?? NSAttributedString()) }
        func looksLikeTitle(_ tv: UITextView, at i: Int) -> Bool {
            guard let f = tv.attributedText.attribute(.font, at: i, effectiveRange: nil) as? UIFont else { return false }
            return NoteTypography.isEntryTitleTypingFont(f) && f.airpadWeightValue >= UIFont.Weight.bold.rawValue - 0.01
        }
        func isBodyWeight(_ tv: UITextView, at i: Int) -> Bool {
            guard let f = tv.attributedText.attribute(.font, at: i, effectiveRange: nil) as? UIFont else { return false }
            return !NoteTypography.isEntryTitleTypingFont(f) && f.airpadWeightValue < UIFont.Weight.bold.rawValue - 0.01
        }

        for font in [NoteFontChoice.system, .sourceSerif4] {
            let tag = "\(font)"
            // A new note: typed, restyled (the title face lands), then typed on inside the title line.
            let tv = editor("", font)
            tv.selectedRange = NSRange(location: 0, length: 0)
            tv.insertText("Ask the harbour office about the mooring.\nBring the forms.")
            tv.selectedRange = NSRange(location: 41, length: 0)
            restyle(tv, font)
            tv.insertText(" Today")
            restyle(tv, font)
            let s = stored(tv)
            row("new-note-first-line-stored-plain (\(tag))", s == "Ask the harbour office about the mooring. Today\nBring the forms.", s)
            row("first-line-still-looks-like-the-title (\(tag))", looksLikeTitle(tv, at: 0) && looksLikeTitle(tv, at: 45))
            row("second-line-is-body (\(tag))", isBodyWeight(tv, at: (tv.text as NSString).length - 3))

            // Return inside the title line: the tail is a body line, plain and not bold.
            let split = editor("Harbour office mooring", font)
            split.selectedRange = NSRange(location: 15, length: 0)
            split.insertText("\n")
            restyle(split, font)
            let ss = stored(split)
            row("return-inside-the-title-leaves-a-plain-body-line (\(tag))",
                ss == "Harbour office \nmooring" && looksLikeTitle(split, at: 0) && isBodyWeight(split, at: (split.text as NSString).length - 2), ss)

            // The caret moved (UIKit resets the typing attributes from the text, dropping the editor's own keys), then
            // more typing in the title line and in the body: still stored plain.
            let moved = editor("Harbour office\nBring forms", font)
            moved.selectedRange = NSRange(location: 7, length: 0)
            moved.insertText(" east")
            restyle(moved, font)
            moved.selectedRange = NSRange(location: (moved.text as NSString).length, length: 0)
            moved.insertText(" today")
            restyle(moved, font)
            row("typing-after-the-caret-moved-stores-plain (\(tag))", stored(moved) == "Harbour east office\nBring forms today",
                stored(moved))

            // Bold the user chose stays: a format-bar bold in the body; a note stored with `**…**` before (never rewritten).
            let userBold = "Ask the harbour office\nBring the **forms**."
            row("user-bold-in-the-body-kept (\(tag))", stored(editor(userBold, font)) == userBold, stored(editor(userBold, font)))
            let legacy = "**Old title stored bold**\nbody line"
            row("a-note-stored-with-a-bold-first-line-is-never-rewritten (\(tag))", stored(editor(legacy, font)) == legacy,
                stored(editor(legacy, font)))
            let legacyEdited = editor(legacy, font)
            legacyEdited.selectedRange = NSRange(location: (legacyEdited.text as NSString).length, length: 0)
            legacyEdited.insertText(" more")
            restyle(legacyEdited, font)
            row("editing-elsewhere-in-an-old-note-keeps-its-bold-first-line (\(tag))",
                stored(legacyEdited) == "**Old title stored bold**\nbody line more", stored(legacyEdited))
            // Markdown typed by hand is literal text, stored escaped (never turned into formatting).
            let typed = #"Use \*\*stars\*\* here"# + "\nbody"
            row("markdown-typed-by-hand-stays-literal (\(tag))", stored(editor(typed, font)) == typed, stored(editor(typed, font)))
        }
        // live-26 (3b) — what the REAL encoder stores for a checklist and an underline reads clean on a card.
        let list = editor("Packing\n- [ ] Print the reef map\n- [x] Book the cottage", .system)
        let storedList = stored(list)
        let cardRows = CardContentSummary.listRows(storedList)
        row("editor-stored-checklist-reads-as-checkboxes-on-a-card", cardRows.map(\.marker) == [.check(false), .check(true)]
            && cardRows.map(\.text) == ["Print the reef map", "Book the cottage"], "stored \(storedList.debugDescription) → \(cardRows.map(\.text))")
        let u = NSMutableAttributedString(string: "Harbour office", attributes: [.font: NoteTypographyHelper.bodyFont])
        u.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 7))
        let storedU = MarkdownCodec.encode(u)
        row("editor-stored-underline-is-html-and-never-shows-in-a-label", storedU.contains("<u>") && MarkdownPlain.text(storedU) == "Harbour office",
            "stored \(storedU) → \(MarkdownPlain.text(storedU))")
        return "[NoteTitleStorageSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}
#endif
