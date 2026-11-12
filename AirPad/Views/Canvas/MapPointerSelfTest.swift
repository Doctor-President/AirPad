#if DEBUG
import UIKit

/// Mac batch C2 — `-MapPointerSelfTest` (with `-OpenMap`): the Map on a trackpad / mouse / keyboard. Drives the SAME
/// scene paths the recognisers call (pinch → zoom around the cursor, scroll → pan, hover → ring + title), fires View ›
/// Zoom In / Out / to Fit through the real menu on the Mac (the router elsewhere), and checks the Map goes back to
/// 0 frames at rest after each. Real trackpad magnify events: -MapPinchReplaySelfTest below; the feel is T's check.
@MainActor
enum MapPointerSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tol }
        func f(_ p: CGPoint) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }
        func atRest(_ label: String) async {
            var paused = false
            for _ in 0..<20 { await settle(0.25); if CorpusPhysicsScene.debugCurrent?.debugRestPaused == true { paused = true; break } }
            row("rest/\(label) → paused (0 frames)", paused)
        }

        guard let scene = CorpusPhysicsScene.debugCurrent else { return "[MapPointerSelfTest] FAIL — no Map" }
        row("recognizers on the Map's view", scene.debugRecognizers.contains("pinch") && scene.debugRecognizers.contains("scroll")
            && scene.debugRecognizers.contains("hover"), scene.debugRecognizers)
        await atRest("before")

        // Pick an orb near the middle of the view.
        let size = scene.view?.bounds.size ?? .zero
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let ids = scene.debugOrbIDs
        let pick = ids.compactMap { id in scene.debugOrbViewPoint(id).map { (id, $0) } }
            .filter { $0.1.x > 80 && $0.1.x < size.width - 80 && $0.1.y > 80 && $0.1.y < size.height - 80 }
            .min { hypot($0.1.x - mid.x * 0.6, $0.1.y - mid.y) < hypot($1.1.x - mid.x * 0.6, $1.1.y - mid.y) }
        guard let (orb, p0) = pick else {
            let pts = ids.prefix(5).compactMap { scene.debugOrbViewPoint($0) }.map(f).joined(separator: " ")
            return "[MapPointerSelfTest] FAIL — no orb on screen (orbs=\(ids.count) view=\(size) settled=\(router.mapSettled) sample=\(pts))"
        }

        // 1. Pinch (zoom around the cursor): the scene point under the cursor stays put.
        let under0 = scene.debugSceneUnder(p0), s0 = scene.debugCamera.scale
        scene.debugPointerGesture { $0.debugPointerZoom(by: 0.8, at: p0); $0.debugPointerZoom(by: 0.8, at: p0) }
        let s1 = scene.debugCamera.scale, under1 = scene.debugSceneUnder(p0)
        row("pinch in zooms around the cursor", s1 < s0 * 0.7 && near(under0, under1, 1.5),
            "scale \(String(format: "%.3f→%.3f", s0, s1)) under-cursor \(f(under0))→\(f(under1))")
        let pOrb = scene.debugOrbViewPoint(orb) ?? .zero
        row("the orb under the cursor stays under it", near(pOrb, p0, 3), "\(f(p0))→\(f(pOrb))")
        await atRest("after pinch")
        scene.debugPointerGesture { $0.debugPointerZoom(by: 1.5625, at: p0) }
        row("pinch out restores the scale", abs(scene.debugCamera.scale - s0) < 0.01, String(format: "%.3f", scene.debugCamera.scale))

        // 2. Two-finger scroll / wheel pans like a finger drag (content follows the fingers).
        let c0 = scene.debugCamera.position, sc = scene.debugCamera.scale
        scene.debugPointerGesture { $0.debugPointerPan(by: CGPoint(x: 60, y: -40)) }
        let c1 = scene.debugCamera.position
        row("scroll pans", near(c1, CGPoint(x: c0.x - 60 * 1.5 * sc, y: c0.y - 40 * 1.5 * sc), 1.0), "\(f(c0))→\(f(c1))")
        scene.debugPointerGesture { $0.debugPointerPan(by: CGPoint(x: -60, y: 40)) }
        await atRest("after scroll")

        // 3. Keyboard zoom: View › Zoom In / Out / to Fit.
        func fire(_ c: AppCommand) async {
            #if targetEnvironment(macCatalyst)
            let title = c == .zoomIn ? "Zoom In" : c == .zoomOut ? "Zoom Out" : "Zoom to Fit"
            if MacMenuSelfTest.fire(menu: "View", title: title) { await settle(0.8); return }
            row("menu/View›\(title) present + enabled", false)
            #endif
            router.perform(c); await settle(0.8)
        }
        let k0 = scene.debugCamera.scale
        await fire(.zoomIn)
        row("⌘+ zooms in 1.5×", abs(scene.debugCamera.scale - max(k0 / 1.5, 0.25)) < 0.01, String(format: "%.3f→%.3f", k0, scene.debugCamera.scale))
        await fire(.zoomOut)
        row("⌘− zooms back out", abs(scene.debugCamera.scale - k0) < 0.01, String(format: "%.3f", scene.debugCamera.scale))
        await fire(.zoomFit)
        let fitScale = scene.debugCamera.scale
        await fire(.zoomIn); await fire(.zoomFit)
        row("⌘9 fits the whole library (same framing each time)", abs(scene.debugCamera.scale - fitScale) < 0.01,
            String(format: "scale %.3f", fitScale))
        await atRest("after keyboard zoom")

        // 4. Hover: ring + the orb's title; leaving clears it; the Map rests again.
        let target = scene.debugOrbIDs.compactMap { id in scene.debugOrbViewPoint(id).map { (id, $0) } }
            .filter { $0.1.x > 40 && $0.1.x < size.width - 40 && $0.1.y > 40 && $0.1.y < size.height - 40 }
            .first { id, _ in !(store.nodes.first { $0.id == id }?.title ?? "").isEmpty }
        if let (hid, hp) = target {
            scene.debugPointerHover(at: hp)
            let want = store.nodes.first { $0.id == hid }?.title ?? ""
            row("hover shows the ring + title", scene.debugHoveredOrbID == hid && scene.debugHoverTitle == want,
                "hovered=\(scene.debugHoveredOrbID == hid) title=\(scene.debugHoverTitle == want)")
            await atRest("while hovering")
            scene.debugPointerHover(at: CGPoint(x: 5, y: 5))
            row("pointer off the orb clears it", scene.debugHoveredOrbID == nil)
            scene.debugPointerHover(at: hp); scene.debugPointerHover(at: nil)
            row("pointer leaving the Map clears it", scene.debugHoveredOrbID == nil)
            await atRest("after hover")
        } else {
            row("hover target on screen", false)
        }
        return "[MapPointerSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
