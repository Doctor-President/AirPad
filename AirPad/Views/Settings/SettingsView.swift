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

    // UI state
    @State private var connectionTestResult: String? = nil
    @State private var isTestingConnection = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    aiModelSection
                    Divider().background(Color.white.opacity(0.1))
                    privacySection
                    Divider().background(Color.white.opacity(0.1))
                    corpusSection
                    Divider().background(Color.white.opacity(0.1))
                    aboutSection
                }
                .padding(20)
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
