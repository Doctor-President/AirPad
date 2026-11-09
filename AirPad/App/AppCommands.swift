import SwiftUI

/// Mac batch C1 — the menu bar on the Mac, and the same key commands on an iPad with a hardware keyboard (the ⌘-hold
/// overlay and the iPad menu bar list them). Each item asks the router (`AppRouter.perform`); the view that owns the
/// action answers (`commandRequest`): ContentView (entries, collections, views, Today, Settings, the Librarian),
/// LibrarianSurface (Find), the open entry (Export), the mounted NavigationStack (Back / Forward).
/// ⌃⌘S (Toggle Sidebar) is reserved for batch D. Text formatting keys belong to the editor (C3).
enum AppCommand: String, CaseIterable, Sendable {
    case newEntry, newCollection, closeWindow, export
    case find
    case viewMap, viewList, viewCards, librarian
    case zoomIn, zoomOut, zoomFit
    case back, forward, today
    case settings
}

struct AppCommands: Commands {
    let router: AppRouter
    let store: CorpusStore

    var body: some Commands {
        // App menu: Settings… opens the existing Settings.
        CommandGroup(replacing: .appSettings) {
            item("Settings…", .settings, "settings").keyboardShortcut(",")
        }
        // File
        CommandGroup(replacing: .newItem) {
            item("New Entry", .newEntry, "file.newEntry").keyboardShortcut("n")
                .disabled(!canCreate)
            item("New Collection", .newCollection, "file.newCollection").keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(router.entryMode == .quikCapture)
        }
        #if targetEnvironment(macCatalyst)
        CommandGroup(replacing: .saveItem) {
            item("Close Window", .closeWindow, "file.closeWindow").keyboardShortcut("w")
        }
        #endif
        CommandGroup(replacing: .importExport) {
            item("Export Entry…", .export, "file.export").keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(router.openEntryID == nil || !store.isInDetailView)
        }
        CommandGroup(replacing: .printItem) {}   // nothing in AirPad prints
        // Edit: Find opens the library search.
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Find", .find, "edit.find").keyboardShortcut("f")
                .disabled(router.isCapturing || router.entryMode == .quikCapture)
        }
        // View: the three library views and the Librarian (⌃⌘S is kept free for batch D's sidebar).
        CommandGroup(after: .sidebar) {
            item("Map", .viewMap, "view.map").keyboardShortcut("1")
            item("List", .viewList, "view.list").keyboardShortcut("2")
            item("Cards", .viewCards, "view.cards").keyboardShortcut("3")
            Divider()
            item("Librarian", .librarian, "view.librarian").keyboardShortcut("l")
                .disabled(router.isCapturing || router.entryMode == .quikCapture)
        }
        // View: the Map's zoom (C2). ⌘0 is Go › Today, so Zoom to Fit takes ⌘9, as in Preview.
        CommandGroup(after: .sidebar) {
            Divider()
            item("Zoom In", .zoomIn, "view.zoomIn").keyboardShortcut("+")
                .disabled(!mapShowing)
            item("Zoom Out", .zoomOut, "view.zoomOut").keyboardShortcut("-")
                .disabled(!mapShowing)
            item("Zoom to Fit", .zoomFit, "view.zoomFit").keyboardShortcut("9")
                .disabled(!mapShowing)
        }
        // Go
        CommandMenu("Go") {
            item("Back", .back, "go.back").keyboardShortcut("[")
                .disabled(!router.canGoBack)
            item("Forward", .forward, "go.forward").keyboardShortcut("]")
                .disabled(!router.canGoForward)
            Divider()
            item("Today", .today, "go.today").keyboardShortcut("0")
        }
        // Help: AirPad has no help book; the system's "AirPad Help" item did nothing.
        CommandGroup(replacing: .help) {}
    }

    private var mapShowing: Bool { router.mapShowing && !store.isInDetailView }
    private var canCreate: Bool { router.entryMode != .quikCapture && !router.isCapturing }

    private func item(_ title: String, _ command: AppCommand, _ id: String) -> some View {
        Button(title) { router.perform(command) }
            .accessibilityIdentifier("menu.\(id)")
    }
}

/// Mac batch C1 — Go › Back / Forward for a surface's NavigationStack. Forward works like a browser's: it re-opens what
/// Back (or the on-screen back button) just closed, until something new is opened. Applied to every NavigationStack
/// owner; only one is mounted at a time, and the mounted one publishes `canGoBack` / `canGoForward` for the menu.
struct NavigationHistory: ViewModifier {
    @Binding var path: NavigationPath
    @Environment(AppRouter.self) private var router
    @State private var forward: [NavigationPath] = []
    @State private var restoring = false

    func body(content: Content) -> some View {
        content
            .onChange(of: path) { old, new in
                if new.count < old.count { forward.append(old) }
                else if !restoring { forward.removeAll() }
                restoring = false
                publish()
            }
            .onChange(of: router.commandRequest) { _, request in
                switch request?.command {
                case .back?:
                    if !path.isEmpty { path.removeLast() }
                case .forward?:
                    if let next = forward.popLast() { restoring = true; path = next }
                default: break
                }
            }
            .onAppear { publish() }
    }

    private func publish() {
        router.canGoBack = !path.isEmpty
        router.canGoForward = !forward.isEmpty
    }
}

extension View {
    /// Mac batch C1 — Go › Back / Forward for this NavigationStack's path.
    func navigationHistory(_ path: Binding<NavigationPath>) -> some View { modifier(NavigationHistory(path: path)) }
}
