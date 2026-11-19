// cskey <keycode> — a key with ⌘⇧ held as REAL modifiers (⌘ down, ⇧ down … key … ⇧ up, ⌘ up), checked after (N4 ⌘⇧R = 15).
import CoreGraphics
import Foundation
let k = CGKeyCode(CommandLine.arguments[1])!
func post(_ c: CGKeyCode, _ d: Bool, _ f: CGEventFlags) { let e = CGEvent(keyboardEventSource: nil, virtualKey: c, keyDown: d); e?.flags = f; e?.post(tap: .cghidEventTap); usleep(40_000) }
let both: CGEventFlags = [.maskCommand, .maskShift]
post(55, true, .maskCommand); post(56, true, both)
post(k, true, both); post(k, false, both)
post(56, false, .maskCommand); post(55, false, [])
let s = CGEventSource.flagsState(.combinedSessionState)
if s.contains(.maskCommand) || s.contains(.maskShift) { print("WARNING modifier still down") }
print("cmd-shift key \(k)")
