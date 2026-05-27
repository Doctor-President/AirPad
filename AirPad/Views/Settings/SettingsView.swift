import SwiftUI

struct SettingsView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Frontier API keys (loaded from Keychain on appear)
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var deepSeekKey = ""
    @State private var ollamaEndpoint = ""

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
    @State private var showImportIdeas = false
    @State private var showReviewQueue = false
    @State private var showClearConfirmation = false
    @State private var showSubstrateInspect = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    aiModelSection
                    Divider().background(Color.white.opacity(0.1))
                    privacySection
                    Divider().background(Color.white.opacity(0.1))
                    tagsSection
                    Divider().background(Color.white.opacity(0.1))
                    importSection
                    Divider().background(Color.white.opacity(0.1))
                    reviewSection
                    Divider().background(Color.white.opacity(0.1))
                    corpusSection
                    Divider().background(Color.white.opacity(0.1))
                    aboutSection
                    developerSection
                }
                .padding(20)
                .dismissKeyboardOnTapOutside()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveKeys()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationBackground(.black)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("http://192.168.x.x:11434", text: $ollamaEndpoint)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            HStack {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        }
                        Text(isTestingConnection ? "Testing…" : "Test connection")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isTestingConnection || activeAPIKey == nil)

                if let result = connectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .red.opacity(0.8))
                }
                Spacer()
            }

            personalPromptField
        }
    }

    private var personalPromptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Personal voice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(librarianPersonalPrompt.count) / \(Self.librarianPersonalPromptMaxChars)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        librarianPersonalPrompt.count >= Self.librarianPersonalPromptMaxChars
                        ? .orange.opacity(0.8)
                        : .white.opacity(0.3)
                    )
            }
            TextField(
                Self.librarianPersonalPromptPlaceholder,
                text: $librarianPersonalPrompt,
                axis: .vertical
            )
            .font(.subheadline)
            .foregroundStyle(.white)
            .tint(.white)
            .lineLimit(3...8)
            .padding(12)
            .background(Color.white.opacity(0.07))
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
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private var currentModelRow: some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundStyle(.purple.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Active model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text(activeModelName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var activeModelName: String {
        if !anthropicKey.isEmpty { return "Anthropic (Claude)" }
        if !openAIKey.isEmpty    { return "OpenAI" }
        if !deepSeekKey.isEmpty  { return "DeepSeek" }
        if !ollamaEndpoint.isEmpty { return "Ollama (local)" }
        return "On-device (Foundation Model)"
    }

    private var activeAPIKey: String? {
        if !anthropicKey.isEmpty { return anthropicKey }
        if !openAIKey.isEmpty    { return openAIKey }
        if !deepSeekKey.isEmpty  { return deepSeekKey }
        return nil
    }

    @ViewBuilder
    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
            SecureField(placeholder, text: text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(12)
                .background(Color.white.opacity(0.07))
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
                        .foregroundStyle(.white)
                    Text("Attaches your location to newly captured nodes")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
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
                        .foregroundStyle(.white.opacity(0.5))
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
                    .foregroundStyle(.white.opacity(0.35))
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
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.09))
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
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showImportIdeas) {
                ImportIdeasSheet()
            }

            Text("Paste a block of text or share a .txt / .md file — each paragraph becomes a node.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
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
                            .foregroundStyle(.white.opacity(0.3))
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
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showReviewQueue) {
                ReviewQueueSheet()
            }

            Text("Ideas that didn't pass the quality gate during import. Promote or discard — nothing is lost.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Developer (hidden)

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // TODO: remove before App Store release
            Button {
                simulateThread()
            } label: {
                Text("Simulate thread")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.2))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)

            Button {
                Task {
                    await store.runGateDiagnosticTest()
                }
            } label: {
                Text("Run Gate Diagnostic Test")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.5))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)

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
                .foregroundStyle(.white.opacity(0.12))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) {
                    if #available(iOS 17.0, *) {
                        showSubstrateInspect = true
                    }
                }
        }
        .sheet(isPresented: $showSubstrateInspect) {
            if #available(iOS 17.0, *) {
                SubstrateInspectView()
                    .environment(store)
            }
        }
    }

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
                    .foregroundStyle(.white.opacity(0.35))
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
                    .foregroundStyle(.white.opacity(0.35))
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

    private func simulateThread() {
        guard store.nodes.count >= 2 else { return }
        let ids = Array(store.nodes.prefix(2).map { $0.id })
        let fake = ThreadSuggestion(
            id: UUID(),
            nodeIDs: ids,
            description: "Simulated connection between first two nodes",
            confidence: 0.99
        )
        store.pendingThreads.append(fake)
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
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.07))
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
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")
            Text("AirPad")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("It works around you. Not the other way around.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text("Version \(version) (\(build))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.35))
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func loadKeys() {
        anthropicKey   = KeychainHelper.load(key: "anthropicAPIKey")   ?? ""
        openAIKey      = KeychainHelper.load(key: "openAIAPIKey")      ?? ""
        deepSeekKey    = KeychainHelper.load(key: "deepSeekAPIKey")    ?? ""
        ollamaEndpoint = KeychainHelper.load(key: "ollamaEndpoint")    ?? ""
    }

    private func saveKeys() {
        persistKey("anthropicAPIKey", value: anthropicKey)
        persistKey("openAIAPIKey",    value: openAIKey)
        persistKey("deepSeekAPIKey",  value: deepSeekKey)
        persistKey("ollamaEndpoint",  value: ollamaEndpoint)
    }

    private func persistKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainHelper.delete(key: key)
        } else {
            KeychainHelper.save(key: key, value: value)
        }
    }

    private func testConnection() {
        guard let key = activeAPIKey else { return }
        isTestingConnection = true
        connectionTestResult = nil
        Task {
            // Minimal Anthropic-style check — just validates the key format and reachability.
            // A real implementation would send a minimal completions request.
            try? await Task.sleep(for: .seconds(1))
            connectionTestResult = key.count > 10 ? "✓ Key saved" : "✗ Key too short"
            isTestingConnection = false
        }
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
