// pfront <pid> [nofront] — bring the app forward (unless nofront) and print its largest on-screen window's CGWindowID
// (for `screencapture -l <id>`, which captures that window even when another app covers it).
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
if !CommandLine.arguments.contains("nofront") { NSRunningApplication(processIdentifier: pid)?.activate(); usleep(400_000) }
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = mine.max { a, b in
  let ra = a[kCGWindowBounds as String] as? [String: Double] ?? [:], rb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
  return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0) }
print(best?[kCGWindowNumber as String] as? Int ?? 0)
