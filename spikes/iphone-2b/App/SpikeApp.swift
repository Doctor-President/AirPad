// Sweep 2b · 3.3 — the phone app: runs the whole battery on launch, shows one progress line, keeps the screen awake,
// writes Documents/spike-results.json + spike-progress.json. Launch arguments (run_on_phone.sh passes them):
//   -SpikePhases all|apple|mlx   -SpikeDryRun YES   -SpikeRepeats 6   -SpikeMLXRepeats 3
//   -SpikeModelDir <path>        (default Documents/models/Qwen3.5-4B-MLX-4bit, where run_on_phone.sh copies it)
//   -SpikeFreeSpaceOnly YES      (writes Documents/spike-freespace.json and stops: the preflight's free-space check)
import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    @StateObject private var runner = SpikeRunner(config: SpikeApp.config())

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func config() -> SpikeConfig {
        let d = UserDefaults.standard
        let phases = (d.string(forKey: "SpikePhases") ?? "all").lowercased()
        return SpikeConfig(
            phases: phases == "all" ? ["apple", "mlx"] : Set(phases.split(separator: ",").map(String.init)),
            dryRun: d.bool(forKey: "SpikeDryRun"),
            appleRepeats: d.object(forKey: "SpikeRepeats") != nil ? d.integer(forKey: "SpikeRepeats") : 6,
            mlxRepeats: d.object(forKey: "SpikeMLXRepeats") != nil ? d.integer(forKey: "SpikeMLXRepeats") : 3,
            modelDir: d.string(forKey: "SpikeModelDir").map { URL(fileURLWithPath: $0) }
                ?? documents.appendingPathComponent("models/Qwen3.5-4B-MLX-4bit"),
            outDir: documents, platform: "iphone")
    }

    var body: some Scene {
        WindowGroup { SpikeView(runner: runner) }
    }
}

struct SpikeView: View {
    @ObservedObject var runner: SpikeRunner
    @State private var started = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AirPad spike 2b").font(.title2.bold())
            Text("Invented notes only. Keep the phone unlocked and connected until it says done.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if !runner.finished && note.isEmpty { ProgressView() }
                Text(note.isEmpty ? runner.line : note).font(.body.monospaced())
            }
            if runner.finished { Text("Done. Results are in the app's Documents folder.").font(.headline) }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !started else { return }
            started = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            if UserDefaults.standard.bool(forKey: "SpikeFreeSpaceOnly") {
                writeFreeSpace(); return
            }
            UIApplication.shared.isIdleTimerDisabled = true   // the screen stays awake while the battery runs
            await runner.run()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func writeFreeSpace() {
        let docs = SpikeApp.documents
        let v = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        let obj: [String: Any] = ["importantUsageBytes": v?.volumeAvailableCapacityForImportantUsage ?? -1,
                                  "availableBytes": v?.volumeAvailableCapacity ?? -1, "totalBytes": v?.volumeTotalCapacity ?? -1]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent("spike-freespace.json"), options: .atomic)
        }
        note = "free space written"
    }
}
