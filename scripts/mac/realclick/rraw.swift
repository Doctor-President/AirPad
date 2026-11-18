// rraw — a REAL click at a global point with no owner check (E fix-up 6, M2): for the system's own windows (the
// Picture in Picture window belongs to PIPAgent, which rclick refuses as "covered").   rraw <x> <y>
import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().compactMap(Double.init); let p = CGPoint(x: a[0], y: a[1])
for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(t == .mouseMoved ? 250_000 : 60_000) }
print("raw click (\(Int(p.x)),\(Int(p.y)))")
