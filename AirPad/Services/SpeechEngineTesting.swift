import SwiftUI

/// live-12 (2) — ★ T approved 2026-10-14: "Speech engine (testing)", a hidden switch that forces the recorder's speech
/// tier so T's one iOS 26 iPhone can exercise every tier of the chain (`OnDeviceSpeech.chain`). Settings → About →
/// long-press the version. Every choice is on-device; there is no server option to force.
///
/// ⚠ GATE — it must not exist in App Store builds. live-19 (4): the gate is STRUCTURAL, at compile time (it was a
/// runtime receipt inference — `appStoreReceiptURL` == "sandboxReceipt" — deprecated in iOS 18, and the kind T removed
/// from the dev tuners on 2026-08-09). It exists in DEBUG and in builds compiled with the `TESTFLIGHT` condition, which
/// `scripts/testflight_upload.sh` sets (`AIRPAD_TF_FLAG=TESTFLIGHT`) unless `AIRPAD_APP_STORE_BUILD=1` — the launch
/// submission is archived that way, and then the long-press, the panel and every stored choice are compiled out
/// (the recorder runs Automatic). `-SpeechEngineTestingSelfTest` proves the gate's logic.
enum SpeechEngineTesting {
    static let key = "speechEngineTesting"

    /// Compile-time: DEBUG or a TestFlight archive.
    static let isOffered: Bool = {
        #if DEBUG || TESTFLIGHT
        return true
        #else
        return false
        #endif
    }()

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
        row("closed-gate-ignores-stored-choice", effective(stored: "dictation", offered: false) == .automatic)
        row("open-gate-uses-stored-choice", effective(stored: "olderRecognizer", offered: true) == .olderRecognizer)
        row("unknown-stored-value-is-automatic", effective(stored: "server", offered: true) == .automatic)
        row("no-server-choice-exists", SpeechEngineChoice.allCases.map(\.rawValue)
            == ["automatic", "speech", "dictation", "olderRecognizer", "unavailable"])
        #if DEBUG || TESTFLIGHT
        row("this-build-offers-it (DEBUG / TESTFLIGHT)", isOffered)
        #else
        row("this-build-hides-it (App Store)", !isOffered)
        #endif
        return "[SpeechEngineTestingSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}

#if DEBUG || TESTFLIGHT
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
#endif
