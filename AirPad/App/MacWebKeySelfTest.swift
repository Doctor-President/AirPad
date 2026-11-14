#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac D fix-up B2 — `-MacWebKeySelfTest` (with `-WebSearchBaseURL http://127.0.0.1:<port>` → `brave_stub.py`): a dummy
/// Brave key typed into the REAL Settings › Web search field, Settings closed the way the Mac closes a sheet (Esc / the
/// window, not Done), then read back from the Keychain and used by the search route (the stub logs whether the request
/// carried it). Never prints the key. Leaves the Keychain item deleted.
@MainActor
enum MacWebKeySelfTest {
    static let dummy = "BSA-dummy-fixup-b2-0000"

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func presented() -> UIViewController? {
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                var vc = w.rootViewController?.presentedViewController
                while let next = vc?.presentedViewController { vc = next }
                if let vc { return vc }
            }
            return nil
        }
        func field(in v: UIView) -> UITextField? {
            if let t = v as? UITextField, t.placeholder == "BSA..." { return t }
            for s in v.subviews { if let f = field(in: s) { return f } }
            return nil
        }
        func press(_ label: String) -> Bool {
            guard let w = presented()?.view.window else { return false }
            return CaptureClickSelfTest.elementObjects(label, in: w).first?.accessibilityActivate() ?? false
        }
        func readBack() -> String {
            switch KeychainHelper.read(key: WebSearchBackend.keychainKey) {
            case .found(let s): return s == dummy ? "found (the dummy)" : "found (another value)"
            case .notFound: return "not found"
            case .failed(let st): return "read failed (\(st))"
            }
        }

        KeychainHelper.delete(key: WebSearchBackend.keychainKey)
        UserDefaults.standard.set(true, forKey: WebSearchBackend.enabledKey)
        UserDefaults.standard.set(WebSearchBackend.Provider.brave.rawValue, forKey: WebSearchBackend.providerKey)
        // The Keychain itself on this Mac: a plain save → read.
        let st = KeychainHelper.save(key: WebSearchBackend.keychainKey, value: dummy)
        row("Keychain save → read (no UI)", st == errSecSuccess && readBack() == "found (the dummy)", "save \(st), \(readBack())")
        KeychainHelper.delete(key: WebSearchBackend.keychainKey)

        // 1. Typed into Settings › Web search, closed without Done.
        _ = MacMenuSelfTest.fire(menu: "AirPad", title: "Settings…")
        await settle(1.2)
        row("Settings open", presented() != nil)
        row("Web search row pressed", press("Web search"))
        await settle(1.2)
        guard let tf = presented().flatMap({ field(in: $0.view) }) else {
            row("Brave key field found", false)
            return "[MacWebKeySelfTest] FAIL\n" + rows.joined(separator: "\n")
        }
        row("Brave key field found (secure: \(tf.isSecureTextEntry))", true)
        tf.becomeFirstResponder()
        tf.insertText(dummy)
        await settle(0.8)
        let doneHere = presented().flatMap { $0.view.window }.map { !CaptureClickSelfTest.elementObjects("Done", in: $0).isEmpty } ?? false
        rows.append("INFO a Done button on the Web search screen: \(doneHere ? "yes" : "no (only Back; Esc / the window close it)")")
        presented()?.dismiss(animated: true)   // what Esc / the sheet's close does — no Done
        router.showSettings = false
        await settle(1.5)
        row("key saved when Settings closes without Done", readBack() == "found (the dummy)", readBack())
        row("search route has the key (hasKey)", WebSearchBackend.hasKey)
        let exec = WebSearchBackend.make()
        row("search route picks Brave", exec is BraveSearchToolExecutor, String(describing: type(of: exec)))

        // 2. The search itself: the request reaches the provider with the key (the stub logs token=match).
        let result = await exec.execute(name: AgentTools.webSearch, arguments: ["query": "stub test query", "count": 3])
        row("search returned the stub's result", result.links.contains { $0.url.contains("example.com/stub") }, "\(result.links.count) link(s)")

        // 3. Reopened, Settings shows a key (the field is filled from the Keychain).
        _ = MacMenuSelfTest.fire(menu: "AirPad", title: "Settings…")
        await settle(1.2)
        _ = press("Web search")
        await settle(1.2)
        let shown = presented().flatMap { field(in: $0.view) }?.text ?? ""
        row("reopened: the field holds the saved key", shown == dummy, shown.isEmpty ? "empty" : (shown == dummy ? "the dummy" : "another value"))
        presented()?.dismiss(animated: true)
        router.showSettings = false
        await settle(1.0)

        KeychainHelper.delete(key: WebSearchBackend.keychainKey)
        let checks = rows.filter { !$0.hasPrefix("INFO") }.count
        return "[MacWebKeySelfTest] \(fails == 0 ? "PASS" : "FAIL") \(checks - fails)/\(checks)\n" + rows.joined(separator: "\n")
    }
}
#endif
