import SwiftUI

/// Reusable horizontal pill rail for collection selection. Extracted from
/// QuikCaptureView (Dashboard Stage 4 c4.4/c4.5) so the in-app capture
/// overlay can share the same render + interaction model.
///
/// Rail order: virtual Journal pill prepended, then all user collections
/// sorted by `collectionLastUsedAt` desc (unmapped entries fall to the tail
/// via `.distantPast`, stable order preserved). Tap pins selection and
/// updates `lastUsedCollectionID` for next-session pre-hydration, but does
/// NOT bump `collectionLastUsedAt` — the rail order stays stable across
/// the multi-tap selection session (same grammar as `TagPillRail`). Tap on
/// the selected pill deselects.
///
/// Recency is bumped via other paths: entering a CollectionView
/// (`.onAppear` calls `markCollectionUsed`), creating a new collection via
/// `CollectionCreationSheet`, and document creation in the overlay.
///
/// Modes:
/// - **Interactive** (`lockedID == nil`): rail responds to taps; "New +"
///   pill appears at the end when `onCreateNew` is provided.
/// - **Locked** (`lockedID != nil`): only the locked pill highlights; taps
///   no-op; "New +" hidden (creating a collection mid-forced-capture
///   would orphan the new pill — the node still lands in the locked one).
struct CollectionPillRail: View {

    @Binding var selectedCollectionID: String?
    var lockedID: String? = nil
    var onCreateNew: (() -> Void)? = nil

    @Environment(CorpusStore.self) private var store

    /// What the rail actually highlights. Locked wins over selection,
    /// matching the QuikCapture `effectiveCollectionID` semantics.
    private var displayedID: String? {
        lockedID ?? selectedCollectionID
    }

    private var railCollections: [NodeCollection] {
        let journal = NodeCollection(id: NodeCollection.journalID, name: "Journal")
        let all = [journal] + store.collections
        return all.sorted { a, b in
            let aDate = store.collectionLastUsedAt[a.id] ?? .distantPast
            let bDate = store.collectionLastUsedAt[b.id] ?? .distantPast
            return aDate > bDate
        }
    }

    var body: some View {
        let isLocked = lockedID != nil
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(railCollections) { collection in
                    pill(for: collection, isLocked: isLocked)
                }
                if !isLocked, onCreateNew != nil {
                    newCollectionPill
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func pill(for collection: NodeCollection, isLocked: Bool) -> some View {
        let isSelected = displayedID == collection.id
        return Button {
            guard !isLocked else { return }
            if isSelected {
                selectedCollectionID = nil
                store.lastUsedCollectionID = nil
            } else {
                store.lastUsedCollectionID = collection.id
                selectedCollectionID = collection.id
            }
        } label: {
            pillLabel(collection.name, isSelected: isSelected, isLocked: isLocked)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }

    /// Pill face. Light-mode convergence: the UNSELECTED pill was a solid dark
    /// `Color(white: 0.18)` circle with `.white` text (illegible on the light
    /// capture surface) → now the STANDARD `chromeSurface` glass + adaptive `ink`,
    /// one implementation for both modes. The SELECTED accent (white fill + black
    /// text) is a selection-state branch (not a colorScheme fork) and is unchanged.
    @ViewBuilder
    private func pillLabel(_ name: String, isSelected: Bool, isLocked: Bool) -> some View {
        let base = Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? Color.black
                                        : AppearancePalette.ink.opacity(isLocked ? 0.35 : 0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        if isSelected {
            base.background(Color.white, in: Capsule())
        } else {
            base.contentShape(Capsule())
                .chromeSurface(Capsule())
                .clipShape(Capsule())
        }
    }

    private var newCollectionPill: some View {
        Button {
            onCreateNew?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("New")
                    .font(.system(size: 13, weight: .semibold))
            }
            // Light-mode convergence — adaptive ink text + ink stroke (were
            // `.white`, invisible on the light capture surface). Outline-only
            // affordance kept (no fill) so it stays quieter than the pills.
            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(
                Capsule().stroke(AppearancePalette.ink.opacity(0.22), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
