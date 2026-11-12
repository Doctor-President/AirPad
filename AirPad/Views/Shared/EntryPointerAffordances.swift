import SwiftUI

/// Mac batch C5 — what a right-click (Mac) / secondary click or long-press (iPad) on an entry offers, wherever the entry
/// shows (List, Recents, Cards, the Map). The actions are one router request each, answered at the root (ContentView)
/// with the entry menu's own paths: Open, Make Private / Make Not Private, Export…, Delete (with its confirmation).
/// No "Copy Link": AirPad has no entry links yet. iPhone: unchanged (no new long-press menus).
enum EntryAction: Equatable, Sendable {
    case open, togglePrivate, export, delete
}

struct EntryContextMenu: ViewModifier {
    let nodeID: String
    let isPrivate: Bool
    @Environment(AppRouter.self) private var router

    static var enabled: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    func body(content: Content) -> some View {
        if Self.enabled {
            content.contextMenu {
                Button { router.requestEntryAction(.open, nodeID) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                if PrivateEntries.shared.available {
                    Button { router.requestEntryAction(.togglePrivate, nodeID) } label: {
                        Label(isPrivate ? "Make Not Private" : "Make Private", systemImage: isPrivate ? "lock.open" : "lock")
                    }
                }
                Button { router.requestEntryAction(.export, nodeID) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Divider()
                Button(role: .destructive) { router.requestEntryAction(.delete, nodeID) } label: { Label("Delete…", systemImage: "trash") }
            }
        } else {
            content
        }
    }
}

/// Mac batch C5 — the pointer is over it: a subtle wash (ink at 5%), the same in light and dark. Nothing on iPhone
/// (no pointer); on iPad it follows a trackpad / mouse.
struct PointerHover<S: Shape>: ViewModifier {
    let shape: S
    var color: Color = AppearancePalette.ink
    var opacity: Double = 0.05
    @State private var hovering = Self.forced

    /// DEBUG `-ForcePointerHover`: every hover wash on, for stills (a locked Mac has no pointer).
    static var forced: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-ForcePointerHover")
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        content
            .overlay(shape.fill(color.opacity(hovering ? opacity : 0)).allowsHitTesting(false))
            .onHover { if !Self.forced { hovering = $0 } }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func entryContextMenu(_ node: Node) -> some View { modifier(EntryContextMenu(nodeID: node.id, isPrivate: node.isPrivate)) }
    func pointerHover<S: Shape>(_ shape: S) -> some View { modifier(PointerHover(shape: shape)) }
    func pointerHover(cornerRadius: CGFloat = 12) -> some View {
        modifier(PointerHover(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

