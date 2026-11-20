import Foundation
import UIKit
import SwiftUI
import CryptoKit

// Sweep 2a — the LIBRARIAN RECORDER. T's "that answer reached for something irrelevant" turned into data: for the
// last few turns it keeps the route, the question's rule flags, every candidate entry with its score and the cut-off
// it met, what was sent (counts and IDs), what was cited and whether each citation was used, timings, tokens, model.
//
// PRIVACY IS STRUCTURAL, not remembered: a recorded value is a number, a bool, a compile-time token (`StaticString`),
// an ID (kept only when it is a UUID, otherwise hashed) or a short label from a closed character set (route, mode,
// model tag). There is no call that takes entry text or a title. The question's own text is recorded only through
// `LibRec.question(_:)`, and only when "Include my question" is switched on.
//
// TestFlight / Xcode / bench builds only (`DEBUG || DEVSWITCHES`), behind the same hidden unlock as the performance
// recorder (Settings › About, five taps on the version line). Compiled out of App Store builds: there `LibRec` is the
// empty facade below.

/// What a recording can hold. No case takes free text.
enum LibRecValue {
    case int(Int)
    case num(Double)
    case bool(Bool)
    /// A word fixed at compile time.
    case token(StaticString)
    /// A node / block / chat ID. Kept when it is a UUID (optionally with a numeric suffix); anything else is hashed.
    case id(String)
    /// A short runtime label from a closed vocabulary (route, mode, model tag): letters, digits and `._:/()+-` only,
    /// 64 characters at most; anything else is dropped to "?".
    case label(String)
    case list([LibRecValue])
    case row([(StaticString, LibRecValue)])
}

/// Call sites. Every call is a no-op unless the recorder is compiled in and switched on.
enum LibRec {
    #if DEBUG || DEVSWITCHES
    static var isOn: Bool { LibrarianRecorder.shared.on }
    /// A new turn starts (closes one left open).
    static func begin() { LibrarianRecorder.shared.begin() }
    static func set(_ key: StaticString, _ value: LibRecValue) { LibrarianRecorder.shared.set(key, value) }
    static func add(_ key: StaticString, _ row: [(StaticString, LibRecValue)]) { LibrarianRecorder.shared.add(key, .row(row)) }
    /// Milliseconds since the turn began, stored under `key`.
    static func mark(_ key: StaticString) { LibrarianRecorder.shared.mark(key) }
    /// The question's text: stored only when "Include my question" is on. Its length and word count always are.
    static func question(_ text: String) { LibrarianRecorder.shared.question(text) }
    /// The turn is complete (the answer is committed, or the app answered itself).
    static func end() { LibrarianRecorder.shared.end() }
    #else
    static var isOn: Bool { false }
    @inline(__always) static func begin() {}
    @inline(__always) static func set(_ key: StaticString, _ value: @autoclosure () -> LibRecValue) {}
    @inline(__always) static func add(_ key: StaticString, _ row: @autoclosure () -> [(StaticString, LibRecValue)]) {}
    @inline(__always) static func mark(_ key: StaticString) {}
    @inline(__always) static func question(_ text: @autoclosure () -> String) {}
    @inline(__always) static func end() {}
    #endif
}

#if DEBUG || DEVSWITCHES

final class LibrarianRecorder: NSObject, UIGestureRecognizerDelegate, @unchecked Sendable {
    static let shared = LibrarianRecorder()
    static let onKey = "librarian.recorder.on"
    static let questionKey = "librarian.recorder.question"
    static let saveNotification = Notification.Name("LibrarianRecorderDidSave")
    /// Turns kept in memory (and written by a save).
    static let keep = 8

    private let lock = NSLock()
    private var turns: [[String: Any]] = []
    private var open: [String: Any]? = nil
    private var openStart: CFTimeInterval = 0
    private var seq = 0
    private var gestureInstalled = false
    private var lastSaved: URL?

    var on: Bool {
        UserDefaults.standard.bool(forKey: Self.onKey) || ProcessInfo.processInfo.arguments.contains("-LibrarianRecorder")
    }
    private var includeQuestion: Bool { UserDefaults.standard.bool(forKey: Self.questionKey) }

