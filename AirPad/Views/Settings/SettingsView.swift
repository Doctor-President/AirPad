import SwiftUI

struct SettingsView: View {

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

    // Privacy
    @AppStorage("locationEnabled") private var locationEnabled = false

    // SB126 Stage 2 — bound to the same key FeatureFlags.useCorpusAwareTagging reads.
    @AppStorage("ff.useCorpusAwareTagging") private var useCorpusAwareTagging = false

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
    // Stage 4 — desktop Host pairing. `hostPairing` is cached (Keychain read is XPC-backed;
    // never read HostPairing.load() from `body`); refreshed on appear + after the sheet closes.
    @State private var showPairingQR = false
    @State private var hostPairing: HostPairing? = nil
    @State private var showImportIdeas = false
    @State private var showReviewQueue = false
    @State private var showClearConfirmation = false

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
    #if DEBUG
    // Dev diagnostics — SubstrateInspectView carries a DESTRUCTIVE "Reset cluster
    // registry"; it must not be reachable in a shipping build. DEBUG-gated
    // (state + gesture + sheet all gated).
    @State private var showSubstrateInspect = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    aiModelSection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    privacySection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    tagsSection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    importSection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    reviewSection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    corpusSection
                    Divider().background(AppearancePalette.ink.opacity(0.1))
                    aboutSection
                    #if DEBUG
                    developerSection
                    #endif
                }
                .padding(20)
                .dismissKeyboardOnTapOutside()
            }
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
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
        .onAppear { loadKeys() }
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
                apiKeyField(label: "Brave Search API key", placeholder: "BSA...", text: $braveSearchKey)

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

            localModelSubsection

            hostPairingRow
        }
        .sheet(isPresented: $showPairingQR, onDismiss: { hostPairing = HostPairing.load() }) {
            HostPairingSheet()
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
            Text("Private on-device model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            // Placeholder copy (T is providing final wording).
            Text("AirPad lets you choose which model does its thinking. Apple Intelligence is built into your device and works immediately. AirPad also offers an optional private model you can download — it runs entirely on your device, engages consistently across all subjects, and doesn't change when your phone updates.")
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
                            Text("Use for note enrichment")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                            Text(useLocalEnrichment
                                 ? "New note titles, summaries, and tags use the private model."
                                 : "Apple Intelligence is still doing the thinking. Turn on to use the private model.")
                                .font(.caption2)
                                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color(hexString: "1B59C2"))
                    Text("Excluded from backup: \(localModel.excludedFromBackup ? "yes" : "NO"). Stored in Application Support (not iCloud).")
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
                    Text("Attaches your location to newly captured nodes")
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
        !anthropicKey.isEmpty || !openAIKey.isEmpty || !deepSeekKey.isEmpty
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Tags")

            if store.tags.isEmpty {
                Text("No tags yet — AI will suggest them as you capture ideas.")
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
                    Text("Import ideas")
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

            Text("Paste a block of text or share a .txt / .md file — each paragraph becomes a node.")
                .font(.caption)
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    // MARK: - Review queue

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Review")

            Button {
                showReviewQueue = true
            } label: {
                HStack {
                    Image(systemName: "tray.and.arrow.down")
                    Text("Flagged ideas")
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

            Text("Ideas that didn't pass the quality gate during import. Promote or discard — nothing is lost.")
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
            sectionHeader("Corpus")

            HStack(spacing: 16) {
                statBox(value: "\(store.nodes.count)", label: "Nodes")
                statBox(value: "\(store.tags.count)", label: "Tags")
                statBox(value: "\(store.nodes.filter { $0.isMeta }.count)", label: "Threads")
            }

            Button {
                // Scaffold — full export in Session 6
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export corpus")
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
                    Text("Clear all nodes")
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
                "Clear all nodes?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await store.clearAllData() }
                }
            } message: {
                Text("This will permanently delete all nodes and cannot be undone.")
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
        anthropicKey   = KeychainHelper.load(key: "anthropicAPIKey")   ?? ""
        openAIKey      = KeychainHelper.load(key: "openAIAPIKey")      ?? ""
        deepSeekKey    = KeychainHelper.load(key: "deepSeekAPIKey")    ?? ""
        braveSearchKey = KeychainHelper.load(key: WebSearchBackend.keychainKey) ?? ""
        ollamaEndpoint = KeychainHelper.load(key: "ollamaEndpoint")    ?? ""
        ollamaAPIToken = KeychainHelper.load(key: "ollamaAPIToken")    ?? ""
        hostPairing    = HostPairing.load()
    }

    private func saveKeys() {
        persistKey("anthropicAPIKey", value: anthropicKey)
        persistKey("openAIAPIKey",    value: openAIKey)
        persistKey("deepSeekAPIKey",  value: deepSeekKey)
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
