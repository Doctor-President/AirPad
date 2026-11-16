#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac D fix-up B1 — `-MacSettingsSelfTest`: opens Settings from the real menu (AirPad › Settings…) `-SettingsRuns`
/// times (default 50) in a row, from each place in turn (Map, List, Cards, Today), and closes it the way Done does.
/// E fix-up 3 (H4): Settings opens as the right slide-out, so "opened" = in the panel with no sheet up.
/// Odd rounds open it from inside the app's views instead: the Librarian's own Settings sheet (the ≡ drawer that crashed
/// is gone on the Mac since F4). A crash ends the run (no PASS line); every round logs before it opens, so the log names
/// the round that died.
@MainActor
enum MacSettingsSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        let runs = UserDefaults.standard.object(forKey: "SettingsRuns") == nil ? 50 : max(1, UserDefaults.standard.integer(forKey: "SettingsRuns"))
        var fails = 0, opened = 0, inViewOpened = 0
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
            let inView = i % 2 == 1
            NSLog("[MacSettingsSelfTest] round %d place=%@ via=%@ opening", i + 1, place, inView ? "librarian" : "menu")
            if inView {
                MacLayout.shared.librarianOpen = true
                NotificationCenter.default.post(name: .debugOpenLibrarianSettings, object: nil)
            } else if !MacMenuSelfTest.fire(menu: "AirPad", title: "Settings…") {
                fails += 1; NSLog("[MacSettingsSelfTest] round %d menu item missing/disabled", i + 1); continue
            }
            await settle(i % 3 == 0 ? 0.35 : 1.0)   // some rounds close while the panel is still sliding in
            // E fix-up 3 (H4) — Settings is the right slide-out now (no sheet): open = the panel is in the slot, no sheet.
            if MacLayout.shared.settingsOpen && presented() == nil { opened += 1; if inView { inViewOpened += 1 } }
            else { fails += 1; NSLog("[MacSettingsSelfTest] round %d not in the panel (open %d, sheet %d)", i + 1, MacLayout.shared.settingsOpen ? 1 : 0, presented() == nil ? 0 : 1) }
            MacLayout.shared.closeSettings()
            await settle(0.7)
        }
        let ok = fails == 0 && opened == runs
        return "[MacSettingsSelfTest] \(ok ? "PASS" : "FAIL") opened \(opened)/\(runs) (\(inViewOpened) from the Librarian's own sheet), crashes 0 (the run reached its end)"
    }
}
#endif
