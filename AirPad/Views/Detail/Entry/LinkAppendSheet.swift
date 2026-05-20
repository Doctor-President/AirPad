import SwiftUI

/// Stage 4.5 commit 2 — modal sheet for appending a URL to a `.link`
/// entry. Ships as a standalone primitive in commit 2; the "+" chrome
/// trigger lands in commit 3 alongside `LinkGalleryBody` and the chrome
/// row on `LinkEntryBody`. No in-app view presents this sheet until
/// commit 3 wires it. A new lightweight component rather than a reuse
/// of `OGPreviewView` State A because the contexts diverge:
///   - State A is in-line on a fresh empty entry, focuses the keyboard,
///     and commits on focus loss; it lives inside the EntryCard body.
///   - This sheet is a modal layer over an entry that already has at
///     least one URL committed; it has explicit Done/Cancel buttons, no
///     focus-loss commit, and dismisses by user action.
///
/// Normalization mirrors `OGPreviewView`'s `normalizeURL` (adds
/// `https://` for bare hosts) so the visible field behavior matches.
///
/// The sheet is content-only: it captures the URL string and fires
/// `onCommit(url)`. The caller (`LinkEntryBody`) is responsible for
/// invoking `appendLinkItem` and the async OG fetch chain. This keeps
/// the sheet a pure UI primitive — no store dependency, no fetch
/// lifecycle inside the view.
struct LinkAppendSheet: View {

    /// Fired when the user taps Done with a non-empty URL. The string
    /// passed in is already normalized (https:// prefix added for bare
    /// hosts, leading/trailing whitespace stripped).
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftURL: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Paste or type a URL", text: $draftURL)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit(commitIfPresent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Spacer()
            }
            .navigationTitle("Add link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: commitIfPresent)
                        .disabled(trimmedDraft.isEmpty)
                }
            }
            .onAppear {
                // Brief delay lets the sheet present animation settle
                // before the keyboard rises; otherwise the sheet jumps
                // visibly under the keyboard. Mirrors `OGPreviewView`'s
                // State A focus timing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    fieldFocused = true
                }
            }
        }
    }

    private var trimmedDraft: String {
        draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitIfPresent() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        onCommit(normalizeURL(trimmed))
        dismiss()
    }

    /// Mirror of `OGPreviewView.normalizeURL`. Adds `https://` when the
    /// user typed a bare host like `apple.com` so Safari's URL bar
    /// behavior is preserved. Duplicated rather than extracted because
    /// the OG view is a small component and pulling the helper out
    /// would force a third file; revisit if a third call site appears.
    private func normalizeURL(_ input: String) -> String {
        if input.lowercased().hasPrefix("http://") { return input }
        if input.lowercased().hasPrefix("https://") { return input }
        return "https://\(input)"
    }
}
