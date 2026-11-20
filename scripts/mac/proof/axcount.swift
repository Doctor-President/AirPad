// axcount <pid> <text> [minX=0] [minY maxY] [v] — prints "<in tree> <on screen>": how many elements in the app's windows carry <text> (case-insensitive) in their value,
// title, label or description, left edge ≥ minX (screen points). Text fields are skipped (the Ask field holds the typed copy).
// sweep 1 · 1.2: the chat bubbles are static text, which axtext (fields only) never saw.
import ApplicationServices
import Foundation
let args = CommandLine.arguments
let pid = pid_t(args[1])!, needle = args[2].lowercased(), minX = args.count > 3 ? Double(args[3])! : 0
let minY = args.count > 5 ? Double(args[4])! : -1e9, maxY = args.count > 5 ? Double(args[5])! : 1e9, verbose = args.count > 6
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
var n = 0, vis = 0
func walk(_ e: AXUIElement, _ d: Int) {
  let r = a(e, kAXRoleAttribute) as? String ?? ""
  if r != "AXTextField" && r != "AXTextArea" {   // the Ask field (multi-line) holds the typed copy too
    var p = CGPoint.zero; if let v = a(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    let s = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].compactMap { a(e, $0) as? String }.joined(separator: " ").lowercased()
    if Double(p.x) >= minX && s.contains(needle) {
      var z = CGSize.zero; if let v = a(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &z) }
      n += 1; if Double(p.y) >= minY && Double(p.y + z.height) <= maxY && z.height > 0 { vis += 1 }
      if verbose { print(r, p, z, s.prefix(80)) } }
  }
  // prune: a subtree whose frame lies wholly left of minX (sidebar, the list's 284 rows) is never walked — keeps a sample
  // near 50 ms instead of ~0.3–0.9 s
  if minX > 0, let v = a(e, kAXPositionAttribute), let w = a(e, kAXSizeAttribute) {
    var p = CGPoint.zero, z = CGSize.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); AXValueGetValue(w as! AXValue, .cgSize, &z)
    if z.width > 0 && Double(p.x + z.width) < minX { return }
  }
  guard d < 60, let k = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
  k.forEach { walk($0, d + 1) }
}
for w in (a(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
print(n, vis)
