import SwiftUI

struct SettingsView: View {

    /// Brief AF3 / AJ — a submenu Settings can open PUSHED-to on appear. `.webSearch`
    /// = the Librarian's no-Brave-key notice; `.models` = the model chip's "Manage
    /// models". (AJ2: the deep link now PUSHES the submenu, it no longer scrolls.)
    enum Anchor: Hashable { case webSearch, models }

    /// Brief AM3 — a value-identified presentation, so hosts present via `.sheet(item:)`
    /// instead of a `.sheet(isPresented:) { SettingsView(initialAnchor: separateState) }`
    /// pair. That pair DESYNCED: the separate anchor `@State` read `nil` when the sheet
    /// content closure evaluated, so the model-chip deep link landed on the Settings ROOT
    /// (reproduced by `ManageModelsRepro`). `.sheet(item:)` hands the closure the exact
    /// presented value, so the anchor can't be lost.
    struct Presentation: Identifiable {
        let anchor: Anchor?
        var id: String { anchor.map { "\($0)" } ?? "root" }
        static let root = Presentation(anchor: nil)
        static func at(_ anchor: Anchor) -> Presentation { Presentation(anchor: anchor) }
    }

    /// Which submenu to push on open (nil = the top-level list). Default keeps every
    /// existing `SettingsView()` call site unchanged.
    var initialAnchor: Anchor? = nil

    /// Brief AJ1 — the submenu destinations (iOS-Settings-style navigation).
    enum Dest: Hashable {
        case library, tags, models, webSearch, librarian, appearance, privacy, about
        case macModels, advanced   // nested under Models
        #if DEBUG
        case developer
        #endif
    }

    @State private var path: [Dest] = []

    #if DEBUG
    /// Screenshot harness only (`-Screen settings-<dest>`): pushes a submenu on open so
    /// each screen can be captured headlessly. Never set in production.
    var debugInitialDest: Dest? = nil
    #endif

    /// Brief AM3 — SEED the navigation path in `init`, so the `NavigationStack` is BORN at
    /// its destination. The build-M fix assigned `path` in `.onAppear`, which is unreliable
    /// when Settings is presented from the model-picker's `onDismiss` (a sheet-over-sheet
    /// sequence): the deep link landed on the Settings ROOT (reproduced by `ManageModelsRepro`).
    /// Seeding at birth removes the timing dependency entirely.
    init(initialAnchor: Anchor? = nil) {
        self.initialAnchor = initialAnchor
        _path = State(initialValue: Self.seededPath(anchor: initialAnchor))
    }
    #if DEBUG
    init(debugInitialDest: Dest?) {
        self.debugInitialDest = debugInitialDest
        _path = State(initialValue: debugInitialDest.map { [$0] } ?? [])
    }
    #endif

    /// The initial `path` for a deep-link anchor. `.models` lands on the paired Mac screen
    /// when a Host is paired (`HostCatalog.shared.isPaired`, primed off-render before Settings
    /// opens), else on Models.
    private static func seededPath(anchor: Anchor?) -> [Dest] {
        switch anchor {
        case .webSearch: return [.webSearch]
        case .models:    return HostCatalog.shared.isPaired ? [.models, .macModels] : [.models]
        case .none:      return []
        }
    }

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Frontier API keys (loaded from Keychain on appear)
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var deepSeekKey = ""
    @State private var braveSearchKey = ""
    @State private var ollamaEndpoint = ""
    // Optional bearer token sent as `Authorization: Bearer <token>` on every request to
    // the endpoint above. Empty = today's behavior (no auth header). Needed for the
    // AirPad Bridge/Host (the Host requires the QR-derived bearer) and any authed proxy.
    @State private var ollamaAPIToken = ""

    // Brief AT5 — Appearance override (shared with the ≡ menu).
    @AppStorage(AppearanceOverride.storageKey) private var appearanceRaw = AppearanceOverride.system.rawValue
    // Brief AZ4 — the app-wide "Default font" for entry body text (shared with the note
    // toolbar's font chip via the SAME @AppStorage key). New entries + entries with no
    // per-entry override follow it.
    @AppStorage(EntryBodyFont.defaultStorageKey) private var defaultBodyFontRaw = EntryBodyFont.fallback.rawValue
    // Privacy
    @AppStorage("locationEnabled") private var locationEnabled = false

    // SB126 Stage 2 — bound to the same key FeatureFlags.useCorpusAwareTagging reads.
    @AppStorage("ff.useCorpusAwareTagging") private var useCorpusAwareTagging = false
    // ★ Brief J §2 — one-shot "Copy all tuner state" result (keys copied), TEMP.
    @State private var tunerExportStatus = ""

    // Librarian c7 — standing system-prompt prefix injected on every Librarian
    // query. Same key LibrarianState reads, so edits here take effect on the
    // next Ask without app restart.
    @AppStorage("librarianPersonalPrompt") private var librarianPersonalPrompt = ""

    private static let librarianPersonalPromptMaxChars = 300
    private static let librarianPersonalPromptPlaceholder =
        "Ex: Be direct and honest. I'm a creative professional who thinks in systems. Connect insights to my work and don't shy away from uncomfortable observations."

    // UI state
    @State private var connectionTestResult: String? = nil
    @State private var isTestingConnection = false
    @State private var showTagEditor = false
    @State private var editingTag: Tag? = nil
    /// Brief AJ — Manage Tags search field.
    @State private var tagSearch = ""
    /// Brief K — Manage Tags CRUD (room-scoped, corpus-mutating).
    @State private var tagPendingDelete: Tag? = nil
    @State private var tagRenaming: Tag? = nil
    @State private var tagRenameText = ""
    /// Brief K addendum — Manage Tags multi-select batch delete (Edit → select → Delete N).
    @State private var tagSelection = Set<UUID>()
    @State private var showBatchTagDelete = false
    // Stage 4 — desktop Host pairing. `hostPairing` is cached (Keychain read is XPC-backed;
    // never read HostPairing.load() from `body`); refreshed on appear + after the sheet closes.
    @State private var showPairingQR = false
    @State private var hostPairing: HostPairing? = nil
    @State private var showImportIdeas = false
    @State private var showReviewQueue = false
    @State private var showClearConfirmation = false
    @State private var showRemoveSampleConfirmation = false

