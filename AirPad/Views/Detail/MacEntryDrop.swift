import SwiftUI
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
/// E fix-up 6 (M6) [T ruled 2026-11-18 "Hover"] — dropping into an open entry on the Mac, by where the pointer is:
/// - over an item that can take everything dragged (images / videos → a gallery, files → a documents item, web links →
///   a Link item): that item lights up with a short label and the drop is added at its end;
/// - over the gap between two items (or above the first / below the last): an insertion line, and the drop becomes
///   new items there;
/// - anywhere else in the entry (or over an item that can't take all of it): today's drop, new items at the end.
/// No prompt; Edit › Undo (⌘Z) takes the add back. Highlights clear with the window's (`DropHighlightWatchdog`) when
/// a drag ends elsewhere.
struct MacEntryItemDrop: ViewModifier {
    let item: NodeItem
    let nodeID: String
    let index: Int
    @Environment(CorpusStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var fits = false
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if over && fits {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                        .overlay(alignment: .top) {
                            Text(Self.label(for: item))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(y: -11)
                        }
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("entryDropInto-\(item.id)")
                }
            }
            .onDrop(of: [.item], delegate: ItemDelegate(item: item, fits: $fits, over: $over, perform: perform))
            #if DEBUG
            // The harness finds each item's frame by this marker (the card's own identifiers stay as they are).
            .background(Color.clear.accessibilityElement().accessibilityLabel("drop item").accessibilityIdentifier("entryDropItem-\(item.id)"))
            #endif
    }

    static func label(for item: NodeItem) -> String {
        switch CorpusStore.entryDropKind(of: item) {
        case .media: return "Add to this gallery"
        case .document: return "Add to these documents"
        case .link: return "Add to these links"
        default: return "Add here"
        }
    }

    private func perform(_ providers: [NSItemProvider], _ placement: CorpusStore.EntryDropPlacement) {
        MacEntryDrop.perform(providers, placement, nodeID: nodeID, store: store, undoManager: undoManager)
    }

    private struct ItemDelegate: DropDelegate {
        let item: NodeItem
        @Binding var fits: Bool
        @Binding var over: Bool
        let perform: ([NSItemProvider], CorpusStore.EntryDropPlacement) -> Void

        func dropEntered(info: DropInfo) {
            fits = CorpusStore.entryDropFits(info.itemProviders(for: [.item]), into: item)
            over = true
            MacEntryDragState.shared.began()
            let o = $over
            DropHighlightWatchdog.watch("item-\(item.id)") { o.wrappedValue = false }
        }
        func dropExited(info: DropInfo) { over = false }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
        func performDrop(info: DropInfo) -> Bool {
            let providers = info.itemProviders(for: [.item])
            let into = CorpusStore.entryDropFits(providers, into: item)
            over = false
            // Doesn't fit: today's drop (new items at the end).
            perform(providers, into ? .into(itemID: item.id) : .at(index: .max))
            return true
        }
    }
}

/// While a drag is over the window the entry's gaps open up (4 pt → 14 pt) so there is somewhere to aim; they close
/// once the drag ends (the watchdog: no mouse button held).
@Observable final class MacEntryDragState {
    static let shared = MacEntryDragState()
    var active = false
    @MainActor func began() {
        if !active { active = true }
        DropHighlightWatchdog.watch("entryDrag") { MacEntryDragState.shared.active = false }
    }
}

enum MacEntryDrop {
    static let openGap: CGFloat = 14

    @MainActor static func perform(_ providers: [NSItemProvider], _ placement: CorpusStore.EntryDropPlacement, nodeID: String,
                                   store: CorpusStore, undoManager: UndoManager?) {
        Task { @MainActor in
            guard let undo = await store.dropIntoEntry(providers, nodeID: nodeID, placement: placement) else { return }
            undoManager?.registerUndo(withTarget: store) { s in Task { @MainActor in await s.undoEntryDrop(undo) } }
            undoManager?.setActionName("Add")
            NSLog("[EntryDrop] %@ → gallery %d docs %d links %d new %d", String(describing: placement),
                  undo.gallery.count, undo.documents.count, undo.links.count, undo.newItems.count)
        }
    }
}

/// The gap between two items (on the Mac the stack's spacing IS this view, same height): an insertion line while a
/// drag is over it; the drop becomes new items there. (A zone drawn as an overlay outside a card took no drops.)
struct MacEntryGapDrop: View {
    let nodeID: String
    let insertAt: Int
    let height: CGFloat
    @Environment(CorpusStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var on = false

    var body: some View {
        Color.clear
            .frame(height: MacEntryDragState.shared.active ? max(height, MacEntryDrop.openGap) : height)
            .animation(.easeOut(duration: 0.15), value: MacEntryDragState.shared.active)
            .contentShape(Rectangle())
            #if DEBUG
            .accessibilityElement().accessibilityLabel("drop gap").accessibilityIdentifier("entryDropGapZone-\(insertAt)")   // the harness's aim
            #endif
            .overlay {
                if on {
                    Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 6)
                        .accessibilityIdentifier("entryDropGap-\(insertAt)")
                }
            }
            .onDrop(of: [.item], isTargeted: $on) { providers in
                MacEntryDrop.perform(providers, .at(index: insertAt), nodeID: nodeID, store: store, undoManager: undoManager)
                return true
            }
            .onChange(of: on) { _, v in
                if v { MacEntryDragState.shared.began(); DropHighlightWatchdog.watch("gap-\(insertAt)") { on = false } }
            }
    }
}
#endif
