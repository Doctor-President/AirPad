import SwiftUI
import FloatingPanel

struct ContentView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(QuarantineStore.self) private var quarantineStore

    /// Single persistent in-layout panel. Mounted at ContentView root via
    /// the non-modal `.floatingPanel { proxy in … }` modifier on the outer
    /// ZStack — added as a child VC by the modifier, never `present()`.
    /// Entry-mode transitions raise it to `.tip` on canvas surfaces and
    /// `.hidden` on dashboard / QuikCapture; user drag covers
    /// `.tip` ↔ `.half` ↔ `.full`.
    @State private var panelState = LibrarianPanelStateModel()
    /// Mac batch C4 — something is being dragged over the window (the drop highlight).
    @State private var dropTargeted = false
    private let panelLayout = LibrarianPanelLayout()
    // Brief AT5 — app-wide Appearance override (System / Light / Dark), applied to the window(s).
    @AppStorage(AppearanceOverride.storageKey) private var appearanceRaw = AppearanceOverride.system.rawValue
    @Environment(\.colorScheme) private var colorScheme   // live-23 (1) — the Librarian's dim is per mode

    var body: some View {
        @Bindable var routerBinding = router
        ZStack {
            // Brief AT5 — pin the window appearance to the user's choice (System = follow iOS). Live.
            AppearanceApplier(style: (AppearanceOverride(rawValue: appearanceRaw) ?? .system).uiStyle)
                .frame(width: 0, height: 0)
            // 1.1-A (A6) — the Face ID lock + app-switcher cover, in their own window above everything.
            AppLockInstaller()
            #if targetEnvironment(macCatalyst)
            // Mac batch D1 — the window's toolbar (hosted SwiftUI, given the app's environment).
            Color.clear.frame(width: 0, height: 0).onAppear {
                let (r, s, sel, q) = (router, store, selection, quarantineStore)
                MacToolbarController.shared.install { view in
                    AnyView(view.environment(r).environment(s).environment(sel).environment(q).provideAppBodyFont())
                }
            }
            #endif
            #if DEBUG || TESTFLIGHT
            // live-22 (2) — the on-device appearance tuner floats in its own pass-through window, over every view,
            // sheet and the Librarian panel (TestFlight only; in DEBUG only with `-AppearanceTuner YES`).
            if AppearanceTuning.isLive { AppearanceTunerInstaller().frame(width: 0, height: 0) }
            #endif
            #if PANBENCH && !DEBUG
            Color.clear.frame(width: 0, height: 0).onAppear {   // bench builds: `-OpenMap` (DEBUG has its own)
                if ProcessInfo.processInfo.arguments.contains("-OpenMap"), router.entryMode != .canvas { router.entryMode = .canvas }
            }
            #endif
            #if DEBUG
            // `-OpenCardView` companion — `entryMode` defaults to `.recents`, so the
            // viewMode seed alone never reaches the canvas.
            Color.clear.frame(width: 0, height: 0).onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenCardView") || ProcessInfo.processInfo.arguments.contains("-OpenListView"),
                   router.entryMode != .canvas { router.entryMode = .canvas }
                // live-19 (3a) — `-DebugFocusSweep`: once the library is up, fire the REAL focus request (the one a
                // Librarian search row fires) at five nodes spread across it, 5 s apart — far rows the surface has
                // never realised. `ScrollToLanding` asserts each lands on screen (iOS 27: FB24968838 reports
                // `scrollTo` missing unrealised lazy rows).
                if ProcessInfo.processInfo.arguments.contains("-DebugFocusSweep") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 50 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        let ids = store.nodes.map(\.id).sorted()
                        for (k, i) in [30, 90, 150, 200, ids.count - 1].enumerated() where i < ids.count {
                            print("[FocusSweep] request k=\(k) id=\(ids[i])")
                            router.requestFocus(ids[i])
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                        }
                        print("[FocusSweep] done")
                    }
                }
                // Mac batch A — `-MacReport`: the Mac-sensitive answers, logged once the window is up (and again after a
                // resize settles, so the window-sized DisplaySize shows).
                RunningOnMac.snapshotIfAsked()
                // Mac batch C2 — `-MapPointerSelfTest`: the Map's trackpad / wheel / hover / keyboard-zoom paths.
                if ProcessInfo.processInfo.arguments.contains("-MapPointerSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<160 where !router.mapSettled { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        NSLog("%@", await MapPointerSelfTest.run(store: store, router: router))
                    }
                }
                #if targetEnvironment(macCatalyst)
                // Mac fix-up X1 — `-MapPinchReplaySelfTest`: magnify events replayed through the real pinch recogniser.
                if ProcessInfo.processInfo.arguments.contains("-MapPinchReplaySelfTest") {
                    Task { @MainActor in
                        for _ in 0..<160 where !router.mapSettled { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        NSLog("%@", await MapPinchReplaySelfTest.run())
                    }
                }
                // Mac fix-up X7 — `-CaptureClickSelfTest`: a new entry's Done, clicked for real.
                if ProcessInfo.processInfo.arguments.contains("-CaptureClickSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<160 where !router.mapSettled { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        NSLog("%@", await CaptureClickSelfTest.run(store: store, router: router))
                    }
                }
                // Mac fix-up X2 — `-MapHoverStillsSelfTest`: hover ring + tag measured and shot at three zooms.
                if ProcessInfo.processInfo.arguments.contains("-MapHoverStillsSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<160 where !router.mapSettled { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        NSLog("%@", await MapHoverStillsSelfTest.run(look: UserDefaults.standard.string(forKey: "appearance.override") ?? "light"))
                    }
                }
                #endif
                // Mac batch C4 — `-ShowDropHighlight`: the drop highlight, for its still.
                if ProcessInfo.processInfo.arguments.contains("-ShowDropHighlight") { dropTargeted = true }
                // Mac batch C3 — `-FocusNoteEditor <s>`: focus the first note editor on screen after <s> s (inline-bar stills).
                if let after = UserDefaults.standard.string(forKey: "FocusNoteEditor").flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        func walk(_ v: UIView) -> RichTextUIView? {
                            if let t = v as? RichTextUIView, !(t.text ?? "").isEmpty { return t }
                            for s in v.subviews { if let r = walk(s) { return r } }
                            return nil
                        }
                        let tv = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).lazy.compactMap(walk).first
                        tv?.becomeFirstResponder()
                        tv?.selectedRange = NSRange(location: 0, length: min(5, (tv?.text as NSString?)?.length ?? 0))
                    }
                }
                // Mac batch C5 — `-EntryMenuSelfTest`: the entry menu's actions, the orb menu, delete-after-edit.
                if ProcessInfo.processInfo.arguments.contains("-EntryMenuSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<160 where !router.mapSettled { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        NSLog("%@", await EntryMenuSelfTest.run(store: store, router: router))
                    }
                }
                // Mac batch C3 — `-EditorRoundTripSelfTest`: every Format command → save → disk → re-open.
                if ProcessInfo.processInfo.arguments.contains("-EditorRoundTripSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await EditorRoundTripSelfTest.run(store: store, router: router))
                    }
                }
                // Mac D0.10 — `-BoldMarkupSelfTest`: bold/italic written as CommonMark spans.
                if ProcessInfo.processInfo.arguments.contains("-BoldMarkupSelfTest") {
                    Task { @MainActor in NSLog("%@", BoldMarkupSelfTest.run()) }
                }
                // Mac D0.8 — `-EmptyLineListSelfTest`: list commands on an empty line.
                if ProcessInfo.processInfo.arguments.contains("-EmptyLineListSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await EmptyLineListSelfTest.run(store: store, router: router))
                    }
                }
                // Mac fix-up X8 — `-NoteWeightSelfTest`: regular note weight; B and Body on bold.
                if ProcessInfo.processInfo.arguments.contains("-NoteWeightSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await NoteWeightSelfTest.run(store: store, router: router))
                    }
                }
                #if targetEnvironment(macCatalyst)
                // Mac batch C6 — `-MacWindowFrameTest set|check`: set the main window's frame (then quit), or log it at
                // the next launch (the harness compares).
                if let mode = UserDefaults.standard.string(forKey: "MacWindowFrameTest") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if mode == "set", let cls = NSClassFromString("NSApplication") as? NSObject.Type,
                           let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
                           let win = (app.value(forKey: "windows") as? [NSObject])?.first(where: { ($0.value(forKey: "visible") as? NSNumber)?.boolValue == true }) {
                            typealias SetFrame = @convention(c) (AnyObject, Selector, CGRect, Bool) -> Void
                            let sel = NSSelectorFromString("setFrame:display:")
                            unsafeBitCast(win.method(for: sel), to: SetFrame.self)(win, sel, CGRect(x: 160, y: 140, width: 1180, height: 760), true)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSLog("[MacWindowFrameTest] %@ frame=%@", mode, RunningOnMac.mainWindowFrame.map { NSCoder.string(for: $0) } ?? "nil")
                        }
                    }
                }
                // Mac batch C1 — `-MacMenuSelfTest`: the real menu bar, fired item by item, once the library is up.
                if ProcessInfo.processInfo.arguments.contains("-MacMenuSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await MacMenuSelfTest.run(store: store, router: router))
                    }
                }
                // Mac batch D — `-MacLayoutSelfTest`: the toolbar, sidebar and Librarian column.
                if ProcessInfo.processInfo.arguments.contains("-MacLayoutSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await MacLayoutSelfTest.run(store: store, router: router))
                    }
                }
                // Mac D0.11 — `-MacSheetsSelfTest` (with `-OpenMap -OpenAppearancePanel -ProLocked YES`): popovers + closes.
                if ProcessInfo.processInfo.arguments.contains("-MacSheetsSelfTest") {
                    Task { @MainActor in
                        for _ in 0..<120 where store.nodes.count < 10 { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        NSLog("%@", await MacSheetsSelfTest.run(store: store, router: router))
                    }
                }
                #endif
                RunningOnMac.forceOrientationIfAsked()   // C7 — iPad four-orientation stills
                if ProcessInfo.processInfo.arguments.contains("-MacReport") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { RunningOnMac.report() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { RunningOnMac.report() }
                }
                // Brief AS — `-OpenMap` lands on the canvas (Map) for headless verification.
                if ProcessInfo.processInfo.arguments.contains("-OpenMap"),
                   router.entryMode != .canvas { router.entryMode = .canvas }
                // CH ruling 5 — `-OpenChatsList` opens the Chats list sheet (the real surface both entry points
                // present) so the off-pillar smoke test can drive rename / delete headlessly.
                if ProcessInfo.processInfo.arguments.contains("-OpenChatsList") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { router.showChatsList = true }
                }
                // `-OpenDashboard` — land on the Dashboard ROOT (not Recents) so the
                // sample-library strip (Brief T) is screenshot-reachable headlessly.
                if ProcessInfo.processInfo.arguments.contains("-OpenDashboard"),
                   router.entryMode != .dashboard { router.entryMode = .dashboard }
                // ws-fluted-glass still harness — `-OpenFirstGradientEntry` pushes the detail of
                // the first gradient-only (no cover image) entry, so the entry hero is reachable
                // headlessly. Waits for the corpus to load.
                // live-28 (5) — `-OpenEntryTitled <title>`: push that entry's detail (the Sample Library attribute stills).
                if let title = UserDefaults.standard.string(forKey: "OpenEntryTitled"), !title.isEmpty {
                    Task { @MainActor in
                        for _ in 0..<40 where !store.nodes.contains(where: { $0.title == title }) {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        // live-29 (4) — three "Sid" and two "Linda" entries share a title; the one with attributes is
                        // the one these stills are about (live-28's sheet opened a field-less "Sid" and read it as broken).
                        let titled = store.nodes.filter { $0.title == title }
                        if let node = titled.first(where: { $0.items.contains { $0.type == .field } }) ?? titled.first {
                            router.pendingNodeNavigationID = node.id
                        }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-OpenFirstGradientEntry") {
                    Task { @MainActor in
                        for _ in 0..<40 where store.nodes.isEmpty {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if let node = store.nodes.first(where: { $0.coverImageRelativePath == nil }) {
                            router.pendingNodeNavigationID = node.id
                        }
                    }
                }
                // Brief CD acceptance tests — `-EntryQuikCapture` is the EXACT production
                // Quick Capture entry: it sets `entryMode = .quikCapture`, the same line the
                // `airpad://quikcapture` deep-link handler runs (AirPadApp.onOpenURL). NOT a
                // seeded screen — QuikCaptureView's own `.task` creates the real capture node,
                // and Done runs the real path. Lets an XCUITest drive the real Quick Capture flow.
                if ProcessInfo.processInfo.arguments.contains("-EntryQuikCapture"),
                   router.entryMode != .quikCapture { router.entryMode = .quikCapture }
                // Brief CD diag/test — `-RealCapturePlus` runs the REAL "+" capture ACTION (the exact
                // calls CanvasChrome's captureTriggerButton makes: createCaptureNode → router handoff →
                // push NodeDetailView in capture mode), then STOPS. No seeded node content, no seeded
                // proposal — the XCUITest types into the REAL note editor from here, so the whole
                // pipeline (editor → scheduleCaptureLiveCommit → updateTextItem → scheduleEnrichment →
                // gate → processNodeWithAI → recordProposal → ghost) runs for real. (On the empty-corpus
                // canvas the "+" chrome is awkward to hit by coordinate; the ACTION is identical.)
                if ProcessInfo.processInfo.arguments.contains("-RealCapturePlus") {
                    Task { @MainActor in
                        // CH-B — act once the library is in memory, as a person's first tap would: at launch the
                        // initial load REPLACES `store.nodes` wholesale, and a capture node made before it lands
                        // came back with no note (no `noteEditor` on the Simulator; T's device was fine).
                        for _ in 0..<40 where store.nodes.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let node = await store.createCaptureNode() else { return }
                        router.isCapturing = true
                        router.captureNodeID = node.id
                        router.captureDraftHasText = false
                        router.pendingNodeNavigationID = node.id   // the real "+" handoff → push detail
                        // Auto-focus the note so the XCUITest's typeText lands (createCaptureNode opens
                        // "calm" by design; the test needs the keyboard up to type). Real editor, real pipeline.
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if let fresh = store.nodes.first(where: { $0.id == node.id }),
                           let textID = fresh.items.first(where: { $0.type == .text })?.id {
                            store.pendingAutoFocusItemID = textID
                        }
                        // Brief CD — REPRODUCE THE DEVICE BUG: the detail-exit handler clears
                        // router.isCapturing during the "+"→push on device. Clear it here too, so the
                        // XCUITest composes with cap=0 — and the ghost must STILL appear via the robust
                        // `isComposing` signal. (`-RealCapturePlusKeepFlag` skips this for the old path.)
                        if !ProcessInfo.processInfo.arguments.contains("-RealCapturePlusKeepFlag") {
                            router.isCapturing = false
                            router.captureNodeID = nil
                        }
                    }
                }
            }
            #endif
            macDesktop {
                switch router.entryMode {
                case .dashboard:
                    DashboardView(initialRoute: nil)
                case .recents:
                    DashboardView(initialRoute: .recents)
                case .quikCapture:
                    QuikCaptureView()
                case .canvas:
                    CanvasChrome(scope: .corpus)
                case .collectionCanvas(let id):
                    CollectionView(collectionID: id)
                case .sampleCanvas:
                    // Brief U — the sample library scoped to its node set. Rendered
                    // directly via CanvasChrome (NOT CollectionView) so it never
                    // calls markCollectionUsed — the sample must not become a
                    // capture's default collection.
                    CanvasChrome(scope: .nodeIDs(store.sampleNodeIDs))
                }
            }
            // live-23 (1) — "dim content behind" (T's tuning: light 10%, dark 20%): black over the content (not the
            // panel), scaled by how far the Librarian is up, so the peek dims nothing.
            .overlay {
                let dim = LibrarianSurfaceSpec.dimAmount(dark: colorScheme == .dark) * Double(panelState.progress.peekProgress)
                if dim > 0 { Color.black.opacity(dim).ignoresSafeArea().allowsHitTesting(false) }
            }
            #if DEBUG
            // Brief CA — headless screenshot harness for the model pill; renders on top of everything.
            if ProcessInfo.processInfo.arguments.contains("-PillGallery") {
                PillGalleryView()
            }
            // live-23 — the card showcase: every synthetic case as the real card faces, for the contact sheets.
            if ProcessInfo.processInfo.arguments.contains("-CardShowcase") {
                CardShowcaseGallery()
            }
            // Brief CD1 — ghost-suggestion look options (opacity × font × light/dark + shimmer).
            if ProcessInfo.processInfo.arguments.contains("-GhostGallery") {
                GhostGalleryView()
            }
            // A3 — `-StoreProbe`: the live store's shape for an XCUITest (which can read the disk but not memory):
            // node count, unique-id count, and each node's id + committed title. Invisible, never hit-testable.
            if ProcessInfo.processInfo.arguments.contains("-StoreProbe") {
                let ids = store.nodes.map(\.id)
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("storeProbe")
                    .accessibilityLabel("nodes=\(ids.count) unique=\(Set(ids).count)")
                    .accessibilityValue(store.nodes.map { "\($0.id)=\($0.title)" }.joined(separator: "\n"))
                    .allowsHitTesting(false)
            }
            // Mac batch C1 — `-RouterProbe`: what the menu / key commands changed, for the iPad key-command UI test.
            if ProcessInfo.processInfo.arguments.contains("-RouterProbe") {
                let mode: String = {
                    switch router.entryMode {
                    case .dashboard: return "dashboard"
                    case .recents: return "recents"
                    case .canvas: return "canvas"
                    case .quikCapture: return "quikCapture"
                    case .collectionCanvas: return "collection"
                    case .sampleCanvas: return "sample"
                    }
                }()
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("routerProbe")
                    .accessibilityLabel("routerProbe")
                    .accessibilityValue("mode=\(mode) view=\(store.filterState(for: .corpus).viewMode.rawValue) depth=\(store.detailViewDepth) peek=\(router.librarianAtPeek ? 1 : 0) capturing=\(router.isCapturing ? 1 : 0) back=\(router.canGoBack ? 1 : 0) forward=\(router.canGoForward ? 1 : 0) settings=\(router.showSettings ? 1 : 0) newCollection=\(router.showNewCollection ? 1 : 0) editor=\(ActiveRichTextEditor.shared.state == nil ? 0 : 1) bold=\(ActiveRichTextEditor.shared.state?.isBold == true ? 1 : 0) heading=\(ActiveRichTextEditor.shared.state?.currentHeadingLevel?.rawValue ?? 0) bullet=\(ActiveRichTextEditor.shared.state?.isBulletList == true ? 1 : 0) checklist=\(ActiveRichTextEditor.shared.state?.isChecklist == true ? 1 : 0) inlineBarMode=\(ActiveRichTextEditor.usesInlineBar ? 1 : 0)")
                    .allowsHitTesting(false)
            }
            // live-11 (2) — `-PasteProbe`: main-thread stalls + paste → naming → ghost times for a long paste.
            if PasteProbe.enabled { PasteProbeView() }
            #endif
        }
        // Chats list sheet — shared by the Dashboard header bubble and
        // the Librarian "Chats" tile via `router.showChatsList`. Mounted
        // at the root so both entry points present the bit-identical
        // surface, and so the sheet floats over the Librarian's
        // FloatingPanel regardless of entry mode.
        // 1.0r S0 — the read-only banner on every screen, and the message for a refused capture or save.
        // Below the top chrome row (back / title / sort sit in the first ~56 pt), and taps pass through to it.
        .overlay(alignment: .top) {
            if store.libraryIsNewerFormat { NewerLibraryBanner().padding(.top, 56).allowsHitTesting(false) }
        }
        // Mac batch C3 — the note editor's formatting bar on a Mac / an iPad with a keyboard, inline under the top
        // chrome row (the iPhone's rides on the keyboard).
        .overlay(alignment: .top) {
            if let editor = ActiveRichTextEditor.shared.state {
                RichTextInlineBar(state: editor)
                    .padding(.top, 58)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: ActiveRichTextEditor.shared.state != nil)
        // Mac batch C4 — drop onto the window: new entries through the share import, or — with an entry open — added to
        // that entry. (A drop on the open note's text lands at the drop point: the editor takes it.)
        .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
            guard router.entryMode != .quikCapture else { return false }
            let target = store.isInDetailView ? router.openEntryID : nil
            Task { await store.importDrop(providers, appendTo: target) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                    .padding(4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("dropHighlight")
            }
        }
        .alert(LibraryFormatGuard.message, isPresented: Binding(
            get: { store.newerFormatNotice }, set: { store.newerFormatNotice = $0 })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $routerBinding.showChatsList) {
            ChatsListView()
                .environment(store)
                .environment(router)
                .environment(selection)
                .environment(quarantineStore)
        }
        // Mac batch C1 — File › New Collection and Settings… (menu bar / key commands).
        .sheet(isPresented: $routerBinding.showNewCollection) {
            CollectionCreationSheet { _ in }
                .environment(store)
        }
        .sheet(isPresented: $routerBinding.showSettings) {
            SettingsView()
                .environment(store)
                .environment(router)
                .environment(selection)
                .environment(quarantineStore)
        }
        .onChange(of: router.commandRequest) { _, request in
            if let command = request?.command { perform(command) }
        }
        // Mac batch C5 — an entry's right-click menu, wherever it was shown.
        .onChange(of: router.entryAction) { _, request in
            if let request { perform(request.action, on: request.nodeID) }
        }
        .sheet(item: Binding(get: { router.exportEntryID.map(ExportTarget.init) }, set: { router.exportEntryID = $0?.id })) { t in
            EntryExportSheet(nodeID: t.id)
                .environment(store)
                .environment(router)
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(
            get: { router.deleteEntryID != nil }, set: { if !$0 { router.deleteEntryID = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let id = router.deleteEntryID else { return }
                router.deleteEntryID = nil
                if store.isInDetailView, router.openEntryID == id { router.perform(.back) }
                Task { await store.deleteNode(id: id) }
            }
            Button("Cancel", role: .cancel) { router.deleteEntryID = nil }
        } message: {
            Text("This will permanently delete the entry and all its items. Can't be undone.")
        }
        // In-layout FloatingPanel — the Librarian's structural home. Mounted
        // once at ContentView root and never torn down across entry-mode
        // switches. Step C below moves it to `.tip` / `.hidden` per mode.
        // Move 1 ships dummy content; Move 2 swaps `LibrarianSurface` in.
        .floatingPanel { proxy in
            // Env objects don't cross FloatingPanel's UIHostingController
            // mount automatically, so we inject the four the surface
            // needs explicitly. `hostScope` drives the Librarian's
            // first-appear scope seed; we collapse the four entry modes
            // to corpus/collection so the surface sees a clean slice.
            // Mac batch D3 — on the Mac the Librarian is a column (`MacDesktopFrame`); the panel stays mounted, empty.
            (RunningOnMac.isMac ? nil : LibrarianSurface(
                hostScope: hostScope(for: router.entryMode),
                panelModel: panelState,
                proxy: proxy
            ))
                .environment(store)
                .environment(router)
                .environment(selection)
                .environment(quarantineStore)
                .onAppear {
                    panelState.controller = proxy.controller
                    proxy.controller.delegate = panelState
                    // FloatingPanel always draws its own grabber on the
                    // surface (`SurfaceView.grabberHandle`); the
                    // Librarian draws a styled SwiftUI Capsule in its
                    // expanded header. Hide the library's so we ship a
                    // single grabber owner (Step E carry-forward; the
                    // probe's doubled-pill artifact was the two
                    // stacking).
                    proxy.controller.surfaceView.grabberHandle.isHidden = true
                    // Clear FloatingPanel's default opaque SurfaceView fill
                    // so the Librarian's `.regularMaterial` rectangle has
                    // the canvas behind it to blur. Both layers need to go
                    // clear: `appearance.backgroundColor` paints the
                    // containerView, `backgroundColor` is the UIView itself.
                    proxy.controller.surfaceView.appearance.backgroundColor = .clear
                    proxy.controller.surfaceView.backgroundColor = .clear
                    // ws-dark-light-mode — remove FloatingPanel's default
                    // surface drop-shadow (`SurfaceAppearance.shadows =
                    // [Shadow()]`). It's invisible on the #1A1A1A dark ground
                    // but reads as a faint line at the surface's top edge on
                    // cream — the hairline above the peek pill. Not
                    // load-bearing (no visible lift in dark).
                    //
                    // ⚠️ Must REPLACE the appearance object, not mutate
                    // `appearance.shadows` in place. `SurfaceAppearance` is a
                    // class, and the `SurfaceView.appearance` didSet — the only
                    // thing that rebuilds the shadow sublayers — fires only on
                    // whole-object assignment. A nested `appearance.shadows =
                    // []` never rebuilds them, and `updateShadow()` (per
                    // layoutSubviews) only configures PRESENT shadows, never
                    // clears an already-drawn one. So reassigning the object is
                    // what actually removes it (measured from SurfaceView.swift;
                    // a prior nested-mutation attempt was a no-op). Durable
                    // across detents: the library never reassigns `appearance`,
                    // and the only other `shadowLayers` rebuild is init-only
                    // (`addSubViews`). Reassigning the SAME object still fires
                    // didSet (Swift runs it on every assignment) and preserves
                    // the `.clear` backgroundColor set above.
                    let clearedAppearance = proxy.controller.surfaceView.appearance
                    clearedAppearance.shadows = []
                    proxy.controller.surfaceView.appearance = clearedAppearance
                    // First-render alignment with the current surface.
                    // SwiftUI's `.onChange` doesn't fire for the initial
                    // value reliably across the panel-mount boundary, so
                    // align here once the controller is wired up. Routes
                    // through the same `librarianSuppressed` SSOT as every
                    // runtime transition (BUG 11).
                    applyLibrarianVisibility(animated: false)
                    #if DEBUG
                    // `-LibrarianDetent tip|half|full` — drives the panel to a
                    // detent for headless real-screen shots of the light panel
                    // (peek/half/full). No-op without the arg.
                    switch UserDefaults.standard.string(forKey: "LibrarianDetent") {
                    case "half": proxy.controller.move(to: .half, animated: false)
                    case "full": proxy.controller.move(to: .full, animated: false)
                    default:     break
                    }
                    #endif
                }
        }
        .floatingPanelLayout(panelLayout)
        // BUG 5 — snappy detent spring. Overrides the library default
        // springResponseTime (0.4, a ~1.6s critically-damped crawl half→full)
        // with a shorter response. Applies to every programmatic move and the
        // drag-release settle; morph-preserving (see LibrarianPanelBehavior).
        .floatingPanelBehavior(LibrarianPanelBehavior())
        // Content tracks each detent's bounds instead of being laid out once
        // at full height and slid down (the .static default). Under .static,
        // the surface stays full-detent-tall and translates for shorter
        // detents, dragging the content's bottom — the Ask input row + end-
        // session footer — off-screen at .half. With .fitToBounds the surface
        // is re-fit per detent (top pinned by the state constraint, bottom
        // pinned to vc.view.bottom), so the pinned bottom row stays visible
        // at every posture. Applied here at configuration time, NOT inside
        // .onAppear: setting `contentMode` after the panel mounts triggers
        // a relayout against the controller's initial state one tick before
        // our `move(to: .tip)` runs, producing a posture flash.
        .floatingPanelContentMode(.fitToBounds)
        // Single existence rule: canvas / collectionCanvas raise the panel
        // to peek; dashboard / recents duck it offscreen. Panel stays
        // mounted across all modes — never torn down. `.hidden` is not in
        // the layout's anchor set, so the duck goes through `hide()` (which
        // routes to a library-default offscreen anchor) — keeping `.tip`
        // as the hard user-facing floor for drag.
        // BUG 11 — single suppression SSOT. Both the entry-mode switch AND
        // capture mode feed `librarianSuppressed`; re-applying visibility on
        // either input change (instead of two independent imperative ducks
        // that a later raise could silently override) is what keeps the peek
        // out of every canvas-COVERING surface — QuikCapture, the ducked entry
        // modes, and capture mode alike. The FloatingPanel is a root-mounted
        // ZStack sibling that's never auto-dismissed, so this is the level
        // where all of those surfaces get suppression.
        .onChange(of: router.entryMode) { _, _ in
            applyLibrarianVisibility(animated: true)
        }
        // Capture mode (Dashboard "+"): the focused blank-node surface ducks the
        // Librarian so the note + capture buttons own the screen — folded into
        // the same SSOT so exit restores per the live surface.
        .onChange(of: router.isCapturing) { _, _ in
            applyLibrarianVisibility(animated: true)
        }
        // 1.1-C fix-up (1) — while the ≡ menu is open the faded Librarian takes no touches (position unchanged).
        .onChange(of: router.slideOutMenuOpen) { _, _ in
            applyLibrarianInteraction()
        }
        // Detail-view coexistence. ContentView's panel visibility is keyed
        // on entryMode, but a node detail is pushed inside the host
        // surface's NavigationStack without changing entryMode — so a
        // detail reached from a ducked host (Recents) would inherit the
        // ducked panel and hide the Librarian. `store.isInDetailView` is
        // a depth-derived computed bool driven by each host's
        // `path.count` observer: it flips false→true only on first-
        // detail-enter (depth 0→1) and true→false only on last-detail-
        // exit (depth 1→0). Stacked transitions (1↔2) don't reach this
        // handler — the Librarian's `openNode` half stays put.
        //
        // Enter-branch is rescue-only: raise only if the panel is
        // actually hidden. Leaves the Librarian's own choreography
        // (`openNode`'s `dropToHalf`) and any user-chosen detent alone.
        // Exit-branch fires at pop-commit (path.count → 0 lands
        // synchronously with `dismiss()` for chevron, at release for
        // swipe), so the duck animates alongside the pop without a
        // separate early-restore signal.
        // live-29 (B2) — a Chat-view citation: the Librarian's own choreography (`openNode`): a full panel drops to half,
        // then the surface pushes the entry's Detail View.
        .onChange(of: router.citedEntryToOpen) { _, id in
            guard let id else { return }
            router.citedEntryToOpen = nil
            if panelState.state == .full { panelState.dropToHalf(animated: true) }
            router.pendingNodeNavigationID = id
        }
        .onChange(of: store.isInDetailView) { _, inDetail in
            if inDetail {
                // Rescue-raise ONLY when the current surface actually wants the
                // Librarian (a canvas / collection-canvas detail). Any suppressed
                // surface — capture mode OR QuikCapture / dashboard / recents —
                // must stay ducked, so gate on the same SSOT (BUG 11). The bare
                // `!isCapturing` guard let a detail-depth flip re-raise the peek
                // over a non-canvas surface.
                if panelState.state == .hidden && !librarianSuppressed {
                    // BUG 15 — go through the visibility SSOT, not a bare
                    // raiseToPeek: entering .recents both ducked the panel AND
                    // disabled its UIKit interaction, so a raise alone would
                    // surface a NON-tappable pill. `applyLibrarianVisibility`
                    // re-enables interaction and raises (we only reach here when
                    // hidden + unsuppressed, so no user detent is overridden).
                    applyLibrarianVisibility(animated: true)
                }
            } else {
                // Leaving the detail ends capture mode (Done → Recents and a
                // plain back-out both land here).
                if router.isCapturing {
                    router.isCapturing = false
                    router.captureNodeID = nil
                }
                restorePanelForEntryMode()
            }
        }
        // Selection coexistence. When batch selection activates in
        // Map / List view, retract the panel to peek so the bottom
        // BatchActionBar (shifted up by peekDetentHeight + 12 in
        // CanvasChrome) reads as the dominant action. No restore on
        // exit — peek is the correct resting state after a batch action.
        .onChange(of: selection.isActive) { _, isActive in
            // Retract-to-peek is a canvas affordance (the BatchActionBar sits
            // above the peek). Guard on the SSOT so activating selection can
            // never raise the peek in a suppressed surface (BUG 11).
            if isActive && !librarianSuppressed {
                panelState.raiseToPeek(animated: true)
            }
        }
        // Mirror the panel detent onto the router (fix-pass v3 Item 2a)
        // so views without a direct handle on `panelState` can gate
        // themselves on peek vs raised — the "+" capture trigger in
        // CanvasView / VerticalScrollView uses this.
        // live-26 (3d): `initial` — a launch that starts at peek mirrors it too (else the floating buttons stayed hidden
        // until the panel first moved; seen in every -Open* still).
        .onChange(of: panelState.state, initial: true) { _, newState in
            router.librarianAtPeek = (newState == .tip)
            #if targetEnvironment(macCatalyst)
            router.librarianAtPeek = !MacLayout.shared.librarianOpen   // Mac batch D3 — the column, not the panel
            #endif
        }
    }

    /// BUG 11 — single source of truth for whether the Librarian peek must be
    /// ducked for the CURRENT surface. Every canvas-COVERING surface hides it:
    /// capture mode (the Dashboard "+" note editor) and the three ducked entry
    /// modes (dashboard / QuikCapture / recents). Only a plain canvas /
    /// collection-canvas shows the peek. Because the FloatingPanel is a
    /// root-mounted ZStack sibling that's never auto-dismissed, this predicate
    /// — not a scattered set of imperative ducks — is what guarantees the peek
    /// can't persist into a surface that never asked for it.
    private var librarianSuppressed: Bool {
        if router.isCapturing { return true }
        switch router.entryMode {
        case .canvas, .collectionCanvas, .sampleCanvas:
            return false
        case .quikCapture:
            return true
        case .dashboard, .recents:
            // BUG 15 — the dashboard / recents LIST surfaces suppress the peek,
            // but a node DETAIL pushed from them (depth ≥ 1) is a canvas-like
            // surface where the Librarian belongs. Keying suppression on
            // entryMode alone left a detail reached from Recents with a ducked
            // panel and no Librarian at all. Capture mode is caught above, so
            // its detail-like editor stays ducked regardless.
            return !store.isInDetailView
        }
    }

    /// Drive the panel position from `librarianSuppressed`. Called on every
    /// input change (entry mode, capture) and at first-render alignment, so the
    /// position never drifts from the visible surface. Raise-intent callers
    /// (selection retract, detail rescue) stay separate but gate on the same
    /// predicate so they can't override a suppression.
    private func applyLibrarianVisibility(animated: Bool) {
        // BUG 11 dead-zone fix. The position duck can be raced by a concurrent
        // NavigationStack push (warm Map→"+" capture), leaving the panel's UIKit
        // surfaceView physically at peek. `LibrarianSurface`'s opacity gate hides
        // it visually, but the surfaceView (and its pan recognizer) still SWALLOW
        // touches in the bottom band — the QuikCapture / capture toolbar under it
        // needs ~a dozen taps to register. A SwiftUI `.allowsHitTesting(false)`
        // can't reach that UIKit view, so make the whole panel non-interactive at
        // the controller level when suppressed: touches then fall through to the
        // surface below. Instant (not animated), so it can't be raced.
        applyLibrarianInteraction()
        #if targetEnvironment(macCatalyst)
        panelState.duck(animated: false)   // Mac batch D3 — the Librarian is the column, never the panel
        panelState.controller?.view.isUserInteractionEnabled = false
        return
        #endif
        if librarianSuppressed {
            panelState.duck(animated: animated)
        } else {
            panelState.raiseToPeek(animated: animated)
        }
    }

    /// The panel's UIKit view takes touches only when the Librarian is up AND the ≡ menu is closed. 1.1-C fix-up (1):
    /// the open menu faded the surface with SwiftUI's `.allowsHitTesting(false)`, which can't reach the panel's
    /// surfaceView (same trap as BUG 11), so the faded surface still swallowed taps on the menu's lower rows (Settings).
    private func applyLibrarianInteraction() {
        panelState.controller?.view.isUserInteractionEnabled = !librarianSuppressed && !router.slideOutMenuOpen
    }

    /// Restore panel visibility for the live surface. Shared by capture-overlay
    /// dismiss and detail-view exit; delegates to the `librarianSuppressed` SSOT.
    private func restorePanelForEntryMode() {
        applyLibrarianVisibility(animated: true)
    }

    // MARK: - Mac batch C1 — menu bar / key commands

    /// The commands ContentView owns. Find also lives in LibrarianSurface (the field), Export in the open entry, Back /
    /// Forward in the mounted NavigationStack.
    private func perform(_ command: AppCommand) {
        let busy = router.isCapturing || router.entryMode == .quikCapture
        switch command {
        case .newEntry:
            guard !busy else { return }
            // The capture "+" (CanvasChrome / Dashboard): a fresh entry, opened with its note.
            Task {
                guard let node = await store.createCaptureNode() else { return }
                router.isCapturing = true
                router.captureNodeID = node.id
                router.captureDraftHasText = false
                router.pendingNodeNavigationID = node.id
            }
        case .newCollection:
            guard router.entryMode != .quikCapture else { return }
            router.showNewCollection = true
        case .viewMap:   if !busy { showLibraryView(.systemGraph) }
        case .viewList:  if !busy { showLibraryView(.list) }
        case .viewCards: if !busy { showLibraryView(.grid) }
        case .today:
            guard !busy else { return }
            if router.entryMode != .dashboard { router.entryMode = .dashboard }   // on the Dashboard, it pops to its top
        case .settings:
            router.showSettings = true
        case .librarian:
            #if targetEnvironment(macCatalyst)
            // Mac batch D3 — ⌘L opens / closes the Librarian column, anywhere.
            MacLayout.shared.librarianOpen.toggle()
            router.librarianAtPeek = !MacLayout.shared.librarianOpen
            return
            #endif
            guard !busy else { return }
            if librarianSuppressed {
                // The Dashboard / Recents put the Librarian away; it lives over the library.
                router.entryMode = .canvas
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { panelState.expandToHalf(animated: true) }
            } else if panelState.state == .tip || panelState.state == .hidden {
                panelState.expandToHalf(animated: true)
            } else {
                panelState.raiseToPeek(animated: true)
            }
        case .find:
            #if targetEnvironment(macCatalyst)
            MacLayout.shared.librarianOpen = true   // Mac batch D — the search lives in the toolbar; results in the column
            router.librarianAtPeek = false
            return
            #endif
            guard !busy, librarianSuppressed else { return }   // with the Librarian up, LibrarianSurface focuses it
            router.entryMode = .canvas
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !librarianSuppressed { router.perform(.find) } }
        case .closeWindow:
            #if targetEnvironment(macCatalyst)
            RunningOnMac.closeFrontWindow()   // one window for now; the same as its close button
            #endif
        case .export, .back, .forward, .zoomIn, .zoomOut, .zoomFit, .editMap:
            break
        }
    }

    /// Mac batch C5 — the entry menu's actions, the same paths as the open entry's own menu.
    private func perform(_ action: EntryAction, on nodeID: String) {
        switch action {
        case .open:
            if router.entryMode == .quikCapture { return }
            router.pendingNodeNavigationID = nodeID
        case .togglePrivate:
            guard PrivateEntries.shared.available, var updated = store.nodes.first(where: { $0.id == nodeID }) else { return }
            updated.isPrivate.toggle()
            Task { await store.updateNode(updated) }
        case .export:
            router.exportEntryID = nodeID
        case .delete:
            router.deleteEntryID = nodeID
        }
    }

    private struct ExportTarget: Identifiable { let id: String }

    /// View › Map / List / Cards: that view of the library being looked at (a collection stays that collection), with
    /// any open entry closed so the view shows.
    private func showLibraryView(_ mode: ViewMode) {
        let scope: CanvasScope
        switch router.entryMode {
        case .collectionCanvas(let id): scope = .collection(id)
        case .sampleCanvas:             scope = .nodeIDs(store.sampleNodeIDs)
        case .canvas:                   scope = .corpus
        case .dashboard, .recents, .quikCapture:
            scope = .corpus
            router.entryMode = .canvas
        }
        var s = store.filterState(for: scope)
        if s.viewMode != mode {
            s.viewMode = mode
            store.setFilterState(s, for: scope)
        }
        router.requestDismissDetail()
    }

    /// Collapse the entry modes to a Librarian scope.
    /// `canvas` and the two ducked modes (dashboard/recents) show
    /// the whole-corpus slice; only an explicit collection canvas
    /// scopes the Librarian to that collection. The Librarian reads
    /// this on first appear in a new host and seeds
    /// `LibrarianState.selectedScope` so search/Ask default to the
    /// slice the user is already looking at.
    /// Mac batch D — the entry-mode content inside the desktop frame (sidebar | content | Librarian); elsewhere as is.
    @ViewBuilder private func macDesktop<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        #if targetEnvironment(macCatalyst)
        MacDesktopFrame(hostScope: hostScope(for: router.entryMode)) { content() }
        #else
        Group { content() }
        #endif
    }

    private func hostScope(for mode: AppRouter.EntryMode) -> CanvasScope {
        switch mode {
        case .collectionCanvas(let id):
            return .collection(id)
        // Brief W2 — scope follows the room: the Librarian opened FROM the sample
        // canvas is scoped to the sample's nodes, so Ask answers from the sample and
        // the scope chip reads "Sample library" (scopeDisplayName arm, Brief U).
        case .sampleCanvas:
            return .nodeIDs(store.sampleNodeIDs)
        case .canvas, .dashboard, .quikCapture, .recents:
            return .corpus
        }
    }
}
