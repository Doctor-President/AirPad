#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac D fix-up B1 — `-MacSettingsSelfTest`: opens Settings from the real menu (AirPad › Settings…) `-SettingsRuns`
/// times (default 50) in a row, from each place in turn (Map, List, Cards, Today), and closes it the way Done does.
/// Odd rounds use the ≡ drawer's Settings row instead (pressed through accessibility; the window takes no clicks while
/// the Mac is locked). A crash ends the run (no PASS line); every round logs before it opens, so the log names the round that died.
@MainActor
enum MacSettingsSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        let runs = UserDefaults.standard.object(forKey: "SettingsRuns") == nil ? 50 : max(1, UserDefaults.standard.integer(forKey: "SettingsRuns"))
        var fails = 0, opened = 0
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func presented() -> UIViewController? {
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                var vc = w.rootViewController?.presentedViewController
                while let next = vc?.presentedViewController { vc = next }
                if let vc { return vc }
            }
            return nil
        }
        let places: [(String, AppCommand)] = [("map", .viewMap), ("list", .viewList), ("cards", .viewCards), ("today", .today)]
        for i in 0..<runs {
            let (place, command) = places[i % places.count]
            router.perform(command)
            await settle(0.6)
            let viaDrawer = i % 2 == 1 && place != "today"
            NSLog("[MacSettingsSelfTest] round %d place=%@ via=%@ opening", i + 1, place, viaDrawer ? "drawer" : "menu")
            if viaDrawer {
                guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first,
                      CaptureClickSelfTest.elementObjects("Menu", in: window).last?.accessibilityActivate() == true else {
                    fails += 1; NSLog("[MacSettingsSelfTest] round %d no ≡ Menu button", i + 1); continue
                }
                await settle(0.8)
                let rows = CaptureClickSelfTest.elementObjects("Settings", in: window)
                if i == 1 {
                    for r in rows { NSLog("[MacSettingsSelfTest] Settings element %@ frame=%@ id=%@", String(describing: type(of: r)), NSCoder.string(for: r.accessibilityFrame), (r.value(forKey: "accessibilityIdentifier") as? String) ?? "-") }
                }
                guard (rows.first { ($0.value(forKey: "accessibilityIdentifier") as? String) == "menu.settings" } ?? rows.last)?.accessibilityActivate() == true else {
                    fails += 1; NSLog("[MacSettingsSelfTest] round %d no Settings row in the drawer", i + 1); continue
                }
            } else if !MacMenuSelfTest.fire(menu: "AirPad", title: "Settings…") {
                fails += 1; NSLog("[MacSettingsSelfTest] round %d menu item missing/disabled", i + 1); continue
            }
            await settle(i % 3 == 0 ? 0.35 : 1.0)   // some rounds close while the sheet is still animating in
            if presented() != nil { opened += 1 } else { fails += 1; NSLog("[MacSettingsSelfTest] round %d not presented", i + 1) }
            presented()?.dismiss(animated: true)
            router.showSettings = false
            await settle(0.7)
        }
        let ok = fails == 0 && opened == runs
        return "[MacSettingsSelfTest] \(ok ? "PASS" : "FAIL") opened \(opened)/\(runs), crashes 0 (the run reached its end)"
    }
}
#endif
