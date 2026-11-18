// locked — prints "locked 1|0" (CGSSessionScreenIsLocked) and whether this shell may post events. (E fix-up 5)
import CoreGraphics
import ApplicationServices
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("locked \((d["CGSSessionScreenIsLocked"] as? Int) ?? 0) ax \(AXIsProcessTrusted() ? 1 : 0) post \(CGPreflightPostEventAccess() ? 1 : 0)")
