import Foundation

/// Mac batch A — the one answer to "is this AirPad on a Mac?". `isMacCatalystApp` is true for the Catalyst build and
/// for the iPhone app run on an Apple silicon Mac (`isiOSAppOnMac` is false under Catalyst, so it can't be used).
enum RunningOnMac {
    static let isMac: Bool = ProcessInfo.processInfo.isMacCatalystApp
}

import SwiftUI

extension View {
    /// Mac batch C6 — Settings and Chats as sheets on the Mac: about 720 × 640, down to 560 × 480 in a small window.
    /// iPhone / iPad: unchanged.
    @ViewBuilder func macSheetSize() -> some View {
        #if targetEnvironment(macCatalyst)
        self.frame(minWidth: 560, idealWidth: 720, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
            .presentationSizing(.fitted)
        #else
        self
        #endif
    }
}

extension View {
    /// Mac fix-up X7 — a sheet's detents. On the Mac a sheet is a fixed-size window sheet with no drag to resize, so
    /// detents only got between a trackpad scroll and the content (T: the Proposals sheet didn't scroll); there it's a
    /// plain sheet whose content scrolls. iPhone / iPad: the detents, unchanged.
    @ViewBuilder func sheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        #if targetEnvironment(macCatalyst)
        self.presentationContentInteraction(.scrolls)
        #else
        self.presentationDetents(detents)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
import UIKit

extension RunningOnMac {
    /// Mac batch C1 — AppKit's window list, through the runtime (Catalyst has no AppKit import).
    private static var appKitWindows: (key: NSObject?, all: [NSObject]) {
        guard let cls = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { return (nil, []) }
        let all = (app.value(forKey: "windows") as? [NSObject] ?? [])
            .filter { ($0.value(forKey: "visible") as? NSNumber)?.boolValue == true }
        return (app.value(forKey: "keyWindow") as? NSObject, all)
    }

    /// File › Close Window: the window's own close, the same as its close button. (For a one-window app UIKit's
    /// `requestSceneSessionDestruction` does nothing, and the system Close item is disabled.)
    @MainActor static func closeFrontWindow() {
        let w = appKitWindows
        guard let window = w.key ?? w.all.first(where: { ($0.value(forKey: "canBecomeMainWindow") as? NSNumber)?.boolValue == true })
        else { return }
        window.perform(NSSelectorFromString("performClose:"), with: nil)
    }

    /// The main window's frame in screen points (DEBUG checks).
    @MainActor static var mainWindowFrame: CGRect? {
        let w = appKitWindows
        guard let window = w.key ?? w.all.first else { return nil }
        return (window.value(forKey: "frame") as? NSValue)?.cgRectValue
    }

    /// Visible app windows (DEBUG checks).
    static var visibleWindowCount: Int { appKitWindows.all.count }
}
#endif

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
            "glassPitchPt: " + [GlassSurface.dashboard, .entry, .list, .carousel, .grid].compactMap { s in
                s.spec.map { "\(s)=\(String(format: "%.2f", GlassGeometry.current.pitchPoints($0)))" } }.joined(separator: " "),
            "minWindow=\(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.sizeRestrictions?.minimumSize }.first.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")",
        ]
        for l in lines { NSLog("[MacReport] %@", l) }
    }

    /// C7 — `-ForceOrientation portrait|upsideDown|landscapeLeft|landscapeRight` (+ `-ForceOrientationAfter <s>`,
    /// default 6): turn the iPad interface after the app is up (a real mid-session rotation, not a launch in landscape),
    /// so the four-orientation stills run headlessly. Logs `[Orientation] <name> → <interfaceOrientation>`.
    @MainActor static func forceOrientationIfAsked() {
        let d = UserDefaults.standard
        guard let name = d.string(forKey: "ForceOrientation"), !name.isEmpty else { return }
        let masks: [String: UIInterfaceOrientationMask] = ["portrait": .portrait, "upsideDown": .portraitUpsideDown,
                                                            "landscapeLeft": .landscapeLeft, "landscapeRight": .landscapeRight]
        guard let mask = masks[name] else { NSLog("[Orientation] unknown %@", name); return }
        let after = d.object(forKey: "ForceOrientationAfter") == nil ? 6 : d.double(forKey: "ForceOrientationAfter")
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { NSLog("[Orientation] %@ failed: %@", name, "\($0)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSLog("[Orientation] %@ → %ld bounds=%@", name, scene.effectiveGeometry.interfaceOrientation.rawValue,
                      "\(scene.effectiveGeometry.coordinateSpace.bounds.size)")
            }
        }
    }

    /// `-MacSnapshot <name>` (+ `-MacSnapshotAfter <s>`, default 12) — the key window drawn in-process to
    /// `<tmp>/macshots/<name>.png` (inside the sandbox container), logged as `[MacSnapshot] <path>`. Works with the
    /// screen locked, where `screencapture` returns black.
    @MainActor static func snapshotIfAsked() {
        let d = UserDefaults.standard
        guard let name = d.string(forKey: "MacSnapshot"), !name.isEmpty else { return }
        let after = d.object(forKey: "MacSnapshotAfter") == nil ? 12 : d.double(forKey: "MacSnapshotAfter")
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { snapshot(name) }
    }

    /// The window (and each sheet) drawn in-process to `<tmp>/macshots/<name>.png`; returns the main image's path.
    @discardableResult @MainActor static func snapshot(_ name: String) -> String? {
        do {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let w = windows.first(where: \.isKeyWindow) ?? windows.max(by: { $0.bounds.width < $1.bounds.width }) else {
                NSLog("[MacSnapshot] no window"); return nil
            }
            for win in windows {
                var chain: [String] = []; var vc = win.rootViewController?.presentedViewController
                while let v = vc { chain.append("\(type(of: v)) inWindow=\(v.view.window === win) frame=\(v.view.frame)"); vc = v.presentedViewController }
                NSLog("[MacSnapshot] window %@ level=%.0f hidden=%d key=%d frame=%@ presented=%@", "\(type(of: win))", win.windowLevel.rawValue,
                      win.isHidden ? 1 : 0, win.isKeyWindow ? 1 : 0, "\(win.frame)", chain.joined(separator: " → "))
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
            // Catalyst hosts a sheet outside the UIWindow (its view isn't in `win`), so each presented controller is
            // drawn on its own: `<name>-sheet1.png`, … (written first; the main image's log line is the "done" signal).
            var k = 0, vc = w.rootViewController?.presentedViewController
            while let v = vc {
                k += 1
                let sheet = UIGraphicsImageRenderer(bounds: v.view.bounds, format: format).image { _ in
                    // false: forcing an update re-runs the detached sheet's SwiftUI body outside its environment
                    // (Settings → "No Observable object of type CorpusStore"); the last drawn frame is what we want.
                    v.view.drawHierarchy(in: v.view.bounds, afterScreenUpdates: false)
                }
                let su = dir.appendingPathComponent("\(name)-sheet\(k).png")
                try? sheet.pngData()?.write(to: su); NSLog("[MacSnapshot] sheet %@ %@", "\(type(of: v))", su.path)
                vc = v.presentedViewController
            }
            do { try img.pngData()?.write(to: url); NSLog("[MacSnapshot] %@", url.path); return url.path }
            catch { NSLog("[MacSnapshot] write failed: %@", "\(error)"); return nil }
        }
    }
}
#endif
