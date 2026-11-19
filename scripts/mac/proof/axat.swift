// axat <pid> <x> <y> — the AX element at that global point (AXUIElementCopyElementAtPosition) and its ancestors: role · id · desc · frame
import ApplicationServices
import Foundation
let g = CommandLine.arguments, app = AXUIElementCreateApplication(pid_t(g[1])!)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func fr(_ e: AXUIElement) -> String { var p = CGPoint.zero, s = CGSize.zero
  if let v = a(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; if let v = a(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
  return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))×\(Int(s.height)))" }
var hit: AXUIElement?; guard AXUIElementCopyElementAtPosition(app, Float(g[2])!, Float(g[3])!, &hit) == .success, var e = hit else { print("none"); exit(1) }
for d in 0..<(Int(g.count > 4 ? g[4] : "6") ?? 6) { let t = [a(e, kAXRoleAttribute), a(e, "AXIdentifier"), a(e, kAXDescriptionAttribute), a(e, kAXTitleAttribute), a(e, kAXValueAttribute)].map { ($0 as? String).map { String($0.prefix(40)) } ?? "-" }
  print("\(d == 0 ? "AT" : "^\(d)") \(t[0]) · id=\(t[1]) · desc=\(t[2]) · title=\(t[3]) · val=\(t[4]) · \(fr(e))"); guard let p = a(e, kAXParentAttribute) else { break }; e = p as! AXUIElement }
