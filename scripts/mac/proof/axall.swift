// axall <pid> <id> — the frame of EVERY element with that AXIdentifier (rclick find gives only the first)
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!, key = CommandLine.arguments[2]
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ d: Int) {
  if (a(e, "AXIdentifier") as? String) == key {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = a(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = a(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    print(Int(p.x), Int(p.y), Int(s.width), Int(s.height))
  }
  guard d < 40, let k = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
  k.forEach { walk($0, d + 1) }
}
for w in (a(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
