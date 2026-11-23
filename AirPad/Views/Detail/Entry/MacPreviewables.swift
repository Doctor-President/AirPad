#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

// Sweep 2b · 4.2 — "a subtle 'Space opens this' highlight" (decisions.md 2026-11-22, T: yes): only what Space can open
// gets it — photos and documents (links are out for now). A soft tint + a hairline outline, ~0.1 s fade, no motion
// (no fade either under Reduce Motion); after the pointer rests ~0.5 s a small ␣ keycap hint, only until Space has
// been used a few times (the highlight itself stays). The Mac only; the iPhone keeps long press.
// Not here yet: the same highlight for KEYBOARD focus (Tab / arrows onto an item) — that needs the attachments to be
// focusable, which is 4.1's focus work (reproduced red first in T's focus state).

/// The ␣ hint shows until Space has opened something this many times (app preference, not the library).
enum MacSpaceHint {
    static let usesKey = "mac.spaceHint.uses"
    static let showUntil = 3
    static var shouldShow: Bool { UserDefaults.standard.integer(forKey: usesKey) < showUntil }
    /// One use per second at most (a held Space repeats).
    @MainActor static func noteUsed() {
        let now = Date()
        guard now.timeIntervalSince(lastUse) > 1 else { return }
        lastUse = now
        let d = UserDefaults.standard
        d.set(d.integer(forKey: usesKey) + 1, forKey: usesKey)
    }
    @MainActor private static var lastUse = Date.distantPast
}

/// The highlight. Ink-derived (the palette's own ink, no new colour): tint ink × 0.06, hairline ink × 0.30.
struct MacSpaceHighlight: ViewModifier {
    let cornerRadius: CGFloat
    /// What the proof log calls it ("photo <id>", "document <id>"): kinds and ids only.
    let probe: String
    let onHoverChange: (Bool) -> Void
    @State private var hovering = false
    @State private var showHint = false
    @State private var rest: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppearancePalette.ink.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(AppearancePalette.ink.opacity(0.30), lineWidth: 1 / max(displayScale, 1)))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomTrailing) {
                if showHint { MacSpaceKeycap().padding(6).transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showHint)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering {
                        hovering = true
                        onHoverChange(true)
                        MacProofLog.note("4.2", "highlight on \(probe)")
                    }
                    guard !showHint else { return }
                    rest?.cancel()   // the hint waits for the pointer to REST ~0.5 s
                    rest = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled, hovering, MacSpaceHint.shouldShow else { return }
                        showHint = true
                        MacProofLog.note("4.2", "keycap hint \(probe)")
                    }
                case .ended:
                    rest?.cancel(); rest = nil
                    guard hovering else { return }
                    hovering = false; showHint = false
                    onHoverChange(false)
                    MacProofLog.note("4.2", "highlight off \(probe)")
                }
            }
            .onDisappear { rest?.cancel(); rest = nil }
    }
}

