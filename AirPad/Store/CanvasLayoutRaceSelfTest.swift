#if DEBUG
import Foundation

/// live-17 (2c) — `-CanvasLayoutRaceSelfTest` (with `-UITestLibrary -UITestLibraryFresh -LoadLatencyMs 1500`): the
/// cold-launch `canvasLayout` race found in CH-B / live-10. `addNode` copied `canvasLayout` BEFORE its awaits, so a
/// capture made while the launch load was still reading (Quick Capture from the Action Button, cold) started from the
/// EMPTY default layout: it saved `canvas_layout.json` with only its own position (every older one gone from disk),
/// and whichever of the two assignments landed last won in memory. T's `canvas_layout.json` holds 2 positions.
///
/// The real `load()` and the real `addNode` race over a scratch library that already has saved positions:
///   A. a capture made mid-load (the load is held by `-LoadLatencyMs`);
///   B. a capture started just before the load;
///   CONTROL. a capture after the load (no race).
/// Each must keep every older position AND the new one, in memory and on disk. Synthetic entries only.
extension CorpusStore {

    static var canvasLayoutRaceStarted = false

    func runCanvasLayoutRaceSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String) {
            rows.append("\(ok ? "PASS" : "FAIL") \(name) — \(detail)"); if !ok { fails += 1 }
        }
        let now = Date(timeIntervalSince1970: 1_760_400_000)
        func entry(_ id: String) -> Node {
            Node(id: id, createdAt: now, updatedAt: now, title: "Layout race \(id)", summary: "", tags: [], entrySchemaVersion: 4)
        }
        // The library a launch capture meets: 5 entries, each with a saved position.
        let older = (1...5).map { "layout-race-old-\($0)" }
        for (i, id) in older.enumerated() { await addNode(entry(id), position: CGPoint(x: 100 * i, y: 50)) }
        func ms(_ n: UInt64) async { try? await Task.sleep(nanoseconds: n * 1_000_000) }
        let saved = canvasLayout   // the library's layout on disk; every scenario starts from it

        for (label, order) in [("A-capture-mid-load", 0), ("B-capture-just-before-load", 1), ("CONTROL-capture-after-load", 2)] {
            let newID = "layout-race-new-\(order)"
            try? await debugWriteDiskCanvasLayout(saved)  // disk as the library left it
            debugColdLaunchState()                       // memory as at launch
            switch order {
            case 0:
                let loading = Task { await self.load() }
                await ms(150)
                await addNode(entry(newID), position: CGPoint(x: 7, y: 7))
                await loading.value
            case 1:
                let capture = Task { await self.addNode(entry(newID), position: CGPoint(x: 7, y: 7)) }
                await load()
                await capture.value
            default:
                await load()
                await addNode(entry(newID), position: CGPoint(x: 7, y: 7))
            }
            let want = Set(older + [newID])
            let mem = Set(canvasLayout.positions.keys).intersection(want)
            let disk = Set(((try? await debugDiskCanvasLayout())?.positions.keys).map(Array.init) ?? []).intersection(want)
            row("\(label) memory", mem == want, "\(mem.count)/\(want.count) positions (missing \(want.subtracting(mem).sorted()))")
            row("\(label) disk", disk == want, "\(disk.count)/\(want.count) positions (missing \(want.subtracting(disk).sorted()))")
            row("\(label) one entry", nodes.filter { $0.id == newID }.count == 1, "\(nodes.filter { $0.id == newID }.count) copies")
        }
        return "[CanvasLayoutRaceSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
