import Foundation

/// Sweep 2b · 4.x — one line per event the real-event proof reads: an `NSLog` "[4x] <item> <line>" in DEBUG or a
/// `-D PERFLOG` bench build launched with `-Sweep4Log YES` (lands in run.sh's app.log), and a perf-recorder mark in
/// builds with the recorder (DEBUG / DEVSWITCHES, while it records). Numbers, kinds and ids only — never a title or a
/// file's real name. An App Store archive compiles both out.
enum MacProofLog {
    @inline(__always) static func note(_ item: StaticString, _ line: @autoclosure () -> String) {
        #if DEBUG || PERFLOG
        if on { NSLog("[4x] %@ %@", "\(item)", line()) }
        #endif
        #if DEBUG || DEVSWITCHES
        Perf.mark("\(item) \(line())")
        #endif
    }
    #if DEBUG || PERFLOG
    static let on = UserDefaults.standard.bool(forKey: "Sweep4Log")
    #endif
}
