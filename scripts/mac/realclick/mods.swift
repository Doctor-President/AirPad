import CoreGraphics
let f = CGEventSource.flagsState(.combinedSessionState)
let h = CGEventSource.flagsState(.hidSystemState)
print("combined \(String(f.rawValue, radix: 16)) cmd \(f.contains(.maskCommand)) · hid \(String(h.rawValue, radix: 16)) cmd \(h.contains(.maskCommand))")
