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
}
#endif
