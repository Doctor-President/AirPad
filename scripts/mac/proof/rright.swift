// rright <x> <y> — a REAL right click (secondary button down/up) at a global point (sweep-1 N16: a context menu).
import CoreGraphics
import Foundation
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(120_000)
for t in [CGEventType.rightMouseDown, .rightMouseUp] {
  let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)
  e?.setIntegerValueField(.mouseEventClickState, value: 1); e?.post(tap: .cghidEventTap); usleep(80_000)
}
print("right-clicked at (\(Int(p.x)),\(Int(p.y)))")
