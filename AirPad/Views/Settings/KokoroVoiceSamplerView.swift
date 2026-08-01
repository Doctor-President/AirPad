#if DEBUG
import SwiftUI

/// DEBUG-only voice sampler for the Kokoro on-device TTS spike. Warms the model
/// off the launch path (on THIS screen's appear, never at app start), enumerates
/// the voice styles present in the bundled `voices.npz`, and plays a fixed line
/// per voice so T can judge voice/character on device. Shows cold-load + RTF
/// telemetry. If the ~600 MB model isn't installed, shows the exact drop-in path.
struct KokoroVoiceSamplerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine = KokoroTTSEngine.shared

    /// A line with varied prosody, a contraction, and clause breaks — enough to
    /// judge timbre and cadence, not just a single word.
    private let sampleLine = "The quiet library keeps every idea you've ever had, ready the moment you reach for it."

    @State private var busyID: String?
    @State private var errorText: String?

    // (The ORT ONNX-Runtime test tier was removed 2026-07-31 with the ORT
    //  dependency — ITMS-90208 cleanup. This sampler now exercises the MLX
    //  KokoroTTSEngine only. See ws-synthesized-voice.md to restore.)

    var body: some View {
        NavigationStack {
            Group {
                if engine.isModelInstalled {
                    loadedBody
                } else {
                    notInstalledBody
                }
            }
            .navigationTitle("Kokoro Voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { engine.stop(); dismiss() }
                }
            }
        }
        .task {
            // Cold-load OFF the launch path: this fires when the sampler opens,
            // not at app start. Safe — the actor does the heavy load off-main.
            guard engine.isModelInstalled, !engine.isLoaded else { return }
            do { try await engine.warmUpIfNeeded() }
            catch { errorText = error.localizedDescription }
        }
    }

    // MARK: Loaded

    private var loadedBody: some View {
        List {
            Section {
                telemetryRow
            }
            if engine.isWarmingUp && !engine.isLoaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading model (~600 MB)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(groupedVoices, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.ids, id: \.self) { id in
                        voiceRow(id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func voiceRow(_ id: String) -> some View {
        Button {
            toggle(id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: busyID == id ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(busyID == id ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KokoroVoiceCatalog.displayName(for: id))
                        .font(.body)
                    Text(id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busyID == id && engine.isWarmingUp {
                    ProgressView()
                } else {
                    Text(KokoroVoiceCatalog.accentTag(for: id))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var telemetryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cold = engine.coldLoadSeconds {
                metric("Cold load", String(format: "%.1fs", cold))
            }
            if let rtf = engine.lastRTF, let gen = engine.lastGenerateSeconds {
                metric("Last synth", String(format: "%.2fs · RTF %.2f", gen, rtf))
            }
            metric("Voices in file", "\(engine.loadedVoiceIDs.count)")
            if let err = errorText {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    // MARK: Not installed

    private var notInstalledBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Model not installed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Drop the two Kokoro asset files into the app's Resources so they bundle under the “Kokoro” folder, then rebuild:")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 8) {
                    dropRow("kokoro-v1_0.safetensors", "~600 MB weights")
                    dropRow("voices.npz", "voice styles")
                }
                Text("Expected location in the repo:")
                    .font(.callout).foregroundStyle(.secondary)
                Text("AirPad/Resources/Kokoro/")
                    .font(.callout.monospaced())
                    .padding(8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text("The folder is a folder-reference; anything inside bundles under Kokoro/ at runtime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dropRow(_ name: String, _ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
            Text(name).font(.callout.monospaced())
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var groupedVoices: [(title: String, ids: [String])] {
        let ids = KokoroVoiceCatalog.sorted(engine.loadedVoiceIDs)
        let groups = Dictionary(grouping: ids) { KokoroVoiceCatalog.accentTag(for: $0) }
        // Preserve the sorted order of first appearance per group.
        var seen: [String] = []
        for id in ids {
            let tag = KokoroVoiceCatalog.accentTag(for: id)
            if !seen.contains(tag) { seen.append(tag) }
        }
        return seen.map { (title: $0, ids: groups[$0] ?? []) }
    }

    private func toggle(_ id: String) {
        errorText = nil
        if busyID == id {
            engine.stop()
            busyID = nil
            return
        }
        busyID = id
        Task {
            do {
                try await engine.speak(text: sampleLine, voiceID: id) {
                    if busyID == id { busyID = nil }
                }
            } catch {
                errorText = error.localizedDescription
                busyID = nil
            }
        }
    }
}
#endif
