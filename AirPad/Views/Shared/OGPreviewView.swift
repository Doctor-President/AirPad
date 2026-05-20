import SwiftUI
import UIKit

// AT19.3c — single OG preview renderer shared by `LinkEntryBody` (detail
// view) and the QuikCapture receipt modal (commit 6) so both surfaces
// present identical visual treatment. State machine derives from the
// item's persisted fields alone:
//   A (empty)        — no URL → focused TextField with placeholder.
//   B (pending)      — URL set, never fetched → bare URL, no spinner.
//   C (rich)         — URL set, fetched, metadata present → card.
//   D (bareFallback) — URL set, fetched, no metadata → bare URL.
// View-internal `@State` only exists for the State A draft buffer and
// async UIImage loading in State C; business logic stays externalized.

struct OGPreviewView: View {

    let item: NodeItem
    let nodeID: String
    /// Fired when the user commits a URL in State A (TextField submit or
    /// defocus while non-empty). Caller is responsible for persisting
    /// the URL and triggering the OG fetch.
    let onCommitURL: (String) -> Void
    /// When false, omits the URL-open `onTapGesture` in states B/C/D so a
    /// parent `onTapGesture` (e.g. the QuikCapture receipt overlay)
    /// receives the tap instead of Safari being launched. State A still
    /// renders its TextField — `interactive: false` is only used in
    /// contexts where the URL is already set, so State A won't appear.
    ///
    /// Prior to 2026-05-19 the interactive path used SwiftUI `Link`. That
    /// was replaced with `Text/cardContent + .contentShape(Rectangle()) +
    /// .onTapGesture { openURL(url) }`: Link's accessibility-link trait +
    /// the detail-view ScrollView's `.dismissKeyboardOnTapOutside`
    /// contentShape were combining to promote the Link's tap region
    /// across the whole EntryCard, eating chevron/menu/long-press on
    /// every link entry. The `.isLink` accessibility trait is preserved
    /// on the new tap surface, and the open mechanism stays SwiftUI-
    /// native via `@Environment(\.openURL)` (what Link uses internally).
    var interactive: Bool = true

    @Environment(CorpusStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var draftURL: String = ""
    @FocusState private var urlFieldFocused: Bool
    @State private var ogImage: UIImage? = nil

    private enum PreviewState {
        case empty
        case pending
        case rich
        case bareFallback
    }

    // Stage 4.5 commit 5 — `linkItems[0]` wins over the legacy NodeItem-
    // level OG fields when present. This single rule keeps single-mode
    // rendering correct after a per-tile delete drops a multi-link
    // entry's count from 2 to 1: the surviving LinkItem drives the view,
    // even though the legacy fields may still hold the deleted item's
    // data. Falls back to legacy fields for QuikCapture-created entries
    // (which never write linkItems) and pre-4.5 entries that never went
    // multi-link. See `CorpusStore.removeLinkItem` for the policy.
    private var effectiveURL: String? {
        item.linkItems?.first?.url ?? item.url
    }
    private var effectiveTitle: String? {
        item.linkItems?.first?.title ?? item.ogTitle
    }
    private var effectiveDescription: String? {
        item.linkItems?.first?.description ?? item.ogDescription
    }
    private var effectiveSiteName: String? {
        item.linkItems?.first?.siteName ?? item.ogSiteName
    }
    private var effectiveImageFile: String? {
        item.linkItems?.first?.imageFile ?? item.ogImageFile
    }

    /// `LinkItem` has no per-item `ogFetchedAt`. When linkItems[0] is
    /// the source, treat the URL as having been fetched — the gallery
    /// tile's on-appear fetch (or `appendLinkItem`'s on-append fetch)
    /// already ran by the time this view is reached. Successful-but-
    /// empty OG fetches will land here as State D (bareFallback), same
    /// as the legacy path; the gallery tile handles its own re-fetch
    /// trigger via `hasAnyOG`.
    private var hasBeenFetched: Bool {
        if item.linkItems?.first != nil { return true }
        return item.ogFetchedAt != nil
    }

    private var state: PreviewState {
        guard let urlString = effectiveURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else { return .empty }
        guard hasBeenFetched else { return .pending }
        let hasMetadata = effectiveTitle?.isEmpty == false
            || effectiveDescription?.isEmpty == false
            || effectiveSiteName?.isEmpty == false
            || effectiveImageFile?.isEmpty == false
        return hasMetadata ? .rich : .bareFallback
    }

    var body: some View {
        switch state {
        case .empty:        emptyStateBody
        case .pending:      bareURLBody     // visually identical to D in commit 3
        case .rich:         richStateBody
        case .bareFallback: bareURLBody
        }
    }

    // MARK: - State A — empty

    private var emptyStateBody: some View {
        TextField("Paste or type a URL", text: $draftURL)
            .focused($urlFieldFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.caption)
            .foregroundStyle(.blue)
            .submitLabel(.done)
            .onSubmit { commitDraftIfPresent() }
            .onChange(of: urlFieldFocused) { _, isFocused in
                if !isFocused { commitDraftIfPresent() }
            }
            .onAppear {
                // Brief delay lets the entry animation settle before the
                // keyboard rises; otherwise the entry card jumps under it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    urlFieldFocused = true
                }
            }
    }

    private func commitDraftIfPresent() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = normalizeURL(trimmed)
        onCommitURL(normalized)
        draftURL = ""
    }

    /// Adds `https://` when the user typed a bare host like `apple.com`.
    /// Mirrors what Safari's URL bar does — never surprises the user with
    /// a "not a URL" error for input that's obviously meant to be a URL.
    private func normalizeURL(_ input: String) -> String {
        if input.lowercased().hasPrefix("http://") { return input }
        if input.lowercased().hasPrefix("https://") { return input }
        return "https://\(input)"
    }

    // MARK: - States B & D — bare URL

    private var bareURLBody: some View {
        Group {
            if let urlString = effectiveURL, let url = URL(string: urlString) {
                if interactive {
                    Text(urlString)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture { openURL(url) }
                        .accessibilityAddTraits(.isLink)
                } else {
                    Text(urlString)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - State C — rich preview

    private var richStateBody: some View {
        Group {
            if interactive, let urlString = effectiveURL, let url = URL(string: urlString) {
                cardContent
                    .contentShape(Rectangle())
                    .onTapGesture { openURL(url) }
                    .accessibilityAddTraits(.isLink)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        let imagePresent = effectiveImageFile != nil
        return VStack(alignment: .leading, spacing: 0) {
            if imagePresent {
                imageBlock
            }
            VStack(alignment: .leading, spacing: 4) {
                if let title = effectiveTitle, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let description = effectiveDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if let siteName = effectiveSiteName, !siteName.isEmpty {
                    Text(siteName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(imagePresent ? 10 : 0)
        }
        .background(imagePresent ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var imageBlock: some View {
        Group {
            if let img = ogImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 160)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    )
            }
        }
        .task(id: effectiveImageFile) {
            ogImage = nil
            guard let url = await store.effectiveOGImageURL(for: item, nodeID: nodeID) else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                ogImage = img
            }
        }
    }
}
