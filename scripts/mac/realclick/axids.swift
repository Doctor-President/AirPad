import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ d: Int) {
  if let id = a(e, "AXIdentifier") as? String, !id.isEmpty { print(id) }
  if let r = a(e, kAXRoleAttribute) as? String, r == "AXSheet" || r == "AXWindow" { print("role:" + r) }
  guard d < 40, let kids = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
  kids.forEach { walk($0, d + 1) }
}
let app = AXUIElementCreateApplication(pid)
for w in (a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
