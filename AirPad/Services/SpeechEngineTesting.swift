import SwiftUI

/// live-12 (2) — ★ T approved 2026-10-14: "Speech engine (testing)", a hidden switch that forces the recorder's speech
/// tier so T's one iOS 26 iPhone can exercise every tier of the chain (`OnDeviceSpeech.chain`). Settings → About →
/// long-press the version. Every choice is on-device; there is no server option to force.
///
/// ⚠ GATE — it must not exist in App Store builds. It is offered in DEBUG, and in a Release build only when the app's
/// receipt is TestFlight's sandbox receipt. That is a runtime receipt inference — the kind T removed from
/// `InternalBuild.showsDevTuners` on 2026-08-09 for the dev tuners, which stays structural (`#if DEBUG`) and untouched.
/// This one control re-introduces it because T needs it ON in TestFlight, and it fails safe:
///   • only the exact name "sandboxReceipt" opens it — an App Store receipt ("receipt"), no receipt, or anything
///     unexpected keeps it absent;
///   • when the gate is closed a stored choice is ignored: the recorder runs Automatic (`effective`);
///   • at worst (the inference wrong on an App Store install) someone could pick a less accurate ON-DEVICE tier —
///     no tier sends audio or words off the phone.
/// `-SpeechEngineTestingSelfTest` proves the gate.
enum SpeechEngineTesting {
    static let key = "speechEngineTesting"

    static let isOffered: Bool = {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return offered(debug: debug, receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }()

    static func offered(debug: Bool, receiptName: String?) -> Bool { debug || receiptName == "sandboxReceipt" }

    /// The choice this take runs: the stored one only when the switch is offered, else Automatic.
    static var choice: SpeechEngineChoice { effective(stored: UserDefaults.standard.string(forKey: key), offered: isOffered) }

    static func effective(stored: String?, offered: Bool) -> SpeechEngineChoice {
        guard offered, let stored, let c = SpeechEngineChoice(rawValue: stored) else { return .automatic }
        return c
    }

    static func set(_ c: SpeechEngineChoice) {
        guard isOffered else { return }
        if c == .automatic { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(c.rawValue, forKey: key) }
    }

    /// The last recorder take (this launch only) — shown in the panel, so Automatic's pick is visible, with how long
    /// the take took to be ready and to show its first words (live-13 (2): T can compare online vs airplane mode).
    struct LastTake {
        var tier: SpeechTier
        var readyMs: Int
        var firstWordMs: Int?
        var summary: String {
            "\(tier.label) · ready \(readyMs) ms · first words " + (firstWordMs.map { "\($0) ms" } ?? "none yet")
        }
    }
    @MainActor static var lastTake: LastTake?

    /// `-SpeechEngineTestingSelfTest` — the gate, the stored-choice guard, and the forced chains. Pure.
    static func selfTest() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool) { rows.append("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { fails += 1 } }
        row("app-store-receipt-absent", !offered(debug: false, receiptName: "receipt"))
        row("testflight-sandbox-receipt-present", offered(debug: false, receiptName: "sandboxReceipt"))
        row("no-receipt-release-absent", !offered(debug: false, receiptName: nil))
        row("unexpected-receipt-name-absent", !offered(debug: false, receiptName: "sandboxReceipt.bak"))
        row("debug-or-simulator-present", offered(debug: true, receiptName: nil))
        row("closed-gate-ignores-stored-choice", effective(stored: "dictation", offered: false) == .automatic)
        row("open-gate-uses-stored-choice", effective(stored: "olderRecognizer", offered: true) == .olderRecognizer)
        row("unknown-stored-value-is-automatic", effective(stored: "server", offered: true) == .automatic)
        row("no-server-choice-exists", SpeechEngineChoice.allCases.map(\.rawValue)
            == ["automatic", "speech", "dictation", "olderRecognizer", "unavailable"])
        #if DEBUG
        row("this-build-offers-it (DEBUG)", isOffered)
        #else
        row("this-build-matches-its-receipt", isOffered == (Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"))
        #endif
        return "[SpeechEngineTestingSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}

/// The panel behind the long-press. Plain system list: it only exists in TestFlight and DEBUG builds.
struct SpeechEngineTestingPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choice = SpeechEngineTesting.choice
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { c in
                        Button {
                            SpeechEngineTesting.set(c); choice = c
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.label)
                                    Text(Self.detail(c)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if c == choice { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("speechEngine-\(c.rawValue)")
                        .accessibilityAddTraits(c == choice ? .isSelected : [])
                    }
                } footer: {
                    Text("Testing only — absent from App Store builds. Every engine runs on this iPhone. A forced engine "
                         + "that can't run falls to the next one, as it would for anyone.")
                }
                Section {
                    Text("Last take: \(SpeechEngineTesting.lastTake?.summary ?? "none yet")")
                        .accessibilityIdentifier("speechEngineLastTake")
                    Button(copied ? "Copied" : "Copy values") {
                        UIPasteboard.general.string = "Speech engine (testing): \(choice.label)\n"
                            + "Last take: \(SpeechEngineTesting.lastTake?.summary ?? "none yet")"
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                }
            }
            .navigationTitle("Speech engine (testing)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private static func detail(_ c: SpeechEngineChoice) -> String {
        switch c {
        case .automatic: return "Speech, else Dictation, else the older recognizer"
        case .speech: return "SpeechTranscriber — most accurate, no app vocabulary"
        case .dictation: return "DictationTranscriber + the app's words"
        case .olderRecognizer: return "SFSpeechRecognizer, ~50 s segments — the no-model fallback"
        case .unavailable: return "No transcript; the audio is kept"
        }
    }
}