import CoreGraphics

/// Mac fix-up X1 — `-MapPinchReplaySelfTest` (with `-OpenMap`): replays trackpad MAGNIFY events into the app's own
/// window (a CGEvent of the gesture type with the zoom HID type → `NSEvent eventWithCGEvent:` → `NSApp sendEvent:`, all
/// in-process: nothing is posted to the system), so the real Catalyst pinch recogniser and the Map's handler run on
/// them. Logs per event: magnification sent, the recogniser's scale, the camera's scale; checks the curve.
@MainActor
enum MapPinchReplaySelfTest {
    private static var app: NSObject? {
        (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject
    }

    /// The NSWindow hosting `view`, and `p` (view points) in global CG coordinates (top-left origin).
    private static func globalPoint(_ p: CGPoint, in view: UIView) -> (NSObject, CGPoint)? {
        guard let app, let windows = app.value(forKey: "windows") as? [NSObject],
              let ns = windows.first(where: { ($0.value(forKey: "isVisible") as? NSNumber)?.boolValue == true
                  && String(describing: type(of: $0)).contains("UINSWindow") }) ?? windows.first,
              let uiWindow = view.window else { return nil }
        let inWin = view.convert(p, to: uiWindow)
        // UIKit window points = the NSWindow's content area (top-left), so flip by the content height.
        let content = (ns.value(forKey: "contentView") as? NSObject)?.value(forKey: "frame") as? CGRect ?? .zero
        let frame = ns.value(forKey: "frame") as? CGRect ?? .zero
        let screenY = frame.origin.y + content.height - inWin.y   // AppKit screen (bottom-left)
        let screenX = frame.origin.x + inWin.x
        let primary = ((NSClassFromString("NSScreen") as? NSObject.Type)?.value(forKey: "screens") as? [NSObject])?.first?
            .value(forKey: "frame") as? CGRect ?? .zero
        return (ns, CGPoint(x: screenX, y: primary.height - screenY))
    }

    /// One magnify event (`phase`: 1 began, 2 changed, 4 ended — IOHID phases), dispatched like the window server's.
    private static func send(_ magnification: Double, phase: Int64, at global: CGPoint, window: NSObject) -> Bool {
        guard let e = CGEvent(source: nil), let gestureType = CGEventType(rawValue: 29) else { return false }
        e.type = gestureType                                              // NSEventTypeGesture
        e.location = global
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)    // gesture HID type: zoom
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        guard let cls = NSClassFromString("NSEvent") as? NSObject.Type,
              let ev = cls.perform(NSSelectorFromString("eventWithCGEvent:"), with: e)?.takeUnretainedValue() as? NSObject,
              let _ = app else { return false }
        // Into the window (its sendEvent: hit-tests and hands the magnify to UIKit). NSApp's sendEvent: drops a
        // window-less gesture, and naming the window in the event makes AppKit ignore the event's location.
        window.perform(NSSelectorFromString("sendEvent:"), with: ev)
        return true
    }

