// rdraghold — a REAL press-hold-drag (E fix-up 5, L3): mouse down at (x,y), hold `hold` ms, move to (x+dx,y+dy) in
// `steps` over `ms`, optionally linger there, release. Starts a UIKit drag (text selection, an image) where a quick
// rclick drag only extends a selection.   rdraghold <x> <y> <dx> <dy> [hold=600] [ms=900] [steps=30] [linger=300]
import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count >= 4 else { print("usage: rdraghold x y dx dy [hold ms steps linger]"); exit(2) }
let (x, y, dx, dy) = (a[0], a[1], a[2], a[3]); let hold = a.count > 4 ? a[4] : 600, ms = a.count > 5 ? a[5] : 900
let steps = Int(a.count > 6 ? a[6] : 30), linger = a.count > 7 ? a[7] : 300
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
let p = CGPoint(x: x, y: y)
post(.mouseMoved, p); usleep(150_000); post(.leftMouseDown, p); usleep(useconds_t(hold * 1000))
for i in 1...steps { post(.leftMouseDragged, CGPoint(x: x + dx * Double(i) / Double(steps), y: y + dy * Double(i) / Double(steps))); usleep(useconds_t(ms * 1000 / Double(steps))) }
usleep(useconds_t(linger * 1000)); post(.leftMouseUp, CGPoint(x: x + dx, y: y + dy)); usleep(300_000)
print("held \(Int(hold)) ms, dragged (\(Int(x)),\(Int(y))) → (\(Int(x + dx)),\(Int(y + dy)))")
