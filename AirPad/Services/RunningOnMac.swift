import Foundation

/// Mac batch A — the one answer to "is this AirPad on a Mac?". `isMacCatalystApp` is true for the Catalyst build and
/// for the iPhone app run on an Apple silicon Mac (`isiOSAppOnMac` is false under Catalyst, so it can't be used).
enum RunningOnMac {
    static let isMac: Bool = ProcessInfo.processInfo.isMacCatalystApp
}

#if DEBUG
import UIKit

extension RunningOnMac {
    /// `-MacReport` — one log line per Mac-sensitive answer, for the Mac launch check (no input automation there).
    @MainActor static func report() {
        let lines = [
            "isMac=\(isMac) deviceNoun=\(ModelRouter.deviceNoun)",
            "cameraAvailable=\(CameraCaptureView.cameraAvailable) motionAvailable=\(FlutedGlass.shared.motionAvailable) tiltRunning=\(FlutedGlass.shared.tiltRunning)",
            "displaySize=\(Int(DisplaySize.screenWidth))x\(Int(DisplaySize.screenHeight)) screen=\(Int(DisplaySize.screen?.bounds.width ?? 0))x\(Int(DisplaySize.screen?.bounds.height ?? 0)) scale=\(DisplaySize.scale)",
            "lock: method=\(AppLock.shared.method) require=\"\(AppLock.shared.requireLabel)\" unlock=\"\(AppLock.shared.unlockLabel)\"",
            "localModel.isAvailable=\(LocalModelService.shared.isAvailable)",
            "minWindow=\(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.sizeRestrictions?.minimumSize }.first.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")",
        ]
        for l in lines { NSLog("[MacReport] %@", l) }
    }

    /// `-MacSnapshot <name>` (+ `-MacSnapshotAfter <s>`, default 12) — the key window drawn in-process to
    /// `<tmp>/macshots/<name>.png` (inside the sandbox container), logged as `[MacSnapshot] <path>`. Works with the
    /// screen locked, where `screencapture` returns black.
    @MainActor static func snapshotIfAsked() {
        let d = UserDefaults.standard
        guard let name = d.string(forKey: "MacSnapshot"), !name.isEmpty else { return }
        let after = d.object(forKey: "MacSnapshotAfter") == nil ? 12 : d.double(forKey: "MacSnapshotAfter")
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let w = windows.first(where: \.isKeyWindow) ?? windows.max(by: { $0.bounds.width < $1.bounds.width }) else {
                NSLog("[MacSnapshot] no window"); return
            }
            // Every window of the scene, bottom to top (the lock/tuner windows and sheets sit in their own windows).
            let format = UIGraphicsImageRendererFormat(); format.scale = w.screen.scale
            let img = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { _ in
                for win in windows.sorted(by: { $0.windowLevel < $1.windowLevel }) where !win.isHidden {
                    win.drawHierarchy(in: win.frame, afterScreenUpdates: true)
                }
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(name).png")
            do { try img.pngData()?.write(to: url); NSLog("[MacSnapshot] %@", url.path) }
            catch { NSLog("[MacSnapshot] write failed: %@", "\(error)") }
        }
    }
}
#endif
