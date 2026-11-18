// rrec — record an app's window to a .mov at 60 fps (Mac E fix-up 5, L2: the orb → card morph before / after for T).
// ScreenCaptureKit's recording output over the window's rect on its display, cursor shown. Needs Screen Recording.
//   rrec <pid> <seconds> <out.mov>
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[1]), let secs = Double(args[2]) else { print("usage: rrec <pid> <seconds> <out.mov>"); exit(2) }
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: out)
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
guard let win = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first else { print("no window"); exit(1) }
var p = CGPoint.zero, s = CGSize.zero
if let pv = a(win, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
if let sv = a(win, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
let winRect = CGRect(origin: p, size: s)
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.frame.contains(winRect.origin) }) ?? content.displays.first else { exit(1) }
let cfg = SCStreamConfiguration()
cfg.sourceRect = winRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
cfg.width = Int(winRect.width); cfg.height = Int(winRect.height)
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
cfg.queueDepth = 8
cfg.showsCursor = true
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
let rc = SCRecordingOutputConfiguration()
rc.outputURL = out
rc.outputFileType = .mov
final class Del: NSObject, SCRecordingOutputDelegate {}
let rec = SCRecordingOutput(configuration: rc, delegate: Del())
try stream.addRecordingOutput(rec)
try await stream.startCapture()
print("recording \(Int(winRect.width))×\(Int(winRect.height)) at 60 fps for \(secs) s → \(out.path)")
try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
try await stream.stopCapture()
try await Task.sleep(nanoseconds: 500_000_000)
print("done")
