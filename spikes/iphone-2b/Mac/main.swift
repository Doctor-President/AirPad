// Sweep 2b · 3.3 — the Mac runner: the phone app's battery (Shared/) as a command-line process on this Mac, Apple
// Intelligence and the same Qwen3.5 4B weights through MLX. run_mac.sh builds and runs it.
//
//   spike-mac [--phases all|apple|mlx] [--dry-run] [--repeats 6] [--mlx-repeats 3] [--model-dir DIR] [--out DIR]
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let phases = (value("--phases") ?? "all").lowercased()
let config = SpikeConfig(
    phases: phases == "all" ? ["apple", "mlx"] : Set(phases.split(separator: ",").map(String.init)),
    dryRun: args.contains("--dry-run"),
    appleRepeats: Int(value("--repeats") ?? "") ?? 6,
    mlxRepeats: Int(value("--mlx-repeats") ?? "") ?? 3,
    modelDir: URL(fileURLWithPath: value("--model-dir") ?? "build/iphone-spike/models/Qwen3.5-4B-MLX-4bit", relativeTo: cwd).standardizedFileURL,
    outDir: URL(fileURLWithPath: value("--out") ?? "build/iphone-spike/results/mac", relativeTo: cwd).standardizedFileURL,
    platform: "mac")

Task { @MainActor in
    let runner = SpikeRunner(config: config)
    await runner.run()
    print("[spike] results: \(config.outDir.appendingPathComponent("spike-results.json").path)")
    exit(0)
}
dispatchMain()
