import SwiftUI
import GameController

/// Mac batch C3 — the note editor being typed in, for the inline formatting bar and the Format menu. On a Mac (no
/// software keyboard) and on an iPad with a hardware keyboard, the formatting bar can't ride on the keyboard, so it
/// shows inline (ContentView) and acts on this editor. iPhone keeps the keyboard bar and never registers here.
@MainActor
@Observable
final class ActiveRichTextEditor {
    static let shared = ActiveRichTextEditor()

    /// The focused editor's command / state bag, nil when no note editor has focus (or on iPhone).
    private(set) var state: RichTextEditorState?

    /// A Mac, or an iPad with a hardware keyboard attached.
    static var usesInlineBar: Bool {
        if RunningOnMac.isMac { return true }
        return UIDevice.current.userInterfaceIdiom == .pad && GCKeyboard.coalesced != nil
    }

    func begin(_ s: RichTextEditorState) { state = s }

    /// Focus left the editor. Held a moment: clicking a bar button can take focus first, and the command must still
    /// reach the editor; it's cleared only if the editor didn't take focus back.
    func end(_ s: RichTextEditorState, textView: UITextView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak textView] in
            guard let self, self.state === s, textView?.isFirstResponder != true else { return }
            self.state = nil
        }
    }
}

/// Mac batch C3 — the formatting bar, inline: the text attributes the iPhone keeps behind `Aa` sit directly on it
/// (there's room on a Mac / iPad), then lists, indent, link, image and table. Same capsule material as the keyboard bar.
struct RichTextInlineBar: View {
    @Bindable var state: RichTextEditorState

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Title") { state.applyHeading(.title) }
                Button("Heading") { state.applyHeading(.heading) }
                Button("Subheading") { state.applyHeading(.subheading) }
                Button("Body") { state.applyHeading(nil) }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("inlineBar.style")
            separator
            button("bold", state.isBold, state.toggleBold, "bold")
            button("italic", state.isItalic, state.toggleItalic, "italic")
            button("underline", state.isUnderline, state.toggleUnderline, "underline")
            button("strikethrough", state.isStrikethrough, state.toggleStrikethrough, "strikethrough")
            separator
            button("list.bullet", state.isBulletList, state.toggleBulletList, "bullets")
            button("list.number", state.isNumberedList, state.toggleNumberedList, "numbers")
            button("checklist", state.isChecklist, state.toggleChecklist, "checklist")
            button("increase.indent", false, state.indent, "indent")
            button("decrease.indent", false, state.outdent, "outdent")
            separator
            button("link", false, state.insertLink, "link")
            if state.supportsInlineImage {
                button("photo", false, state.insertImage, "image")
                button("tablecells", false, state.insertTable, "table")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(NoteEditorChrome.hairline, lineWidth: 1))
        .shadow(color: NoteEditorChrome.shadow, radius: 6, x: 0, y: 1.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inlineFormatBar")
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func button(_ icon: String, _ active: Bool, _ action: @escaping () -> Void, _ id: String) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityIdentifier("inlineBar.\(id)")
    }
}