    // Local on-device model (ws-local-model Stage 1). Settings surface + plumbing only —
    // this does NOT change any generation path yet (AIService / ModelRouter untouched).
    @State private var localModel = LocalModelService.shared
    /// ws-local-model Stage 2 — the opt-in that moves the note-enrichment lever to the
    /// on-device model. FM stays the default; ModelRouter.structuredProvider() reads this
    /// key AND requires `.ready`, so toggling it on only takes effect while the model is
    /// downloaded (configured-but-absent falls back to FM). Shown ONLY in the `.ready` state.
    @AppStorage(ModelRouter.useLocalEnrichmentKey) private var useLocalEnrichment = false
    @State private var isTestingLocal = false
    @State private var localTestOutput = ""
    // AC2 — "Copy Librarian log" confirmation flash.
    @State private var librarianLogCopied = false
    /// Brief AG3 — "Reset first-time tips" confirmation flash.
    @State private var tipsReset = false
    #if DEBUG
    // Dev diagnostics — SubstrateInspectView carries a DESTRUCTIVE "Reset cluster
    // registry"; it must not be reachable in a shipping build. DEBUG-gated
    // (state + gesture + sheet all gated).
    @State private var showSubstrateInspect = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Group 1 — the library and its labels.
                Section {
                    settingsRow(.library,  icon: "books.vertical.fill",       tint: "1B59C2", title: "Library")
                    settingsRow(.tags,     icon: "tag.fill",                   tint: "E8820A", title: "Tags")
                }
                // Group 2 — who answers and how.
                Section {
                    settingsRow(.models,   icon: "cpu",                        tint: "7A3FF2", title: "Models")
                    settingsRow(.webSearch,icon: "magnifyingglass",            tint: "2E9E4F", title: "Web search")
                    settingsRow(.librarian,icon: "character.book.closed.fill", tint: "C2571B", title: "Librarian")
                }
                // Brief AZ4 — Appearance is now a submenu (Theme + Default font), so the
                // app-wide light/dark override and the default entry font live together.
                Section {
                    settingsRow(.appearance, icon: "circle.righthalf.filled", tint: "5E5CE6", title: "Appearance")
                }
                // Group 3 — privacy and about.
                Section {
                    settingsRow(.privacy,  icon: "lock.fill",                  tint: "3A8DDE", title: "Privacy")
                    settingsRow(.about,    icon: "info.circle.fill",           tint: "8A8A8E", title: "About")
                }
                #if DEBUG
                Section {
                    settingsRow(.developer, icon: "hammer.fill",              tint: "8A8A8E", title: "Developer")
                }
                #endif
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: Dest.self) { submenu(for: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveKeys()
                        dismiss()
                    }
                    .foregroundStyle(AppearancePalette.ink)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationBackground(AppearancePalette.bgBase)
        .onAppear {
            loadKeys()
            // Brief AL1 — pairing state is the shared observable `HostCatalog.shared.isPaired`
            // (the SAME source the Librarian reads), refreshed off-render here so Settings and
            // the Librarian can never disagree. `hostPairing` is kept only for the display
            // name / Unpair / sheets. (AM3: the deep-link `path` is now SEEDED in `init`, not
            // pushed here — the onAppear push was unreliable through the picker's onDismiss.)
            HostCatalog.shared.refreshPaired()
        }
    }

    // MARK: - Brief AJ1 — top-level rows + submenu routing

    /// One iOS-Settings-style row: a tinted rounded-square SF Symbol tile + label +
    /// chevron. Tint is decoration (T ruled): the symbol + label carry the meaning.
    private func settingsRow(_ dest: Dest, icon: String, tint: String, title: String) -> some View {
        NavigationLink(value: dest) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(hexString: tint))
                    .frame(width: 29, height: 29)
                    .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                Text(title).font(.body).foregroundStyle(AppearancePalette.ink)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(AppearancePalette.ink.opacity(0.04))
    }

    @ViewBuilder
    private func submenu(for dest: Dest) -> some View {
        switch dest {
        case .library:   librarySubmenu
        case .tags:      tagsSubmenu
        case .models:    modelsSubmenu
        case .macModels: macModelsSubmenu
        case .advanced:  advancedSubmenu
        case .webSearch: webSearchSubmenu
        case .librarian: librarianSubmenu
        case .appearance: appearanceSubmenu
        case .privacy:   privacySubmenu
        case .about:     aboutSubmenu
        #if DEBUG
        case .developer: submenuScroll { developerSection }
        #endif
        }
    }

    /// A submenu screen: header card (icon, title, one sentence) + content, on the
    /// standard Settings ground. Reused by every submenu (Brief AJ1).
    @ViewBuilder
    private func submenuScroll<Content: View>(header: (() -> AnyView)? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let header { header() }
                content()
            }
            .padding(20)
            .dismissKeyboardOnTapOutside()
        }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iOS-General-style header card: a big tinted tile + title + one sentence.
    private func submenuHeader(icon: String, tint: String, title: String, blurb: String) -> AnyView {
        AnyView(
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hexString: tint))
                    .frame(width: 60, height: 60)
                    .overlay(Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white))
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(AppearancePalette.ink)
                Text(blurb)
                    .font(.subheadline)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        )
    }

    // MARK: - Brief AJ — submenu screens (reuse the existing controls; only their home changes)

    /// Thinking default for the paired Mac (the Mac-screen toggle). Persisted; seeding
    /// new Librarian sessions from it is a follow-up.
    @AppStorage("hostThinkingDefault") private var hostThinkingDefault = false

    private var librarySubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "books.vertical.fill", tint: "1B59C2", title: "Library",
            blurb: "Everything you've saved, and the ways to bring more in or take it out.") }) {
            corpusSection      // counts · search index + rebuild · export · clear · sample add/remove
            importSection      // "each paragraph becomes an entry"
            reviewSection      // Needs review (import review queue)
        }
    }

    /// Brief K — Manage Tags CRUD. A `List` (native swipe + context menu). Room-SEALED:
    /// sample-only tags never appear; counts + delete/rename act on the USER room only.
    private var tagsSubmenu: some View {
        List(selection: $tagSelection) {
            Section {
                submenuHeader(icon: "tag.fill", tint: "E8820A", title: "Tags",
                              blurb: "Tags label entries. Pinned tags form territories on the Map.")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if manageTagRows.isEmpty {
                Text(tagSearch.isEmpty ? "No tags yet — AI will suggest them as you capture entries." : "No tags match.")
                    .font(.callout).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    .listRowBackground(AppearancePalette.ink.opacity(0.04))
            } else {
                Section("\(manageTagRows.count) \(manageTagRows.count == 1 ? "tag" : "tags")") {
                    ForEach(manageTagRows, id: \.tag.id) { row in
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: row.tag.colorHex) ?? .gray).frame(width: 11, height: 11)
                            Text(row.tag.name).foregroundStyle(AppearancePalette.ink)
                            if row.tag.isCanvasAnchor {
                                Image(systemName: "map.fill").font(.system(size: 10)).foregroundStyle(AppearancePalette.ink.opacity(0.3))
                            }
                            Spacer()
                            Text("\(row.count)").monospacedDigit().foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        }
                        .listRowBackground(AppearancePalette.ink.opacity(0.04))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { tagPendingDelete = row.tag } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { tagRenaming = row.tag; tagRenameText = row.tag.name } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { tagPendingDelete = row.tag } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $tagSearch, prompt: "Search tags")
        .confirmationDialog(tagDeleteTitle(tagPendingDelete),
                            isPresented: Binding(get: { tagPendingDelete != nil }, set: { if !$0 { tagPendingDelete = nil } }),
                            titleVisibility: .visible, presenting: tagPendingDelete) { tag in
            Button("Remove", role: .destructive) { Task { await store.deleteTagInUserRoom(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { tag in
            if tag.isCanvasAnchor { Text("Its territory on the Map will dissolve.") }
        }
        .alert("Rename tag", isPresented: Binding(get: { tagRenaming != nil }, set: { if !$0 { tagRenaming = nil } })) {
            TextField("Tag name", text: $tagRenameText).autocorrectionDisabled()
            Button("Rename") { if let t = tagRenaming { Task { await store.renameTagInUserRoom(t, to: tagRenameText) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames it on your entries and keeps its colour. The Sample Library keeps the old name.")
        }
        // Brief K addendum — Edit → multi-select → Delete (N), one confirmation with totals.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { if !manageTagRows.isEmpty { EditButton() } }
            ToolbarItem(placement: .bottomBar) {
                if !tagSelection.isEmpty {
                    Button("Delete (\(tagSelection.count))", role: .destructive) { showBatchTagDelete = true }
                }
            }
        }
        .confirmationDialog(batchTagDeleteTitle, isPresented: $showBatchTagDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let selected = store.tags.filter { tagSelection.contains($0.id) }
                Task { await store.deleteTagsInUserRoom(selected); tagSelection.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The delete-confirmation title names the cost (Brief K rule 1): the user-room count.
    private func tagDeleteTitle(_ tag: Tag?) -> String {
        guard let tag else { return "Remove tag?" }
        let n = store.userNodeCount(forTag: tag.name)
        return "Remove \u{201C}\(tag.name)\u{201D} from \(n) \(n == 1 ? "entry" : "entries")?"
    }

    /// Batch-delete confirmation names the TOTALS: N tags across M user entries (an entry
    /// carrying several selected tags counts once).
    private var batchTagDeleteTitle: String {
        let names = Set(store.tags.filter { tagSelection.contains($0.id) }.map(\.name))
        let entries = store.userNodes.filter { n in names.contains { n.tags.contains($0) } }.count
        return "Remove \(names.count) \(names.count == 1 ? "tag" : "tags") from \(entries) \(entries == 1 ? "entry" : "entries")?"
    }

    private var modelsSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "cpu", tint: "7A3FF2", title: "Models",
            blurb: "Choose who answers. Apple Intelligence works right away — everything here is optional.") }) {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("On this iPhone")
                appleIntelligenceRow
                localModelSubsection   // "Downloaded model"
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("On your Mac")
                macRow
            }
            NavigationLink(value: Dest.advanced) {
                HStack {
                    Text("Advanced").font(.subheadline.weight(.medium)).foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.3))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(AppearancePalette.ink.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        // Brief AL1 — refresh the shared pairing observable + the local name off-render when
        // the Models screen appears (covers the deep-link push, where the root `onAppear`
        // may not have committed `hostPairing` before this destination first resolved).
        .onAppear {
            HostCatalog.shared.refreshPaired()
            if hostPairing == nil { hostPairing = HostPairing.load() }
        }
        .sheet(isPresented: $showPairingQR, onDismiss: {
            hostPairing = HostPairing.load()
            HostCatalog.shared.refreshPaired()
        }) {
            HostPairingSheet()
        }
    }

    /// Apple Intelligence — built in, always available. Colourblind-safe (icon + text).
    private var appleIntelligenceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo").font(.system(size: 16)).foregroundStyle(AppearancePalette.ink.opacity(0.8)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence").font(.subheadline.weight(.semibold)).foregroundStyle(AppearancePalette.ink)
                Text("Built in, ready. The default.").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
        }
        .padding(14).background(AppearancePalette.ink.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// One "On your Mac" row: unpaired → Host setup (QR); paired → push the Mac screen.
    /// Brief AL1 — the branch reads `HostCatalog.shared.isPaired` (the shared observable,
    /// refreshed off-render), NOT the per-view `@State hostPairing`. The old code branched
    /// on `hostPairing == nil`, which a deep-linked / pushed destination could resolve
    /// against a stale-nil snapshot before `loadKeys()` committed — so Settings showed
    /// "unpaired" while the Librarian (reading the same observable) showed paired.
    /// `hostPairing` is still used for the display NAME + the Mac-models screen + Unpair.
    @ViewBuilder private var macRow: some View {
        if HostCatalog.shared.isPaired {
            NavigationLink(value: Dest.macModels) {
                macRowLabel(icon: "checkmark.seal.fill", text: HostCatalog.shared.pairing?.displayHost ?? hostPairing?.displayHost ?? "Your Mac", chevron: true, green: true)
            }.buttonStyle(.plain)
        } else {
            Button { showPairingQR = true } label: {
                macRowLabel(icon: "qrcode", text: "Connect your Mac", chevron: true)
            }.buttonStyle(.plain)
            Text("Use models running on your own Mac, from anywhere — end-to-end encrypted.")
                .font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    private func macRowLabel(icon: String, text: String, chevron: Bool, green: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(green ? .green : AppearancePalette.ink.opacity(0.8))
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(AppearancePalette.ink.opacity(0.85))
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.3)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(AppearancePalette.ink.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Settings → Models → your Mac: the FULL model-management surface (reuses
    /// ModelPickerSheet with `fullControls: true`), plus Unpair (Brief AJ3).
    private var macModelsSubmenu: some View {
        ModelPickerSheet(
            catalog: HostCatalog.shared,
            thinkEnabled: $hostThinkingDefault,
            fullControls: true,
            macName: HostCatalog.shared.pairing?.displayHost ?? hostPairing?.displayHost,
            onUnpair: {
                HostPairing.clear()
                hostPairing = nil
                HostCatalog.shared.refreshPaired()
                if !path.isEmpty { path.removeLast() }
            }
        )
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var advancedSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "slider.horizontal.3", tint: "8A8A8E", title: "Advanced",
            blurb: "Connect a model server on your network, like Ollama or LM Studio.") }) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama / LM Studio endpoint").font(.caption.weight(.semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    TextField("http://192.168.x.x:11434", text: $ollamaEndpoint)
                        .font(.subheadline).foregroundStyle(AppearancePalette.ink).tint(AppearancePalette.ink)
                        .padding(12).background(AppearancePalette.ink.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                apiKeyField(label: "API token (optional)", placeholder: "Bearer token — leave empty for none", text: $ollamaAPIToken)
                HStack {
                    Button { testConnection() } label: {
                        HStack(spacing: 6) {
                            if isTestingConnection { ProgressView().tint(AppearancePalette.ink).scaleEffect(0.7) }
                            Text(isTestingConnection ? "Testing…" : "Test connection").font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75)).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(AppearancePalette.ink.opacity(0.09)).clipShape(Capsule())
                    }.buttonStyle(.plain).disabled(isTestingConnection)
                    if let result = connectionTestResult {
                        Text(result).font(.caption).foregroundStyle(connectionResultColor(result))
                    }
                    Spacer()
                }
                // Brief AJ5 — cloud (frontier) providers ONLY when the flag is on (DEBUG).
                // In Release these fields never render; their Keychain entries are untouched.
                if FeatureFlags.cloudProviders {
                    Divider().overlay(AppearancePalette.ink.opacity(0.1)).padding(.vertical, 4)
                    Text("Cloud providers (developer)").font(.caption.weight(.semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    apiKeyField(label: "Anthropic API key", placeholder: "sk-ant-...", text: $anthropicKey)
                    apiKeyField(label: "OpenAI API key", placeholder: "sk-...", text: $openAIKey)
                    apiKeyField(label: "DeepSeek API key", placeholder: "sk-...", text: $deepSeekKey)
                }
            }
        }
    }

    private var webSearchSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "magnifyingglass", tint: "2E9E4F", title: "Web search",
            blurb: "Lets the Librarian look things up in General mode.") }) {
            VStack(alignment: .leading, spacing: 6) {
                apiKeyField(label: "Brave Search API key", placeholder: "BSA...", text: $braveSearchKey)
                Text("Web search uses Brave's Search API. Brave gives a monthly credit that covers normal use, but needs an account with a card on file. Paste your key here.")
                    .font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                Link("Get a Brave Search API key", destination: URL(string: "https://brave.com/search/api/")!)
                    .font(.caption.weight(.semibold)).tint(Color(hexString: "E8820A"))
            }
        }
    }

    private var librarianSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "character.book.closed.fill", tint: "C2571B", title: "Librarian",
            blurb: "How the Librarian talks to you.") }) {
            personalPromptField
            resetTipsButton
            librarianLogRow
        }
    }

    /// Brief AZ4 — Appearance submenu: the app-wide Theme override (System / Light /
    /// Dark, shared with the ≡ menu via `AppearanceOverride.storageKey`) + the "Default
    /// font" for entry body text (shared with the note toolbar chip via
    /// `EntryBodyFont.defaultStorageKey`).
    private var appearanceSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "circle.righthalf.filled", tint: "5E5CE6", title: "Appearance",
            blurb: "How AirPad looks, and the default font for your entries.") }) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme").font(.subheadline.weight(.semibold)).foregroundStyle(AppearancePalette.ink)
                    Picker("Theme", selection: Binding(
                        get: { AppearanceOverride(rawValue: appearanceRaw) ?? .system },
                        set: { appearanceRaw = $0.rawValue }
                    )) {
                        ForEach(AppearanceOverride.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Default font").font(.subheadline.weight(.medium)).foregroundStyle(AppearancePalette.ink)
                        Spacer()
                        Picker("Default font", selection: Binding(
                            get: { EntryBodyFont(rawValue: defaultBodyFontRaw) ?? .fallback },
                            set: { defaultBodyFontRaw = $0.rawValue }
                        )) {
                            ForEach(EntryBodyFont.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(AppearancePalette.ink)
                    }
                    Text("New entries use this. An entry can still pick its own font from the editor toolbar.")
                        .font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }
        }
    }

    private var privacySubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "lock.fill", tint: "3A8DDE", title: "Privacy",
            blurb: "Your library stays on your phone.") }) {
            Toggle(isOn: $locationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPS location on capture").font(.subheadline.weight(.medium)).foregroundStyle(AppearancePalette.ink)
                    Text("Attaches your location to newly captured entries").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }.tint(.purple)
            if !hasAnyFrontierKey {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green.opacity(0.8))
                    Text("Your data never leaves this device").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                }
            }
        }
    }

    private var aboutSubmenu: some View {
        submenuScroll(header: { submenuHeader(icon: "info.circle.fill", tint: "8A8A8E", title: "About",
            blurb: "It works around you. Not the other way around.") }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("AirPad").font(.subheadline.weight(.semibold)).foregroundStyle(AppearancePalette.ink)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    Text("Version \(version) (\(build))").font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.25))
                }
            }
        }
    }

    /// Brief AG3 — moved to the Librarian submenu (Brief AJ2). Brings back every callout.
    private var resetTipsButton: some View {
        Button {
            FirstRunCalloutKey.resetAll()
            tipsReset = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { tipsReset = false }
        } label: {
            HStack {
                Image(systemName: tipsReset ? "checkmark" : "lightbulb")
                Text(tipsReset ? "First-time tips will show again" : "Reset first-time tips").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(AppearancePalette.ink.opacity(0.75)).padding(.horizontal, 16).padding(.vertical, 10)
            .background(AppearancePalette.ink.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    /// Brief AJ (build J) — READ-ONLY Manage Tags: sorted by use, trailing count, search,
    /// "N tags" header. NO delete/rename (that would orphan tags today; the full CRUD +
    /// per-room seal land in build K). Derived from the global vocabulary.
    /// Brief K — the user-room tag rows: SEALED (sample-only tags never appear), counted
    /// by USER coverage, sorted by use (then alphabetical), filtered by the search field.
    private var manageTagRows: [(tag: Tag, count: Int)] {
        store.tags.compactMap { t -> (tag: Tag, count: Int)? in
            let count = store.userNodeCount(forTag: t.name)
            let sampleOnly = count == 0 && store.nodes.contains { store.isSample($0.id) && $0.tags.contains(t.name) }
            guard !sampleOnly else { return nil }   // rule 3: sample-only tags never show in the user room
            return (t, count)
        }
        .filter { tagSearch.isEmpty || $0.tag.name.localizedCaseInsensitiveContains(tagSearch) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.name.lowercased() < $1.tag.name.lowercased() }
    }

    // MARK: - AI Model

    private var aiModelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("AI Model")

            currentModelRow

            VStack(alignment: .leading, spacing: 12) {
                apiKeyField(label: "Anthropic API key", placeholder: "sk-ant-...", text: $anthropicKey)
                apiKeyField(label: "OpenAI API key", placeholder: "sk-...", text: $openAIKey)
                apiKeyField(label: "DeepSeek API key", placeholder: "sk-...", text: $deepSeekKey)
                // Web search backend (private-mode tool loop). Web search REQUIRES a Brave
                // key: with one, the Brave Search API is used; without one, web search is
                // unavailable (no keyless fallback). Same BYO-key model as the frontier
                // providers above and the Ollama endpoint below.
                // Brief AF3 — carries the "what Brave is / why a card" copy + a signup
                // link, and `.id(Anchor.webSearch)` so the Librarian no-key notice can
                // open Settings scrolled here.
                VStack(alignment: .leading, spacing: 6) {
                    apiKeyField(label: "Brave Search API key", placeholder: "BSA...", text: $braveSearchKey)
                    Text("Web search uses Brave's Search API. Brave gives a monthly credit that covers normal use, but needs an account with a card on file. Paste your key here.")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    Link("Get a Brave Search API key", destination: URL(string: "https://brave.com/search/api/")!)
                        .font(.caption.weight(.semibold))
                        .tint(Color(hexString: "E8820A"))
                }
                .id(Anchor.webSearch)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama / LM Studio endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    TextField("http://192.168.x.x:11434", text: $ollamaEndpoint)
                        .font(.subheadline)
                        .foregroundStyle(AppearancePalette.ink)
                        .tint(AppearancePalette.ink)
                        .padding(12)
                        .background(AppearancePalette.ink.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                // Optional bearer token for the endpoint above. Empty = no auth header
                // (today's behavior). Sent as `Authorization: Bearer <token>` on every
                // request; required by the AirPad Bridge/Host and any authed proxy.
                apiKeyField(label: "API token (optional)",
                            placeholder: "Bearer token — leave empty for none",
                            text: $ollamaAPIToken)
            }

            HStack {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView().tint(AppearancePalette.ink).scaleEffect(0.7)
                        }
                        Text(isTestingConnection ? "Testing…" : "Test connection")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(AppearancePalette.ink.opacity(0.09))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                // Enabled even with an empty endpoint — the tap must always produce a visible,
                // honest response (empty → guidance; reachable/unreachable → result). Gating it on
                // a key made it a dead control for a reviewer with nothing configured (the 2.1 case).
                .disabled(isTestingConnection)

                if let result = connectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(connectionResultColor(result))
                }
                Spacer()
            }

            personalPromptField

            librarianLogRow

            localModelSubsection

            hostPairingRow
        }
        .sheet(isPresented: $showPairingQR, onDismiss: { hostPairing = HostPairing.load() }) {
            HostPairingSheet()
        }
    }

    // MARK: - Brief AC2 — Copy Librarian log (device diagnosis, no Mac needed)
    /// Puts the last 10 corpus-Ask S5 records (scope · empty · shape · per-candidate
    /// rows) on the clipboard. os_log isn't readable on TestFlight, so this is the
    /// on-device channel for "a Librarian answer looked wrong — what did retrieval do?"
    private var librarianLogRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let log = LibrarianState.recentCandidateLog
                UIPasteboard.general.string = log.isEmpty
                    ? "(no Librarian Library-mode turns yet this session)"
                    : log.joined(separator: "\n\n")
                librarianLogCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { librarianLogCopied = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: librarianLogCopied ? "checkmark" : "doc.on.clipboard")
                    Text(librarianLogCopied ? "Copied" : "Copy Librarian log")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(AppearancePalette.ink.opacity(0.09))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Text("The last 10 Library-mode retrievals (scope, whether empty, shape, candidate rows). Paste it when a Librarian answer looks wrong.")
                .font(.caption2)
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    // MARK: - Connect to your computer (Stage 4: pair with the desktop Host over the tunnel)
    private var hostPairingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(AppearancePalette.ink.opacity(0.1))
            Text("Connect to your computer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            Button { showPairingQR = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: hostPairing == nil ? "qrcode" : "checkmark.seal.fill")
                        .foregroundStyle(hostPairing == nil ? AppearancePalette.ink.opacity(0.8) : .green)
                    Text(hostPairing == nil ? "Pair with your desktop model" : "Paired — \(hostPairing!.displayHost)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.3))
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Text("Reach a private model running on your own Mac, from anywhere — end-to-end encrypted.")
                .font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    // MARK: - Local on-device model (Stage 1: download + status only; NOT wired to generation)

    private var localModelSubsection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(AppearancePalette.ink.opacity(0.1))
            Text("Downloaded model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            // Brief AJ3 — copy states its real job TODAY (bake-off may change it later).
            Text("An optional model you download to run entirely on your phone. Writes titles, summaries and tags on your phone. The Librarian doesn't use it.")
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.55))

            if !localModel.isAvailable {
                localStatusRow(symbol: "xmark.octagon", text: "Not available on this device")
            } else {
                switch localModel.state {
                case .notDownloaded:
                    Text("Download \(localModel.modelDisplayName) · \(localModel.downloadSizeLabel). Use Wi-Fi — this is a large download.")
                        .font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    localCapsuleButton("Download model", symbol: "arrow.down.circle") { localModel.download() }
                case .downloading(let p):
                    VStack(alignment: .leading, spacing: 6) {
                        localStatusRow(symbol: "arrow.down.circle.dotted", text: "Downloading… \(Int(p * 100))%")
                        ProgressView(value: p).tint(AppearancePalette.ink)
                        localCapsuleButton("Cancel", symbol: "xmark") { localModel.cancelDownload() }
                    }
                case .paused(let p):
                    // ws-bg-download — honest "waiting" state, NOT a frozen "Downloading X%" (BUG 35 §7).
                    // The transfer keeps running in the background and resumes on its own.
                    VStack(alignment: .leading, spacing: 6) {
                        localStatusRow(symbol: "pause.circle", text: "Paused — waiting for a connection… \(Int(p * 100))%")
                        ProgressView(value: p).tint(AppearancePalette.ink.opacity(0.6))
                        localCapsuleButton("Cancel", symbol: "xmark") { localModel.cancelDownload() }
                    }
                case .ready:
                    localStatusRow(symbol: "checkmark.circle", text: "Downloaded & ready")
                    // ws-local-model Stage 2 — the real opt-in. FM is the default; this only
                    // moves the note-enrichment lever. Toggle position (not colour) carries the
                    // state, and the caption stays honest in both settings (T is colorblind).
                    Toggle(isOn: $useLocalEnrichment) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use for entry enrichment")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                            Text(useLocalEnrichment
                                 ? "New entry titles, summaries, and tags use the downloaded model."
                                 : "Apple Intelligence is still doing the thinking. Turn on to use the downloaded model.")
                                .font(.caption2)
                                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color(hexString: "1B59C2"))
                    Text("Not backed up to iCloud. You can download it again anytime.")
                        .font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    localCapsuleButton("Delete model · reclaim \(reclaimLabel)", symbol: "trash") { localModel.deleteModel() }
                    if InternalBuild.showsDevTuners { localTestBlock }
                case .failed(let reason):
                    // A DOWNLOAD failure — the weights aren't (fully) on disk, so re-downloading is right.
                    localStatusRow(symbol: "exclamationmark.triangle", text: "Download failed")
                    Text(reason).font(.caption2).foregroundStyle(.orange.opacity(0.8)).lineLimit(3)
                    localCapsuleButton("Retry download", symbol: "arrow.clockwise") { localModel.download() }
                case .loadFailed(let reason):
                    // ws-bg-download Fix Path A — the weights ARE on disk; this is a LOAD failure, so the
                    // remedy is a cheap retry (repair sidecars + load), NOT a 1.8 GB re-download. That
                    // re-download is exactly what cost T two cellular downloads. Delete stays as the
                    // deliberate escape hatch.
                    localStatusRow(symbol: "exclamationmark.triangle", text: "Downloaded — but couldn't load")
                    Text(reason).font(.caption2).foregroundStyle(.orange.opacity(0.8)).lineLimit(3)
                    localCapsuleButton("Try again", symbol: "arrow.clockwise") { localModel.retryLoad() }
                    localCapsuleButton("Delete model · reclaim \(reclaimLabel)", symbol: "trash") { localModel.deleteModel() }
                }
            }
        }
    }

    private var reclaimLabel: String {
        ByteCountFormatter.string(fromByteCount: localModel.diskUsageBytes(), countStyle: .file)
    }

    // Colorblind-safe: shape (SF Symbol) + text carry the meaning; no colour-only state.
    private func localStatusRow(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(AppearancePalette.ink.opacity(0.55))
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(AppearancePalette.ink.opacity(0.75))
        }
    }

    private func localCapsuleButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(AppearancePalette.ink.opacity(0.09))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // STEP 5 — verification hook, DEBUG/dev-only (InternalBuild.showsDevTuners → false in Release).
    private var localTestBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            localCapsuleButton(isTestingLocal ? "Testing…" : "Test generation",
                               symbol: "play.circle") { runLocalTest() }
            if !localTestOutput.isEmpty {
                Text(localTestOutput)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                    .textSelection(.enabled)
                if localModel.lastOutTokens > 0 {
                    Text("\(localModel.lastOutTokens) out-tokens · \(String(format: "%.1f", localModel.lastTokPerSec)) tok/s")
                        .font(.caption2.monospacedDigit()).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }
        }
    }

    private func runLocalTest() {
        guard !isTestingLocal else { return }
        isTestingLocal = true; localTestOutput = ""
        Task {
            do {
                let out = try await localModel.generate(
                    systemPrompt: "You are a note-distillation assistant. Reply ONLY with a JSON object: {\"title\": \"...\", \"summary\": \"...\"}.",
                    userPrompt: "Breakfast, lunch, dinner — why three meals? The whole structure feels like a social construct the food industry reinforced to sell cereal and coffee.")
                localTestOutput = out
            } catch {
                localTestOutput = "ERROR: \(error)"
            }
            isTestingLocal = false
        }
    }

    private var personalPromptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Personal voice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                Spacer()
                Text("\(librarianPersonalPrompt.count) / \(Self.librarianPersonalPromptMaxChars)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        librarianPersonalPrompt.count >= Self.librarianPersonalPromptMaxChars
                        ? .orange.opacity(0.8)
                        : AppearancePalette.ink.opacity(0.3)
                    )
            }
            TextField(
                Self.librarianPersonalPromptPlaceholder,
                text: $librarianPersonalPrompt,
                axis: .vertical
            )
            .font(.subheadline)
            .foregroundStyle(AppearancePalette.ink)
            .tint(AppearancePalette.ink)
            .lineLimit(3...8)
            .padding(12)
            .background(AppearancePalette.ink.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: librarianPersonalPrompt) { _, new in
                if new.count > Self.librarianPersonalPromptMaxChars {
                    librarianPersonalPrompt = String(
                        new.prefix(Self.librarianPersonalPromptMaxChars)
                    )
                }
            }

            Text("Prepended to every Librarian query — shapes how the model engages with you.")
                .font(.caption2)
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    private var currentModelRow: some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundStyle(.purple.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Active model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                Text(activeModelName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppearancePalette.ink)
            }
            Spacer()
        }
        .padding(14)
        .background(AppearancePalette.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var activeModelName: String {
        if !anthropicKey.isEmpty { return "Anthropic (Claude)" }
        if !openAIKey.isEmpty    { return "OpenAI" }
        if !deepSeekKey.isEmpty  { return "DeepSeek" }
        if !ollamaEndpoint.isEmpty { return "Ollama (local)" }
        // Single source of truth so this can't drift from the Librarian pill
        // (both now read "Apple Intelligence"). Was "On-device (Foundation Model)".
        return ModelRouter.foundationModelName
    }

    @ViewBuilder
    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            SecureField(placeholder, text: text)
                .font(.subheadline)
                .foregroundStyle(AppearancePalette.ink)
                .tint(AppearancePalette.ink)
                .padding(12)
                .background(AppearancePalette.ink.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Privacy")

            Toggle(isOn: $locationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPS location on capture")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppearancePalette.ink)
                    Text("Attaches your location to newly captured entries")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }
            .tint(.purple)

            if !hasAnyFrontierKey {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.8))
                    Text("Your data never leaves this device")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                }
            }
        }
    }

    private var hasAnyFrontierKey: Bool {
        // Brief AJ5 — with cloud providers gated off (Release), data never leaves the
        // device regardless of any Keychain remnant, so the lock line always shows.
        guard FeatureFlags.cloudProviders else { return false }
        return !anthropicKey.isEmpty || !openAIKey.isEmpty || !deepSeekKey.isEmpty
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Tags")

            if store.tags.isEmpty {
                Text("No tags yet — AI will suggest them as you capture entries.")
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
            } else {
                FlowLayoutSettings(spacing: 8) {
                    ForEach(store.tags) { tag in
                        tagPill(tag)
                    }
                }
            }

            Button {
                editingTag = nil
                showTagEditor = true
            } label: {
                Label("New Tag", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppearancePalette.ink.opacity(0.09))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorSheet(existing: editingTag)
        }
    }

    private func tagPill(_ tag: Tag) -> some View {
        Button {
            editingTag = tag
            showTagEditor = true
        } label: {
            Text(tag.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((Color(hex: tag.colorHex) ?? .gray).opacity(0.3))
                .overlay(Capsule().stroke(Color(hex: tag.colorHex) ?? .gray, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Import")

            Button {
                showImportIdeas = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import entries")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showImportIdeas) {
                ImportIdeasSheet()
            }

            Text("Paste a block of text or share a .txt / .md file — each paragraph becomes an entry.")
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    // MARK: - Review queue

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Needs review")

            Button {
                showReviewQueue = true
            } label: {
                HStack {
                    Image(systemName: "tray.and.arrow.down")
                    Text("Needs review")
                    Spacer()
                    if store.reviewQueue.isEmpty {
                        Text("Clear")
                            .font(.caption)
                            .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                    } else {
                        Text("\(store.reviewQueue.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.7))
                            .clipShape(Capsule())
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showReviewQueue) {
                ReviewQueueSheet()
            }

            Text("Entries that didn't pass the quality gate during import. Promote or discard — nothing is lost.")
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    // MARK: - Developer (DEBUG-only)

    // ★ Whole section is `#if DEBUG` — it never ships. Stripped 2026-08-01:
    // "Simulate thread" (fabricated a fake ThreadSuggestion into the review
    // queue — a privacy-oath violation, deleted outright) and "Run Gate
    // Diagnostic Test" (read a ~/Desktop path absent on device, deleted) are
    // gone. What remains is dev-only: corpus maintenance (Reprocess / Backfill —
    // no honest user-facing home yet; promote to a real Settings "Maintenance"
    // section if ever user-exposed), the SB126 experimental tagging flag, and
    // the substrate-inspect long-press.
    #if DEBUG
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            reprocessRow

            backfillEmbeddingRow

            Toggle(isOn: $useCorpusAwareTagging) {
                Text("SB126 Stage 2 — corpus-aware tagging")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.5))
            }
            .tint(.orange)
            .padding(.horizontal, 16)

            // ★ Brief L §1 — orb-separation dials retired: T ruled floor = 6. The value is baked into
            // `AnnulusTuning.breathingGap` and the ×radius term is deleted; the sliders/toggle are gone
            // and their persisted keys are purged in AirPadApp.

            // ★ Brief K §2 — one-shot export of EVERY app-domain UserDefaults key (not a prefix
            // allow-list — that can't find a key we didn't anticipate). Values only. T pastes it back.
            Button {
                tunerExportStatus = SettingsView.copyAllTunerState()
            } label: {
                Text(tunerExportStatus.isEmpty ? "Copy all tuner state → clipboard" : tunerExportStatus)
                    .font(.caption2).foregroundStyle(.orange.opacity(0.6))
            }
            .padding(.horizontal, 16)

            // SB139 Stage 1 — hidden long-press opens the substrate dev
            // inspect view. Label is faint on purpose; this surface is for
            // Thomas debugging the substrate, not for end users.
            Text("· · ·")
                .font(.caption2)
                .foregroundStyle(AppearancePalette.ink.opacity(0.12))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .contentShape(Rectangle())
                #if DEBUG
                .onLongPressGesture(minimumDuration: 1.0) {
                    if #available(iOS 17.0, *) {
                        showSubstrateInspect = true
                    }
                }
                #endif
        }
        #if DEBUG
        .sheet(isPresented: $showSubstrateInspect) {
            if #available(iOS 17.0, *) {
                SubstrateInspectView()
                    .environment(store)
            }
        }
        #endif
    }

    /// ★ Brief K §2 — export EVERY app-domain UserDefaults key (excluding Apple's NS*/Apple*/com.apple.*
    /// system keys) to the pasteboard. A prefix allow-list can't surface a key we didn't anticipate —
    /// which is exactly the `count=1` result we're chasing — so dump the whole domain. Values only, no
    /// node content (UserDefaults holds config/dials, not corpus prose). TEMP — removable in one commit.
    static func copyAllTunerState() -> String {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let keys = all.keys
            .filter { k in !(k.hasPrefix("NS") || k.hasPrefix("Apple") || k.hasPrefix("com.apple.")) }
            .sorted()
        var lines = ["===== AirPad TUNER — DIALED STATE (all app UserDefaults keys) =====",
                     "(keys NOT listed are still at their code seed default)"]
        for k in keys { lines.append("\(k) = \(String(describing: all[k] ?? ""))") }
        lines.append("count=\(keys.count)")
        lines.append("===== END =====")
        UIPasteboard.general.string = lines.joined(separator: "\n")
        return "Copied \(keys.count) keys to clipboard"
    }
    #endif

    @ViewBuilder
    private var reprocessRow: some View {
        let state = store.reprocessing
        let inFlight = state != nil && state?.done == false

        VStack(spacing: 4) {
            Button {
                Task { await store.reprocessUntaggedNodes() }
            } label: {
                Text(inFlight ? "Reprocessing…" : "Reprocess Untagged Nodes")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(inFlight ? 0.3 : 0.5))
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .frame(maxWidth: .infinity, alignment: .center)

            if let s = state {
                Text(reprocessStatusText(s))
                    .font(.caption2)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func reprocessStatusText(_ s: ReprocessingState) -> String {
        if s.done {
            return "\(s.total) attempted · \(s.tagged) tagged · \(s.failed) refused/failed"
        }
        return "\(s.current)/\(s.total) · \(s.tagged) tagged · \(s.failed) refused"
    }

    @ViewBuilder
    private var backfillEmbeddingRow: some View {
        let state = store.backfillingEmbeddings
        let inFlight = state != nil && state?.done == false

        VStack(spacing: 4) {
            Button {
                Task { await store.backfillContentEmbeddings() }
            } label: {
                Text(inFlight ? "Backfilling embeddings…" : "Backfill content embeddings")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(inFlight ? 0.3 : 0.5))
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .frame(maxWidth: .infinity, alignment: .center)

            if let s = state {
                Text(backfillStatusText(s))
                    .font(.caption2)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func backfillStatusText(_ s: BackfillEmbeddingState) -> String {
        if s.done {
            return "\(s.total) attempted · \(s.populated) populated · \(s.skippedNoContent) skipped"
        }
        return "\(s.current)/\(s.total) · \(s.populated) populated · \(s.skippedNoContent) skipped"
    }

    // MARK: - Corpus

    private var corpusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Library")

            // Brief Z R3 — counts are the user's ROOM; the sample gets its own line.
            HStack(spacing: 16) {
                statBox(value: "\(store.corpusRoomNodes.count)", label: "Entries")
                statBox(value: "\(store.tags.count)", label: "Tags")
                statBox(value: "\(store.corpusRoomNodes.filter { $0.isMeta }.count)", label: "Threads")
            }
            if store.sampleLibraryPresent {
                Text("Sample Library: \(store.sampleNodeIDs.count) entries")
                    .font(.footnote)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }

            // Brief Y Part E — search-index coverage dial. Reads the block-reconciler
            // tally (nodes with a current index / nodes with text; no-text nodes
            // excluded) + the embedder version, shows "rebuilding…" while the
            // reconciler runs, and offers a foreground "Rebuild now" (same pacing).
            if #available(iOS 17.0, *) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    if store.blockIndexRebuilding {
                        Text("Search index · rebuilding…")
                    } else if let cov = store.blockIndexCoverage {
                        Text("Search index · \(cov.current)/\(cov.total) entries current · v\(BlockEmbeddingService.currentEmbedderVersion)")
                    } else {
                        Text("Search index · checking…")
                    }
                    Spacer()
                    Button("Rebuild now") {
                        Task { await store.rebuildBlockIndexNow() }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(store.blockIndexRebuilding)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .task { await store.refreshBlockIndexCoverage() }
            }

            Button {
                // Scaffold — full export in Session 6
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export library")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                showClearConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Clear all entries")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Clear all entries?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await store.clearAllData() }
                }
            } message: {
                Text("This will permanently delete all entries and cannot be undone.")
            }

            // Brief U Step 3 — add OR remove the bundled sample library on demand.
            // "Remove" (marker present) deletes exactly what was seeded, keyed to the
            // manifest, leaving the user's own notes untouched. "Add" (marker absent)
            // seeds it over the user's existing corpus — so T can have the sample
            // beside his real corpus without a fresh install. Always shown; the
            // launch auto-seed gate (empty corpus + no marker) is unchanged.
            Button {
                if store.sampleLibraryPresent {
                    showRemoveSampleConfirmation = true
                } else {
                    Task { await store.addSampleLibrary() }
                }
            } label: {
                HStack {
                    Image(systemName: store.sampleLibraryPresent
                          ? "sparkles.rectangle.stack" : "sparkles.rectangle.stack.fill")
                    Text(store.sampleLibraryPresent ? "Remove Sample Library" : "Add Sample Library")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Remove Sample Library?",
                isPresented: $showRemoveSampleConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task { await store.removeSampleLibrary() }
                }
            } message: {
                Text("Removes the bundled sample entries and their collections. Your own entries are not affected.")
            }
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppearancePalette.ink)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppearancePalette.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")
            Text("AirPad")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink)
            Text("It works around you. Not the other way around.")
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            // Brief AG3 — bring back every first-run callout (each shows again on its surface).
            Button {
                FirstRunCalloutKey.resetAll()
                tipsReset = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { tipsReset = false }
            } label: {
                HStack {
                    Image(systemName: tipsReset ? "checkmark" : "lightbulb")
                    Text(tipsReset ? "First-time tips will show again" : "Reset first-time tips")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppearancePalette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text("Version \(version) (\(build))")
                    .font(.caption2)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.25))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppearancePalette.ink.opacity(0.35))
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func loadKeys() {
        // Brief AJ5 — cloud keys are neither loaded nor saved when the flag is off
        // (Release): the fields don't exist, and existing Keychain entries are LEFT
        // exactly as-is (never read back, never re-written, never deleted).
        if FeatureFlags.cloudProviders {
            anthropicKey   = KeychainHelper.load(key: "anthropicAPIKey")   ?? ""
            openAIKey      = KeychainHelper.load(key: "openAIAPIKey")      ?? ""
            deepSeekKey    = KeychainHelper.load(key: "deepSeekAPIKey")    ?? ""
        }
        braveSearchKey = KeychainHelper.load(key: WebSearchBackend.keychainKey) ?? ""
        ollamaEndpoint = KeychainHelper.load(key: "ollamaEndpoint")    ?? ""
        ollamaAPIToken = KeychainHelper.load(key: "ollamaAPIToken")    ?? ""
        hostPairing    = HostPairing.load()
    }

    private func saveKeys() {
        if FeatureFlags.cloudProviders {
            persistKey("anthropicAPIKey", value: anthropicKey)
            persistKey("openAIAPIKey",    value: openAIKey)
            persistKey("deepSeekAPIKey",  value: deepSeekKey)
        }
        persistKey(WebSearchBackend.keychainKey, value: braveSearchKey)
        persistKey("ollamaEndpoint",  value: ollamaEndpoint)
        persistKey("ollamaAPIToken",  value: ollamaAPIToken)
    }

    private func persistKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainHelper.delete(key: key)
        } else {
            KeychainHelper.save(key: key, value: value)
        }
    }

    /// "Test connection" for the local-server (Ollama / LM Studio) endpoint — three honest,
    /// in-place outcomes. Empty short-circuits BEFORE the spinner (no attempt, no spinner-to-
    /// nothing). Otherwise it actually probes the endpoint via `ModelRouter.probeEndpoint`, which
    /// reuses the same path the live Librarian uses.
    private func testConnection() {
        let trimmed = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionTestResult = "Enter an endpoint above to test it."   // no connection attempt
            return
        }
        isTestingConnection = true
        connectionTestResult = nil
        Task {
            switch await ModelRouter.probeEndpoint(trimmed) {
            case .needsEndpoint:
                connectionTestResult = "Enter an endpoint above to test it."
            case .reachable(let model):
                connectionTestResult = "✓ Connected — \(model) is loaded"
            case .unreachable(let reason):
                connectionTestResult = "✗ \(reason)"
            }
            isTestingConnection = false
        }
    }

    /// ✓ green / ✗ red / neutral guidance (the empty-field line is not an error).
    private func connectionResultColor(_ result: String) -> Color {
        if result.hasPrefix("✓") { return .green }
        if result.hasPrefix("✗") { return .red.opacity(0.8) }
        return AppearancePalette.ink.opacity(0.55)
    }
}

// MARK: - Wrapping flow layout for tag pills

private struct FlowLayoutSettings: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rowWidth > 0 ? spacing : 0) > maxWidth {
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
                rowHeight = max(rowHeight, size.height)
            }
        }
        height += rowHeight
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
