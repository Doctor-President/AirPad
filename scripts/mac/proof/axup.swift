// axup <pid> <id> — the element with that AXIdentifier and its ancestors: role · id · frame (to find a container's frame)
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!, key = CommandLine.arguments[2]
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func fr(_ e: AXUIElement) -> String {
  var p = CGPoint.zero, s = CGSize.zero
  if let v = a(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
  if let v = a(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
  return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))×\(Int(s.height)))"
}
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
  if (a(e, "AXIdentifier") as? String) == key { return e }
  guard d < 40, let k = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
  for c in k { if let f = find(c, d + 1) { return f } }
  return nil
}
for w in (a(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
  guard var e = find(w, 0) else { continue }
  for _ in 0..<8 {
    print("\(a(e, kAXRoleAttribute) as? String ?? "?") · \(a(e, "AXIdentifier") as? String ?? "-") · \(fr(e)) · kids \((a(e, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0)")
    guard let p = a(e, kAXParentAttribute) else { break }; e = p as! AXUIElement
  }
  break
}
