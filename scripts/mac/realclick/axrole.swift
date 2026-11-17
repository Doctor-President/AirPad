// axrole <pid> <AXRole> — every element of that role: title · description · value · identifier · frame (setup aid).
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!, role = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ d: Int) {
    if (a(e, kAXRoleAttribute) as? String) == role {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = a(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = a(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        print("[\(a(e, kAXTitleAttribute) as? String ?? "")] [\(a(e, kAXDescriptionAttribute) as? String ?? "")] value \(a(e, kAXValueAttribute).map { "\($0)" } ?? "-") id \(a(e, "AXIdentifier") as? String ?? "") at \(Int(p.x)),\(Int(p.y)) \(Int(s.width))×\(Int(s.height))")
    }
    guard d < 40, let kids = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    kids.forEach { walk($0, d + 1) }
}
((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).forEach { walk($0, 0) }