    @MainActor static func startIfEnabled() {
        if shared.on { shared.installGesture() }
        // Harnesses (no clicks): `notifyutil -p com.airpad.librarian.save` writes the file.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = LibrarianRecorder.shared.save(reason: "harness") } }
        }, "com.airpad.librarian.save" as CFString, nil, .deliverImmediately)
    }
    @MainActor static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: onKey)
        if value { shared.installGesture() }
    }

    // MARK: recording

    func begin() {
        guard on else { return }
        lock.lock(); defer { lock.unlock() }
        closeLocked()
        seq += 1
        openStart = CACurrentMediaTime()
        open = ["seq": seq, "at": ISO8601DateFormatter().string(from: Date())]
    }

    func set(_ key: StaticString, _ value: LibRecValue) {
        guard on else { return }
        lock.lock(); defer { lock.unlock() }
        guard open != nil else { return }
        open?["\(key)"] = Self.plain(value)
    }

    func add(_ key: StaticString, _ value: LibRecValue) {
        guard on else { return }
        lock.lock(); defer { lock.unlock() }
        guard open != nil else { return }
        var rows = open?["\(key)"] as? [Any] ?? []
        guard rows.count < 200 else { return }
        rows.append(Self.plain(value))
        open?["\(key)"] = rows
    }

    func mark(_ key: StaticString) {
        guard on else { return }
        lock.lock(); defer { lock.unlock() }
        guard open != nil else { return }
        open?["\(key)"] = Int((CACurrentMediaTime() - openStart) * 1000)
    }

    func question(_ text: String) {
        guard on else { return }
        let include = includeQuestion
        lock.lock(); defer { lock.unlock() }
        guard open != nil else { return }
        open?["questionChars"] = text.count
        open?["questionWords"] = text.split(whereSeparator: { $0.isWhitespace }).count
        if include { open?["question"] = String(text.prefix(2_000)) }
    }

    func end() {
        guard on else { return }
        lock.lock(); defer { lock.unlock() }
        if open != nil { open?["totalMs"] = Int((CACurrentMediaTime() - openStart) * 1000) }
        closeLocked()
    }

    private func closeLocked() {
        guard let t = open else { return }
        turns.append(t)
        if turns.count > Self.keep { turns.removeFirst(turns.count - Self.keep) }
        open = nil
    }

    /// The turns held now (oldest first), the open one last. For the self-test and the harness.
    func snapshot() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return turns + (open.map { [$0] } ?? [])
    }
    func reset() { lock.lock(); turns = []; open = nil; lock.unlock() }

    // MARK: values

    static func plain(_ v: LibRecValue) -> Any {
        switch v {
        case .int(let i): return i
        case .num(let d): return d.isFinite ? (d * 10_000).rounded() / 10_000 : 0
        case .bool(let b): return b
        case .token(let s): return "\(s)"
        case .id(let s): return safeID(s)
        case .label(let s): return safeLabel(s)
        case .list(let l): return l.map(plain)
        case .row(let r): return Dictionary(r.map { ("\($0.0)", plain($0.1)) }, uniquingKeysWith: { _, b in b })
        }
    }

    /// A UUID (with an optional `:n` / `-n` / `#n` numeric suffix, or a `card:` / `full:` prefix) is kept; anything else
    /// (a bundled sample entry's readable ID, say) becomes `x` + 12 hex of its SHA-256, so no words survive.
    static func safeID(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        var core = raw, prefix = ""
        for p in ["card:", "full:"] where core.hasPrefix(p) { prefix = p; core.removeFirst(p.count) }
        var suffix = ""
        if core.count > 36 {
            let tail = core.dropFirst(36)
            if let sep = tail.first, ":-#_/".contains(sep), tail.dropFirst().allSatisfy(\.isNumber), tail.count <= 8 {
                suffix = String(tail); core = String(core.prefix(36))
            }
        }
        if UUID(uuidString: core) != nil { return prefix + core + suffix }
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "x" + digest
    }

    static func safeLabel(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/()+-")
        guard !raw.isEmpty, raw.count <= 64, raw.allSatisfy({ allowed.contains($0) }) else { return "?" }
        return raw
    }

    // MARK: save

    @MainActor @discardableResult func save(reason: String) -> URL? {
        guard on else { return nil }
        let rows = snapshot()
        let doc: [String: Any] = [
            "version": 1,
            "kind": "librarian",
            "reason": reason,
            "saved": ISO8601DateFormatter().string(from: Date()),
            "includesQuestion": includeQuestion,
            "device": [
                "mac": RunningOnMac.isMac,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "app": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")",
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            ] as [String: Any],
            "turns": rows,
        ]
        guard let dir = Self.directory,
              let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("librarian-\(f.string(from: Date()))-\(rows.count)-turns.json")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        if let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), all.count > 40 {
            all[40...].forEach { try? FileManager.default.removeItem(at: $0) }
        }
        lastSaved = url
        NSLog("[LibrarianRecorder] saved %@ (%@, %d turns)", url.path, reason, rows.count)
        NotificationCenter.default.post(name: Self.saveNotification, object: url)
        if reason != "harness" && reason != "selftest" { showSavedNote() }
        return url
    }

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("LibrarianRecordings", isDirectory: true)
    }
    @MainActor static var recordings: [URL] {
        guard let dir = directory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @MainActor private func showSavedNote() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let label = UILabel()
        label.text = "  Librarian recording saved  "
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78); label.layer.cornerRadius = 14; label.layer.masksToBounds = true
        label.sizeToFit(); label.frame.size.height = 28
        label.center = CGPoint(x: window.bounds.midX, y: window.safeAreaInsets.top + 66)   // below the performance note
        label.isUserInteractionEnabled = false
        window.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    // MARK: iPhone gesture — the performance recorder's own (three fingers, press and hold); both may fire together.

    @MainActor private func installGesture() {
        guard !gestureInstalled, !RunningOnMac.isMac else { return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.installGesture() } }
            return
        }
        let g = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        g.numberOfTouchesRequired = 3
        g.minimumPressDuration = 0.6
        g.cancelsTouchesInView = false
        g.delegate = self
        window.addGestureRecognizer(g)
        gestureInstalled = true
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        MainActor.assumeIsolated { _ = save(reason: "three-finger press") }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Settings › About, after the taps on the version line, under the performance recorder.
struct LibrarianRecorderPanel: View {
    @AppStorage(LibrarianRecorder.onKey) private var on = false
    @AppStorage(LibrarianRecorder.questionKey) private var includeQuestion = false
    @State private var last: URL?
    @State private var count = LibrarianRecorder.recordings.count

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Librarian recorder (testing)").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
            Toggle("Record how the Librarian answers", isOn: Binding(get: { on }, set: { LibrarianRecorder.setEnabled($0) }))
                .accessibilityIdentifier("librarianRecorderOn")
            Toggle("Include my question", isOn: $includeQuestion).disabled(!on)
                .accessibilityIdentifier("librarianRecorderQuestion")
            Text(RunningOnMac.isMac
                 ? "When an answer looks wrong, press ⌃⌥⌘L. It saves the last \(LibrarianRecorder.keep) turns: which entries were considered (by ID), their scores, what was sent and cited, timings. No entry text or titles; your question's words only if the switch above is on."
                 : "When an answer looks wrong, press and hold with three fingers. It saves the last \(LibrarianRecorder.keep) turns: which entries were considered (by ID), their scores, what was sent and cited, timings. No entry text or titles; your question's words only if the switch above is on.")
                .font(.system(size: 11)).foregroundStyle(AppearancePalette.ink.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Save now") { last = LibrarianRecorder.shared.save(reason: "panel button"); count = LibrarianRecorder.recordings.count }
                    .disabled(!on).accessibilityIdentifier("librarianRecorderSave")
                if let url = last ?? LibrarianRecorder.recordings.first {
                    ShareLink(item: url) { Text(RunningOnMac.isMac ? "Share last…" : "Send last…") }.accessibilityIdentifier("librarianRecorderShare")
                }
                Text("\(count) saved").foregroundStyle(AppearancePalette.ink.opacity(0.45))
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(AppearancePalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librarianRecorderPanel")
        .onReceive(NotificationCenter.default.publisher(for: LibrarianRecorder.saveNotification)) { n in
            last = n.object as? URL; count = LibrarianRecorder.recordings.count
        }
    }
}

#endif
