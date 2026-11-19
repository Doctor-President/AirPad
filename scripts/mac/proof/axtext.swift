// axtext <pid> — every text field / text area in the app's windows: role · id · frame · placeholder · value (escaped)
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func fr(_ e: AXUIElement) -> String {
  var p = CGPoint.zero, s = CGSize.zero
  if let v = a(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
  if let v = a(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
  return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))×\(Int(s.height)))"
}
func walk(_ e: AXUIElement, _ d: Int) {
  let r = a(e, kAXRoleAttribute) as? String ?? ""
  if r == "AXTextField" || r == "AXTextArea" {
    let v = (a(e, kAXValueAttribute) as? String ?? "").replacingOccurrences(of: "\n", with: "\\n")
    print("\(r) · \(a(e, "AXIdentifier") as? String ?? "-") · \(fr(e)) · ph=[\(a(e, "AXPlaceholderValue") as? String ?? "")] · val=[\(v)] · focused=\(a(e, kAXFocusedAttribute).map { "\($0)" } ?? "?")")
  }
  guard d < 40, let k = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
  k.forEach { walk($0, d + 1) }
}
for w in (a(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
