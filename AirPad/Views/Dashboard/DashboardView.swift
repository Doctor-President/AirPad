import SwiftUI

/// Dashboard C1 — app root.
///
/// Layout (top → bottom):
///   1. Header — AirPad wordmark centered, right-aligned Inbox + Recents +
///      Settings icons. Inbox badge stub = 0 (hidden when zero).
///   2. Today section — `TodayCardView`.
///   3. Collections section — Corpus row pinned first (visually distinct:
///      larger text, more vertical padding), then user rows (name dominant,
///      with node count + last-entry timestamp).
///   4. Persistent floating "+" bottom-right.
///
/// C1 constraints: all taps no-op except the journal entry prompt placeholder.
/// Canvas + detail unaffected; this view is unwired (C1.3) until C1.4 swaps
/// the app entry point.
struct DashboardView: View {

    @Environment(AppRouter.self) private var router

    @State private var collections: [NodeCollection] = NodeCollection.sample()
    @State private var showJournalPlaceholder = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                            .padding(.top, 6)
                        todaySection
                        collectionsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }

                floatingPlusButton
            }
            .toolbar(.hidden, for: .navigationBar) // dashboard renders its own header
            .navigationDestination(for: NodeCollection.self) { collection in
                CollectionView(collection: collection)
            }
            .sheet(isPresented: $showJournalPlaceholder) {
                journalPlaceholderSheet
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("AirPad")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                Spacer()
                inboxButton
                headerIconButton(systemName: "clock.arrow.circlepath")
                headerIconButton(systemName: "gearshape.fill")
            }
        }
        .frame(height: 48)
    }

    private var inboxButton: some View {
        let badgeCount = 0
        return Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.14))
                    .clipShape(Circle())

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 3)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func headerIconButton(systemName: String) -> some View {
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.14))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Today

    private var todaySection: some View {
        TodayCardView(onJournalPromptTap: { showJournalPlaceholder = true })
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.8)

            VStack(spacing: 8) {
                ForEach(collections) { collection in
                    CollectionRow(collection: collection, onTap: { tap(collection) })
                }
            }
        }
    }

    // MARK: - Row taps

    /// Corpus row routes to the existing canvas (no scoping — Corpus is the
    /// "everything" view). User-collection rows push a scoped CollectionView
    /// onto the dashboard's nav stack.
    private func tap(_ collection: NodeCollection) {
        if collection.isCorpus {
            router.entryMode = .canvas
        } else {
            path.append(collection)
        }
    }

    // MARK: - Floating "+"

    private var floatingPlusButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: {}) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 60, height: 60)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Journal placeholder sheet

    private var journalPlaceholderSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Journal entry")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Capture wiring lands in C2.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
    }
}

// MARK: - Collection row

private struct CollectionRow: View {
    let collection: NodeCollection
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(nameFont)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: collection.isCorpus ? 0.10 : 0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private var nameFont: Font {
        collection.isCorpus
            ? .system(size: 20, weight: .semibold)
            : .system(size: 16, weight: .semibold)
    }

    private var verticalPadding: CGFloat {
        collection.isCorpus ? 20 : 14
    }

    private var subtitle: String {
        let count = "\(collection.nodeCount) " + (collection.nodeCount == 1 ? "node" : "nodes")
        guard let last = collection.lastEntryAt else { return count }
        return count + " · " + relativeTime(last)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    DashboardView()
}
