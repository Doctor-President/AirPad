#if DEBUG
import UIKit

/// Mac batch C2 — `-MapPointerSelfTest` (with `-OpenMap`): the Map on a trackpad / mouse / keyboard. Drives the SAME
/// scene paths the recognisers call (pinch → zoom around the cursor, scroll → pan, hover → ring + title), fires View ›
/// Zoom In / Out / to Fit through the real menu on the Mac (the router elsewhere), and checks the Map goes back to
/// 0 frames at rest after each. Real trackpad events can't be synthesised headlessly: T's check covers them.
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