/// The small ␣ keycap.
struct MacSpaceKeycap: View {
    var body: some View {
        Text("␣")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
            .frame(minWidth: 26, minHeight: 17)
            .background(AppearancePalette.bgElevated.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppearancePalette.ink.opacity(0.25), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 4.2 — the "Space opens this" highlight + ␣ hint, reporting hover changes (the keys hang on them).
    func macSpaceHighlight(cornerRadius: CGFloat, probe: String, onHoverChange: @escaping (Bool) -> Void) -> some View {
        modifier(MacSpaceHighlight(cornerRadius: cornerRadius, probe: probe, onHoverChange: onHoverChange))
    }
}

// MARK: - Photos: the highlight, Space, Quick Look (4.3)

/// Sweep 2b · 4.3 — an entry's photos handed to Quick Look: named copies (APFS clones, removed when the viewer closes;
/// `DocumentHandoff`), opened on the clicked one. Quick Look gives zoom (pinch / double-click), ← / → between them
/// (`MacViewerKeys`), Space closes.
struct MacPhotoQuickLookSet: Identifiable {
    let id = UUID()
    let handoffs: [DocumentHandoff]
    let start: Int
}

extension CorpusStore {
    /// The entry's photos (videos stay in AirPad's own viewer), resolved and copied off the main thread; nil when the
    /// clicked photo can't be found on disk.
    func macPhotoQuickLook(_ items: [GalleryItem], parent: NodeItem?, nodeID: String, start: GalleryItem) async -> MacPhotoQuickLookSet? {
        let photos = items.filter { $0.mediaType == .image }
        var resolved: [(GalleryItem, URL)] = []
        for p in photos {
            if let u = await resolveGalleryItemURL(p, nodeID: nodeID, fallbackParentItem: parent) { resolved.append((p, u)) }
        }
        guard let startIndex = resolved.firstIndex(where: { $0.0.id == start.id }) else {
            MacProofLog.note("4.3", "photo \(start.id) not on disk: no viewer")
            return nil
        }
        let t0 = ContinuousClock.now
        let handoffs = await withTaskGroup(of: (Int, DocumentHandoff).self) { group in
            for (i, (p, u)) in resolved.enumerated() {
                group.addTask { (i, await DocumentHandoff.make(for: p, storedURL: u)) }
            }
            var out: [(Int, DocumentHandoff)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
        // Only named copies go to Quick Look: a photo whose copy failed (`folder == nil` = the stored file) is left out,
        // so Quick Look's Share can never send the stored file (review of 4.3).
        let startID = resolved[startIndex].0.id
        let copied = handoffs.filter { $0.folder != nil }
        guard let start = copied.firstIndex(where: { $0.documentID == startID }) else {
            MacProofLog.note("4.3", "photo \(startID) could not be copied: no viewer")
            return nil
        }
        MacProofLog.note("4.3", "photo viewer: \(copied.count) of \(handoffs.count) photos copied in \(ms) ms, start \(start)")
        return MacPhotoQuickLookSet(handoffs: copied, start: start)
    }
}

extension View {
    /// 4.3 — presents an entry's photos in Quick Look.
    func macPhotoQuickLookSheet(_ set: Binding<MacPhotoQuickLookSet?>) -> some View {
        appSheet(item: set) { s in
            DocumentViewerSheet(handoffs: s.handoffs, startIndex: s.start)
                .ignoresSafeArea()
        }
    }
}

/// A gallery / single photo on the Mac: the highlight, Space opens what a click opens (Quick Look), ⌘O opens a COPY in
/// its default app (4.4), ⌘⇧R reveals it, and a right-click menu (Quick Look · Open a Copy with <App> · Reveal in
/// Finder · Show in Viewer… — AirPad's own viewer keeps caption, Set as Hero, Share and Delete). Videos: unchanged.
struct MacPhotoActionsModifier: ViewModifier {
    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem?
    let cornerRadius: CGFloat
    let open: () -> Void
    let showInViewer: (() -> Void)?
    @State private var state = MacDocumentState()
    @Environment(CorpusStore.self) private var store

    func body(content: Content) -> some View {
        if galleryItem.mediaType == .image {
            content
                .task(id: galleryItem.id) {
                    guard let url = await store.resolveGalleryItemURL(galleryItem, nodeID: nodeID, fallbackParentItem: parentItem) else { return }
                    state.url = url
                    state.title = DocumentHandoff.displayName(for: galleryItem)
                    state.ext = url.pathExtension
                    state.appName = MacDefaultApp.name(for: url)
                }
                .macSpaceHighlight(cornerRadius: cornerRadius, probe: "photo \(galleryItem.id)") { on in
                    MacDocumentKeys.hover(galleryItem.id, .init(quickLook: {
                        MacSpaceHint.noteUsed()
                        MacProofLog.note("4.2", "space opens photo \(galleryItem.id)")
                        open()
                    }, open: { state.open() }, reveal: { state.reveal() }), on)
                }
                .onDisappear { MacDocumentKeys.clear(galleryItem.id) }
                .contextMenu {
                    Button { open() } label: { Label("Quick Look", systemImage: "eye") }
                    MacDocumentMenuItems(state: state)
                    if let showInViewer {
                        Divider()
                        Button { showInViewer() } label: { Label("Show in Viewer…", systemImage: "photo") }
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func macPhotoActions(_ galleryItem: GalleryItem, nodeID: String, parentItem: NodeItem?, cornerRadius: CGFloat,
                         open: @escaping () -> Void, showInViewer: (() -> Void)? = nil) -> some View {
        modifier(MacPhotoActionsModifier(galleryItem: galleryItem, nodeID: nodeID, parentItem: parentItem,
                                         cornerRadius: cornerRadius, open: open, showInViewer: showInViewer))
    }
}

/// Sweep 2b · 4.4 — "Open a Copy with <App>": the default app per file extension, asked once per extension (a Launch
/// Services query; a gallery of 30 photos asks once, not 30 times on the main thread).
@MainActor
enum MacDefaultApp {
    private static var byExtension: [String: String?] = [:]
    static func name(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if let known = byExtension[ext] { return known }
        let name = MacDocumentActions.defaultAppName(for: url)
        byExtension[ext] = name
        return name
    }
}

// MARK: - The open viewer's keys (4.3)

/// Sweep 2b · 4.3 — while a Quick Look viewer is open: Space or Esc closes it, ← / → step between several items. Taken
/// where AppKit first sees the key (a local monitor, as `MacDocumentKeys`), unless a text field INSIDE the viewer is being
/// edited (Quick Look's own search). The item under the viewer is held off meanwhile (`MacDocumentKeys.suspendForViewer`).
/// Sweep 2b · 4.1 — a field left focused under the viewer (T's toolbar search) no longer takes Space / Esc from it, and
/// ⌘O opens a copy of the item the viewer shows (Finder: ⌘O works while Quick Look is up).
@MainActor
enum MacViewerKeys {
    private struct Viewer {
        let token: Int; let count: Int; let close: () -> Void; let step: (Int) -> Int?; let isLive: () -> Bool
        let openCurrent: () -> Void; let owns: (UIView) -> Bool
    }
    private static var current: Viewer?
    private static var monitor: AnyObject?
    private static var lastToken = 0
    /// A viewer is open: Esc / Space are its (the toolbar search's Esc defers to it — sweep 2b · 4.1).
    static var isOpen: Bool { current?.isLive() ?? false }

    /// Returns a token; only `close(token)` with it ends this viewer's keys (a late `onDisappear` of an earlier viewer
    /// can't take a newer viewer's). `isLive` = its controller is still in a window: if not, keys pass through.
    static func open(count: Int, close: @escaping () -> Void, step: @escaping (Int) -> Int?, isLive: @escaping () -> Bool,
                     openCurrent: @escaping () -> Void, owns: @escaping (UIView) -> Bool) -> Int {
        lastToken += 1
        if current == nil { MacDocumentKeys.suspendForViewer() }
        current = Viewer(token: lastToken, count: count, close: close, step: step, isLive: isLive, openCurrent: openCurrent, owns: owns)
        install()
        return lastToken
    }

    static func close(_ token: Int) {
        guard current?.token == token else { return }
        current = nil
        MacDocumentKeys.resumeAfterViewer()
        MacProofLog.note("4.3", "viewer closed")
    }

    /// A text input inside the viewer is being edited (Quick Look's own search). One outside it (a field left focused
    /// in the window under the viewer) doesn't count: it isn't what the user is looking at (sweep 2b · 4.1).
    private static func editingTextInViewer(_ v: Viewer) -> Bool {
        FirstResponderProbe.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.airpadCaptureFirstResponder), to: nil, from: nil, for: nil)
        guard let r = FirstResponderProbe.current, r is UITextInput else { return false }
        return (r as? UIView).map(v.owns) ?? false
    }

    private static func install() {
        guard monitor == nil, let cls: AnyClass = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        guard let m = class_getClassMethod(cls, sel) else { return }
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping @convention(block) (AnyObject) -> AnyObject?) -> AnyObject?
        let handler: @convention(block) (AnyObject) -> AnyObject? = { event in
            let code = (event.value(forKey: "keyCode") as? NSNumber)?.intValue ?? -1
            let flags = ((event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0) & (0xF << 17)
            let isRepeat = (event.value(forKey: "ARepeat") as? NSNumber)?.boolValue ?? false
            let cmd: UInt = 1 << 20
            return MainActor.assumeIsolated {
                guard let v = current, v.isLive(), !editingTextInViewer(v) else { return event }
                if code == 31, flags == cmd {                                  // ⌘O: a copy of what the viewer shows
                    MacProofLog.note("4.1", "cmd-O in the viewer opens a copy")
                    v.openCurrent(); return nil
                }
                guard flags == 0 else { return event }
                if isRepeat, code == 49 || code == 53 { return nil }          // a held Space / Esc: once, not open-close-open
                switch code {
                case 49, 53:                                                   // Space, Esc
                    MacProofLog.note("4.3", code == 49 ? "space closes the viewer" : "esc closes the viewer")
                    v.close(); return nil
                case 123 where v.count > 1, 124 where v.count > 1:             // ← →
                    let i = v.step(code == 123 ? -1 : 1)
                    MacProofLog.note("4.3", "arrow \(code == 123 ? "left" : "right") → \(i.map(String.init) ?? "end")")
                    return nil
                default: return event
                }
            }
        }
        monitor = unsafeBitCast(method_getImplementation(m), to: Add.self)(cls, sel, 1 << 10, handler)
    }
}
// MARK: - Proof hook (DEBUG / PERFLOG bench builds only)

#if DEBUG || PERFLOG
/// Sweep 2b · 4.x — `-Open4x <kind>` opens one test-library entry so the real-event steps land on it: `gallery` = the
/// biggest gallery that starts with six photos, `single` = a one-photo entry, `document` = the first entry with a document.
/// Deterministic (ids sorted). Logs the kind, the id and counts — never a title.
@MainActor
enum Proof4x {
    static func open(_ kind: String, store: CorpusStore, router: AppRouter) async {
        for _ in 0..<80 where store.nodes.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        // `-Open4xDelay <s>`: open later than the bench's own setup clicks (run.sh clicks the sidebar ~14 s in).
        let delay = Double(UserDefaults.standard.string(forKey: "Open4xDelay") ?? "") ?? 1.5
        try? await Task.sleep(for: .seconds(delay))
        func photos(_ n: Node) -> Int {
            n.items.filter { $0.type == .imageVideo }.map { ($0.mediaItems ?? []).filter { $0.mediaType == .image }.count }.max() ?? 0
        }
        let sorted = store.nodes.sorted { $0.id < $1.id }
        let pick: Node?
        switch kind {
        // The biggest gallery whose first six items are all photos (the steps hover / click tiles #0–#2; a video there
        // has no highlight and no Quick Look by design).
        case "gallery":
            func leadPhotos(_ n: Node) -> Bool {
                n.items.contains { i in
                    let m = i.mediaItems ?? []
                    return i.type == .imageVideo && m.count >= 6 && m.prefix(6).allSatisfy { $0.mediaType == .image }
                }
            }
            pick = sorted.filter(leadPhotos).max { photos($0) < photos($1) }
        case "single": pick = sorted.first { n in n.items.contains { $0.type == .imageVideo && ($0.mediaItems ?? []).count == 1 && $0.mediaItems?.first?.mediaType == .image } }
        case "document": pick = sorted.first { n in n.items.contains { $0.type == .document } }
        default: pick = nil
        }
        guard let node = pick else { MacProofLog.note("4x", "open \(kind): none"); return }
        MacProofLog.note("4x", "open \(kind) \(node.id) photos \(photos(node))")
        router.pendingNodeNavigationID = node.id
    }
}
#endif
#endif