    static func run() async -> String {
        guard let scene = CorpusPhysicsScene.debugCurrent, let view = scene.view else { return "[MapPinchReplaySelfTest] FAIL — no Map" }
        let mid = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let (window, _) = globalPoint(mid, in: view) else { return "[MapPinchReplaySelfTest] FAIL — no NSWindow" }
        // A gesture event happens where the cursor IS (AppKit takes its location from the cursor, not the event), and this
        // test never moves the user's cursor: it moves its own (isolated) window so the Map's middle sits under it.
        let mouse = (NSClassFromString("NSEvent") as? NSObject.Type)?.value(forKey: "mouseLocation") as? CGPoint ?? .zero
        if let frame = window.value(forKey: "frame") as? CGRect,
           let content = (window.value(forKey: "contentView") as? NSObject)?.value(forKey: "frame") as? CGRect,
           let inWin = view.window.map({ view.convert(mid, to: $0) }) {
            let origin = CGPoint(x: mouse.x - inWin.x, y: mouse.y - (content.height - inWin.y))
            typealias SetOrigin = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let sel = NSSelectorFromString("setFrameOrigin:")
            unsafeBitCast(window.method(for: sel), to: SetOrigin.self)(window, sel, origin)
            _ = frame
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let (_, g) = globalPoint(mid, in: view) else { return "[MapPinchReplaySelfTest] FAIL — no NSWindow" }
        var lines: [String] = ["window=\(String(describing: type(of: window))) mid=\(mid) global=\(g)"]
        var fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(detail)"); if !ok { fails += 1 } }

        /// A pinch: `deltas` per 1/60 s frame. Returns (sent, recogniser scale, camera) per event.
        func pinch(_ name: String, _ deltas: [Double], _ ms: UInt64) async -> [(Double, CGFloat, CGFloat, Int)] {
            MapPointerInput.debugPinchLog.removeAll()
            let start = scene.debugCamera.scale
            var out: [(Double, CGFloat, CGFloat, Int)] = []
            _ = send(0, phase: 1, at: g, window: window)
            try? await Task.sleep(nanoseconds: 16_000_000)
            for d in deltas {
                let n0 = MapPointerInput.debugPinchLog.count
                _ = send(d, phase: 2, at: g, window: window)
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                let new = MapPointerInput.debugPinchLog[n0...]
                out.append((d, new.last?.scale ?? -1, scene.debugCamera.scale, new.count))
            }
            _ = send(0, phase: 4, at: g, window: window)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let sumMag = deltas.reduce(0, +)
            lines.append("\(name): start=\(String(format: "%.4f", start)) end=\(String(format: "%.4f", scene.debugCamera.scale)) Σmag=\(String(format: "%.3f", sumMag)) events=\(deltas.count) handlerCalls=\(MapPointerInput.debugPinchLog.count)")
            lines.append("  per event (mag → recogniser scale → camera): " + out.map {
                String(format: "%.3f→%.4f→%.4f%@", $0.0, $0.1, $0.2, $0.3 == 1 ? "" : "(\($0.3) calls)")
            }.joined(separator: "  "))
            return out
        }
        // Sequences at mid zoom: (name, per-event magnification, ms between events).
        let seqs: [(String, [Double], UInt64)] = [
            ("small slow in", Array(repeating: 0.004, count: 40), 16),
            ("small slow out", Array(repeating: -0.004, count: 40), 16),
            ("medium out", Array(repeating: -0.02, count: 20), 16),
            ("medium out, 8 ms", Array(repeating: -0.02, count: 20), 8),
            ("medium in, 33 ms", Array(repeating: 0.02, count: 20), 33),
            ("fast in", Array(repeating: 0.08, count: 8), 16),
            ("fast out", Array(repeating: -0.08, count: 8), 16),
            ("in then out", Array(repeating: 0.02, count: 10) + Array(repeating: -0.02, count: 20), 16),
            ("long out", Array(repeating: -0.05, count: 50), 8),
        ]
        for (name, deltas, ms) in seqs {
            let start: CGFloat = name == "long out" ? 0.25 : 1.0   // room for Σ −2.5 before the 4.0 limit
            router(scale: start, scene: scene); try? await Task.sleep(nanoseconds: 500_000_000)
            let seq = await pinch(name, deltas, ms)
            // Every event moves the zoom (no dead zone), opposite to its magnification (no reversal), by a step close to
            // −Δmag in ln(scale) (no compounding: the step doesn't grow along the gesture).
            let cams = [start] + seq.map(\.2)
            let steps = zip(cams.dropFirst(), cams).map { Double(log($0 / $1)) }
            let moved = steps.filter { abs($0) > 1e-5 }.count
            let ratios = zip(steps, deltas).map { -$0 / $1 }   // 1 = exactly −Δmag
            let mono = ratios.allSatisfy { $0 > 0 }
            row("\(name): every event moves the zoom", moved == seq.count, "\(moved)/\(seq.count)")
            row("\(name): each step follows its event's direction", mono, "")
            row("\(name): proportional (ln step / −Δmag within 0.85…1.15)", ratios.allSatisfy { $0 > 0.85 && $0 < 1.15 },
                String(format: "ratio min %.2f max %.2f", ratios.min() ?? 0, ratios.max() ?? 0))
        }
        await settleRest(scene)
        row("rest after pinches → paused (0 frames)", scene.debugRestPaused, "")
        return "[MapPinchReplaySelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(fails) fail\n" + lines.joined(separator: "\n")
    }

    private static func router(scale: CGFloat, scene: CorpusPhysicsScene) { scene.debugSetCameraScale(scale) }
    private static func settleRest(_ scene: CorpusPhysicsScene) async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 250_000_000); if scene.debugRestPaused { return } }
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
/// Mac fix-up X2 — `-MapHoverStillsSelfTest` (with `-OpenMap`, light or dark): hovers an orb at max zoom-out, the
/// opening zoom and max zoom-in, measures the ring + tag in view points and writes a still of each
/// (`<tmp>/macshots/hover-<zoom>-<look>.png`). Crisp = drawn in screen space (camera children) at a constant size.
@MainActor
enum MapHoverStillsSelfTest {
    static func run(look: String) async -> String {
        guard let scene = CorpusPhysicsScene.debugCurrent, let view = scene.view else { return "[MapHoverStillsSelfTest] FAIL — no Map" }
        var lines: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name) — \(detail)"); if !ok { fails += 1 } }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let opening = scene.debugCamera.scale
        let mid = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        // The orb with a title nearest the middle and the most neighbours close by (the case T saw).
        let titled = Set(scene.debugTitledOrbIDs)
        guard let pick = scene.debugOrbIDs.filter({ titled.contains($0) }).compactMap({ id -> (String, Int)? in
            guard let p = scene.debugOrbViewPoint(id) else { return nil }
            let n = scene.debugOrbIDs.filter { $0 != id && (scene.debugOrbViewPoint($0).map { hypot($0.x - p.x, $0.y - p.y) < 160 } ?? false) }.count
            return hypot(p.x - mid.x, p.y - mid.y) < 260 ? (id, n) : nil
        }).max(by: { $0.1 < $1.1 })?.0 else { return "[MapHoverStillsSelfTest] FAIL — no titled orb near the middle" }
        var labelHeights: [CGFloat] = []
        for (zname, scale) in [("max-out", CGFloat(4.0)), ("mid-out", CGFloat(2.0)), ("opening", opening), ("max-in", CGFloat(0.25))] {
            scene.debugPointerHover(at: nil)
            scene.debugCentre(on: pick, scale: scale)
            await settle(1.5)
            guard let p = scene.debugOrbViewPoint(pick), let (_, orbR) = scene.debugOrbCircle(pick) else { row("\(zname): orb on screen", false, ""); continue }
            scene.debugPointerHover(at: p)
            await settle(0.8)
            guard let o = scene.debugHoverOverlay else { row("\(zname): hover overlay up", false, ""); continue }
            row("\(zname): ring + tag drawn in screen space", scene.debugHoverInScreenSpace, "")
            row("\(zname): ring sits 4 pt outside the orb", abs(o.ringRadius - orbR - 4) < 0.6 && hypot(o.ringCentre.x - p.x, o.ringCentre.y - p.y) < 1,
                String(format: "orb r %.1f ring r %.1f centre off %.2f", orbR, o.ringRadius, hypot(o.ringCentre.x - p.x, o.ringCentre.y - p.y)))
            let shouldShow = o.orbDiameter < CorpusPhysicsScene.hoverLabelMaxOrbDiameter
            row("\(zname): tag only while the orb's title is too small", (o.label != nil) == shouldShow,
                String(format: "orb %.0f pt tag %@", o.orbDiameter, o.label == nil ? "hidden" : "shown"))
            if let l = o.label {
                labelHeights.append(l.height)
                let clearOfOwn = l.minY >= p.y + o.ringRadius - 0.5 || l.maxY <= p.y - o.ringRadius + 0.5
                var hits: [String] = []
                for id in scene.debugOrbIDs where id != pick {
                    guard let (c, r) = scene.debugOrbCircle(id) else { continue }
                    let nx = min(max(c.x, l.minX), l.maxX), ny = min(max(c.y, l.minY), l.maxY)
                    if hypot(nx - c.x, ny - c.y) < r { hits.append(id) }
                }
                row("\(zname): tag anchored just outside its own ring", clearOfOwn,
                    String(format: "tag y %.1f…%.1f orb y %.1f ring r %.1f", l.minY, l.maxY, p.y, o.ringRadius))
                lines.append("  \(zname): tag \(l.integral) overlaps \(hits.count) other orb(s)")
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let shot = dir.appendingPathComponent("hover-\(zname)-\(look).png").path
            row("\(zname): still rendered", scene.debugRenderStill(to: shot), shot)
            lines.append("  \(zname): camera \(String(format: "%.3f", scale)) still \(shot)")
        }
        if labelHeights.count > 1 {
            row("tag text the same size at every zoom it shows", (labelHeights.max()! - labelHeights.min()!) < 0.5,
                labelHeights.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        scene.debugPointerHover(at: nil)
        return "[MapHoverStillsSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(fails) fail (\(look))\n" + lines.joined(separator: "\n")
    }
}
#endif
