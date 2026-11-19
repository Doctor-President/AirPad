// skey — a key with ⇧ held as a REAL modifier (⇧ down … key … ⇧ up), checked after.  skey <keycode> (36 = Return)
import CoreGraphics
import Foundation
let k = CGKeyCode(CommandLine.arguments[1])!, sh = CGKeyCode(56)
let sd = CGEvent(keyboardEventSource: nil, virtualKey: sh, keyDown: true); sd?.flags = .maskShift; sd?.post(tap: .cghidEventTap); usleep(40_000)
for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: down); e?.flags = .maskShift; e?.post(tap: .cghidEventTap); usleep(40_000) }
let su = CGEvent(keyboardEventSource: nil, virtualKey: sh, keyDown: false); su?.flags = []; su?.post(tap: .cghidEventTap); usleep(40_000)
if CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) { print("WARNING shift still down") }
print("shift key \(k)")
