// Sweep 2b · 4.6 — headless check of MacLibraryKeeper's scan and throttle on a LOCAL scratch folder (never iCloud, never
// the library). Compiled for Mac Catalyst with -D PERFLOG -D DEVSWITCHES (the fake-evicted mode and the switch key).
// Run: zsh scripts/mac/perf/4x/keeper_test.sh
import Foundation

/// The app's perf recorder is not compiled here; MacProofLog's mark goes nowhere.
enum Perf { static func mark(_ name: @autoclosure () -> String) {} }

var fails = 0, passes = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if ok { passes += 1 } else { fails += 1 }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("4x-keeper-test-\(getpid())")
try! fm.createDirectory(at: root.appendingPathComponent("nodes/A/items"), withIntermediateDirectories: true)
for i in 0..<50 { try! Data(repeating: 7, count: 1000 + i).write(to: root.appendingPathComponent("nodes/A/items/f\(i).bin")) }
try! Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("nodes/A/.hidden"))
// an old-style placeholder for a missing file
try! Data().write(to: root.appendingPathComponent("nodes/A/items/.gone.jpg.icloud"))

let s = MacLibraryKeeper.scan(root: root)
check("scan-counts-files", s.files == 52, "\(s.line)")
check("scan-local-not-icloud", s.iCloudFiles == 1 && s.evicted.map(\.lastPathComponent) == ["gone.jpg"], "\(s.line) \(s.evicted.map(\.lastPathComponent))")
let wantBytes: Int = (0..<50).reduce(0) { (a: Int, i: Int) -> Int in a + 1000 + i } + 10
check("scan-bytes", s.bytes == Int64(wantBytes), "\(s.bytes)")
let f = MacLibraryKeeper.scan(root: root, fakeEvictedEvery: 3)
check("scan-fake-every-3rd", f.evicted.count == 1 + 51 / 3, "\(f.evicted.count)")

// Throttle: fake mode → 17 + 1 evicted in batches of 16 → 2 batches; never on the main thread.
UserDefaults.standard.set(true, forKey: "KeeperFakeEvicted")
UserDefaults.standard.set(true, forKey: MacKeepDownloaded.key)
let sem = DispatchSemaphore(value: 0)
var summary = ""
Task.detached { summary = await MacLibraryKeeper.run(root: root, reason: "test"); sem.signal() }
sem.wait()
check("run-batches", summary.contains("in 2 batch(es)") && !summary.contains("STOPPED"), summary)
// Switch off → the sweep stops before its first batch.
UserDefaults.standard.set(false, forKey: MacKeepDownloaded.key)
Task.detached { summary = await MacLibraryKeeper.run(root: root, reason: "off"); sem.signal() }
sem.wait()
check("switch-off-stops", summary.contains("requested 0") && summary.contains("STOPPED"), summary)
check("default-on", { UserDefaults.standard.removeObject(forKey: MacKeepDownloaded.key); return MacKeepDownloaded.isOn }())
// The scan never wrote anything: the folder's files and dates are unchanged.
let after = MacLibraryKeeper.scan(root: root)
check("read-only", after.files == s.files && after.bytes == s.bytes)
UserDefaults.standard.removeObject(forKey: "KeeperFakeEvicted")
try? fm.removeItem(at: root)
print("\n\(fails == 0 ? "PASS" : "FAIL") \(passes)/\(passes + fails)")
exit(fails == 0 ? 0 : 1)
