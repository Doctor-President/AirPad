// winid <pid> — the CGWindowID of that process's largest on-screen window (for `screencapture -l`), and its size.
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = mine.max { a, b in
    let ra = a[kCGWindowBounds as String] as! [String: Double], rb = b[kCGWindowBounds as String] as! [String: Double]
    return ra["Width"]! * ra["Height"]! < rb["Width"]! * rb["Height"]!
}
if let w = best, let b = w[kCGWindowBounds as String] as? [String: Double] {
    print("\(w[kCGWindowNumber as String]!) \(Int(b["Width"]!))x\(Int(b["Height"]!))")
} else { exit(1) }
