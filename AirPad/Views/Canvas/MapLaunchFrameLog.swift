#if targetEnvironment(macCatalyst)
import Foundation
import QuartzCore

/// Mac D fix-up B3 — T saw the Map stutter heavily on one launch (smooth after a relaunch + an appearance change) and it
/// didn't come back on demand. So every launch records the Map's first 30 s of frames, one line per second (frames,
/// asked rate, frame-interval p50/p95/max, hitches, the scene's update time, Low Power, thermal, look, size, rest) plus
/// the events that can change the cost (size, appearance, power, look). Written to
/// `Library/Caches/MapLaunchFrames.log` in the app's container (timings only, never content); the last ~20 launches
/// are kept. Nothing runs after the 30 s, and nothing while the Map isn't drawing (it rests at 0 fps).
@MainActor
final class MapLaunchFrameLog {
    static let shared = MapLaunchFrameLog()
    static let window: TimeInterval = 30

    private var start: TimeInterval?
    private var lastFrame: TimeInterval?
    private var second = 0
    private var dts: [Double] = []
    private var updates: [Double] = []
    private var asked = 0
    private var lines: [String] = []
    private var done = false
    private var flushedLines = 0

    var active: Bool { !done }

    /// One drawn frame: `t` = the scene's currentTime, `updateMs` = the scene's own update work this frame.
    func frame(_ t: TimeInterval, updateMs: Double, askFPS: Int, context: () -> String) {
        guard !done else { return }
        if start == nil {
            start = t
            lines.append("=== launch \(Self.stamp()) build \(Self.build()) — first Map frame")
        }
        guard let start else { return }
        let s = Int(t - start)
        if s != second { closeSecond(context: context) ; second = s }
        if let lastFrame { dts.append((t - lastFrame) * 1000) }
        lastFrame = t
        updates.append(updateMs)
        asked = askFPS
        if t - start >= Self.window {
            closeSecond(context: context)
            lines.append("=== end of the first \(Int(Self.window)) s")
            done = true
            flush()
        } else if lines.count - flushedLines >= 5 {
            flush()   // a quit mid-window still leaves what was seen
        }
    }

    /// Something that can change the Map's cost: size, appearance, power, look, rest.
    func event(_ what: String, context: @autoclosure () -> String = "-") {
        guard !done, let start, let lastFrame else { return }
        if what.hasPrefix("rest") { closeSecond(context: context) }   // the second so far, before the Map goes still
        lines.append(String(format: "  t=%.1fs event %@", lastFrame - start, what))
        flush()
    }

    private func closeSecond(context: () -> String) {
        guard !updates.isEmpty else { return }
        let budget = 1000.0 / Double(max(asked, 1))
        let hitches = dts.filter { $0 > budget * 1.5 }.count
        func pct(_ a: [Double], _ p: Double) -> Double {
            let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
        }
        lines.append(String(format: "  t=%2ds frames=%d ask=%d dt p50=%.1f p95=%.1f max=%.1f hitches=%d update p95=%.2f max=%.2f ms | %@",
                            second, updates.count, asked, pct(dts, 0.5), pct(dts, 0.95), dts.max() ?? 0, hitches,
                            pct(updates, 0.95), updates.max() ?? 0, context()))
        dts.removeAll(keepingCapacity: true)
        updates.removeAll(keepingCapacity: true)
    }

    private func flush() {
        let new = lines[flushedLines...].joined(separator: "\n") + "\n"
        flushedLines = lines.count
        guard let url = Self.url else { return }
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += new
        // keep the last ~20 launches (≈ 35 lines each)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.count > 800 { text = all.suffix(700).joined(separator: "\n") }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("MapLaunchFrames.log")
    }
    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
    }
    private static func build() -> String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
}
#endif
