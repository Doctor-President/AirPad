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
            over = false
            // Sweep 1 · N5 — the hovered item takes what fits; the rest sorts (`dropIntoEntry`).
            perform(providers, .into(itemID: item.id))
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
            guard let undo = await store.dropIntoEntry(providers, nodeID: nodeID, placement: placement,
                                                       choose: { kind, items in await MacDropNote.shared.ask(kind, items) })
            else { return }
            undoManager?.registerUndo(withTarget: store) { s in Task { @MainActor in await s.undoEntryDrop(undo) } }
            undoManager?.setActionName("Add")
            // Sweep 1 · N5 — say what went where, with Undo (⌘Z still works).
            if !undo.summary.isEmpty {
                MacDropNote.shared.show(undo.summary) { [weak undoManager] in
                    if undoManager?.canUndo == true { undoManager?.undo() } else { Task { await store.undoEntryDrop(undo) } }
                }
            }
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
    var openHeight: CGFloat = MacEntryDrop.openGap
    @Environment(CorpusStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var on = false

    var body: some View {
        Color.clear
            .frame(height: MacEntryDragState.shared.active ? max(height, openHeight) : height)
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

/// Sweep 1 · N5 — the short note after a sorted drop ("Added 1 photo to Gallery · 1 PDF to Documents", Undo), and the
/// question when two items of the same kind could take a drop (a small choice naming them, plus "New Item").
@MainActor @Observable final class MacDropNote {
    static let shared = MacDropNote()
    var message: String?
    @ObservationIgnored var undo: (() -> Void)?
    var question: (title: String, options: [(id: String, name: String)])?
    @ObservationIgnored private var answer: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var token = UUID()

    func show(_ text: String, undo: @escaping () -> Void) {
        message = text; self.undo = undo
        let t = UUID(); token = t
        Task { try? await Task.sleep(for: .seconds(6)); if self.token == t { self.message = nil } }
    }

    func ask(_ kind: CorpusStore.EntryDropKind, _ items: [NodeItem]) async -> String? {
        let noun = kind == .media ? "photos and videos" : kind == .document ? "files" : "links"
        answer?.resume(returning: nil)
        return await withCheckedContinuation { c in
            answer = c
            question = ("Add the \(noun) to…", items.map { ($0.id, $0.displayName ?? $0.type.defaultDisplayName) })
        }
    }

    func reply(_ id: String?) {
        answer?.resume(returning: id); answer = nil; question = nil
    }
}

struct MacDropNoteView: View {
    @State private var note = MacDropNote.shared
    var body: some View {
        VStack {
            Spacer()
            if let m = note.message {
                HStack(spacing: 12) {
                    Text(m).font(.system(size: 13)).foregroundStyle(AppearancePalette.ink).lineLimit(2)
                    Button("Undo") { note.undo?(); note.message = nil }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("entryDropNoteUndo")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(AppearancePalette.ink.opacity(0.12)))
                .padding(.bottom, 24)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("entryDropNote")
            }
        }
        .animation(.easeOut(duration: 0.2), value: note.message)
        .allowsHitTesting(note.message != nil)
        .confirmationDialog(note.question?.title ?? "", isPresented: Binding(
            get: { note.question != nil }, set: { if !$0 && note.question != nil { note.reply(nil) } }
        ), titleVisibility: .visible) {
            ForEach(note.question?.options ?? [], id: \.id) { o in Button(o.name) { note.reply(o.id) } }
            Button("New Item") { note.reply(nil) }
        }
    }
}
#endif
