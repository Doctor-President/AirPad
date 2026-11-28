// Good Flow spike (throwaway, never merged) · the root: the current case, the switch panel, recordings, bench runs.
//
// Bench runs (iPhone and Mac):  -Bench <detail|cards|map> -Seconds N [-Variant … -Theme … any switch]
//   waits 3 s (stills fill), resets the recorder, runs the case's PROGRAMMATIC motion for N s (marked "programmatic"),
//   then 10 s of rest (the rest row), saves Documents/recordings/bench-<case>-<variant>-<theme>[-flat]-<stamp>.json
//   (frames + the 1 Hz thermal / footprint / CPU trace) and writes Documents/recordings/bench-done.json, then idles.
// Recording while T uses it: the panel's "Record" switch (start = a fresh recording; stop = saved as manual-<stamp>);
//   ⌃⌥⌘P (Mac) or "Save now" saves what is recorded so far; `notifyutil -p com.goodflow.save` too (scripted Mac runs).
// Headless: -AutoSaveAt S saves at S seconds (name -AutoSaveName); -AutoQuit YES quits after it.
import UIKit

final class GFRootViewController: UIViewController {
    private var screen: (UIViewController & GFCaseScreen)?
    private var shownCase: GFSettings.Case?
    private let panel = GFPanel()
    private let toggle = UIButton(type: .system)
    private let note = UILabel()
    private var obs: NSObjectProtocol?
    private var benchStarted = false

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Save recording", action: #selector(saveNow), input: "p", modifierFlags: [.control, .alternate, .command])]
    }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        GFRecorder.extraMeta = { [weak self] in self?.screen?.recordingMeta ?? [:] }
        showCase()
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Switches"; cfg.cornerStyle = .capsule; cfg.baseBackgroundColor = UIColor(white: 0.15, alpha: 0.75)
        toggle.configuration = cfg
        toggle.accessibilityIdentifier = "panel.toggle"
        toggle.addAction(UIAction { [weak self] _ in self?.togglePanel() }, for: .primaryActionTriggered)
        view.addSubview(toggle)
        panel.isHidden = true
        panel.onSave = { [weak self] in self?.saveNow() }
        panel.onDetailScale = { [weak self] v in _ = self?.screen?.scriptAction("scale", String(v)) }
        panel.onCopy = { [weak self] in self?.copyValues() }
        view.addSubview(panel)
        obs = NotificationCenter.default.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main) { [weak self] n in
            if (n.userInfo?["what"] as? String) == "case" { self?.showCase() }
        }
    }

    private func showCase() {
        let c = GFSettings.shared.caseName
        guard c != shownCase else { return }
        shownCase = c
        if let s = screen { s.willMove(toParent: nil); s.view.removeFromSuperview(); s.removeFromParent() }
        let s: UIViewController & GFCaseScreen
        switch c {
        case .detail: s = GFDetailViewController()
        case .cards: s = GFCardsViewController()
        case .map: s = GFMapViewController()
        }
        addChild(s); view.insertSubview(s.view, at: 0); s.view.frame = view.bounds; s.didMove(toParent: self)
        screen = s
        GFRecorder.shared.mark("case \(c.rawValue)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        screen?.view.frame = view.bounds
        let sa = view.safeAreaInsets
        let ts = toggle.intrinsicContentSize
        toggle.frame = CGRect(x: view.bounds.width - ts.width - 16 - sa.right, y: view.bounds.height - ts.height - 16 - sa.bottom, width: ts.width, height: ts.height)
        let pw = min(420, view.bounds.width - 24), ph = min(panel.fittingHeight(width: pw), view.bounds.height - sa.top - sa.bottom - ts.height - 40)
        panel.frame = CGRect(x: view.bounds.width - pw - 12 - sa.right, y: toggle.frame.minY - ph - 10, width: pw, height: ph)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        let d = UserDefaults.standard
        if !benchStarted, let b = d.string(forKey: "Bench") { benchStarted = true; runBench(b, seconds: max(5, d.double(forKey: "Seconds") == 0 ? 60 : d.double(forKey: "Seconds"))) }
        if let sc = d.string(forKey: "Script") { runScript(sc) }
        let at = d.double(forKey: "AutoSaveAt")
        if at > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                GFRecorder.shared.save(name: d.string(forKey: "AutoSaveName"), meta: GFRecorder.extraMeta?() ?? [:])
                if d.bool(forKey: "AutoQuit") { exit(0) }
            }
        }
    }

    /// Round 2 · `-Script "verb:arg@seconds,…"` (scripted runs with the screen locked; also usable by hand-free checks):
    ///   theme:light|dark  variant:A|B|BD75|BD50  case:Detail|Cards|Map  pools:…  size:WxH (window, Mac)  panel:open|closed
    ///   dump:<name> (Documents/r2/<name>.json: the screen's diagnostics)  snap:<name> (Documents/r2/<name>.png: the window,
    ///   drawHierarchy)  save:<name> (a recording)  reset (recorder)  quit;  any other verb goes to the screen
    ///   (scriptAction: e.g. scroll:<pt>, scale:<x>, hover:<item>, reveal:on|off …).
    private func runScript(_ sc: String) {
        let S = GFSettings.shared
        for part in sc.split(separator: ",") {
            let at = part.split(separator: "@", maxSplits: 1)
            guard at.count == 2, let t = Double(at[1]) else { continue }
            let va = at[0].split(separator: ":", maxSplits: 1).map(String.init)
            let verb = va[0], arg = va.count > 1 ? va[1] : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                GFRecorder.shared.mark("script \(verb):\(arg)")
                switch verb {
                case "theme": S.theme = arg == "dark" ? .dark : .light
                case "variant": if let v = GFVariant.parse(arg) { S.variant = v }
                case "case": if let c = GFSettings.Case.allCases.first(where: { $0.rawValue.lowercased() == arg.lowercased() }) { S.caseName = c }
                case "pools": if let v = GFPoolsMode.parse(arg) { S.pools = v }
                case "live": S.live = arg == "on"
                case "size":
                    let wh = arg.split(separator: "x").compactMap { Double($0) }
                    if wh.count == 2, let ws = self.view.window?.windowScene {
                        ws.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: wh[0], height: wh[1]))) { e in GFRecorder.shared.mark("size failed \(e)") }
                    }
                case "panel": if (arg == "open") == self.panel.isHidden { self.togglePanel() }
                case "dump": self.writeR2(arg + ".json", try? JSONSerialization.data(withJSONObject: self.diagnosticsNow(), options: [.prettyPrinted, .sortedKeys]))
                case "snap": self.writeR2(arg + ".png", self.snapshotPNG())
                case "save": GFRecorder.shared.save(name: arg, meta: self.screen?.recordingMeta ?? [:])
                case "copy": self.copyValues()
                case "reset": GFRecorder.shared.reset()
                case "quit": exit(0)
                default: if self.screen?.scriptAction(verb, arg) != true { GFRecorder.shared.mark("script: unknown \(verb)") }
                }
            }
        }
    }
    /// "Copy values": every current setting as a labelled plain-text list on the pasteboard (UIPasteboard; on Catalyst the
    /// Mac's general pasteboard), then "Copied" on screen for 1.5 s.
    func copyValues() {
        let S = GFSettings.shared
        let win = view.window?.bounds.size ?? view.bounds.size
        let scale = view.window?.traitCollection.displayScale ?? traitCollection.displayScale
        var L: [String] = ["Good Flow spike · round 2 · values (\(GFRecorder.stamp()))"]
        L.append("device: \(ProcessInfo.processInfo.isMacCatalystApp ? "Mac (Catalyst)" : UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · display scale \(scale)")
        L.append(String(format: "window: %.0f × %.0f pt", win.width, win.height))
        L.append("case: \(S.caseName.rawValue)")
        L.append("theme: \(S.theme.rawValue)")
        L.append("variant: \(S.variant.rawValue)")
        if let d = screen as? GFDetailViewController {
            let b = d.band.bounds.size, r = GFDetailViewController.zoomRange(widthPt: Double(b.width), heightPt: Double(b.height)), z = d.currentZoom()
            L.append(String(format: "detail band: %.0f × %.0f pt", b.width, b.height))
            L.append(String(format: "detail zoom: %.2f× (Bench 1.00×, Width %.2f× for this band; scale %.2f on Bench 0 → Width 1)", z, r.width, log(z) / max(log(r.width), 1e-6)))
        } else {
            L.append("detail zoom: " + (S.detailZoom.map { String(format: "%.2f×", $0) } ?? (S.detailFitWidth ? "Width" : "Bench (1.00×)")) + " (open Detail for its band's Bench/Width)")
        }
        L.append("DeepFix (dark-cast fix): \(S.deepFix ? "on" : "off")")
        L.append("ScrolledBand: \(S.scrolledBand)")
        L.append("Reveal: \(S.reveal ? "on" : "off (all Good Flow)") · size \(String(format: "%.0f", S.revealSize)) pt · annulus \(String(format: "%.0f", S.revealAnnulus)) pt · soft \(String(format: "%.2f", S.revealSoft)) · stills \(S.revealStills)")
        L.append("LiveScale: \(S.liveScale.map { String(format: "%.0f×", $0) } ?? "display (\(scale)×)")")
        L.append("LiveZone: \(S.liveZoneImage ? "image zone" : "whole card")")
        L.append("ScrollRedraw: \(S.scrollRedraw ? "on" : "off")")
        L.append("live: \(S.live ? "on @\(S.liveRate)" : "off")")
        L.append("Pools: \(S.pools.rawValue)")
        L.append("glass: \(S.glass ? "on (Clear 0.6)" : "off")")
        L.append("edge bend: \(S.edgeBend ? "on (0.5)" : "off")")
        L.append("flat control: \(S.flat ? "on" : "off") · hash \(S.benchHash ? "bench" : "stable") · map master \(S.mapCap) px")
        let text = L.joined(separator: "\n")
        UIPasteboard.general.string = text
        GFRecorder.shared.mark("copied values")
        panel.status("Copied")
        let t = UILabel()
        t.text = "  Copied  "; t.font = .systemFont(ofSize: 15, weight: .semibold); t.textColor = .white
        t.backgroundColor = UIColor(white: 0.1, alpha: 0.85); t.layer.cornerRadius = 8; t.layer.masksToBounds = true
        t.sizeToFit(); t.frame.size.height += 10; t.center = CGPoint(x: view.bounds.midX, y: view.bounds.height * 0.12)
        t.accessibilityIdentifier = "copied.toast"
        view.addSubview(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { t.removeFromSuperview() }
    }
    private func diagnosticsNow() -> [String: Any] {
        var d = screen?.diagnostics ?? [:]
        d["window"] = [view.window?.bounds.width ?? 0, view.window?.bounds.height ?? 0]
        d["settings"] = GFSettings.shared.dict; d["footprintMB"] = GFRecorder.physFootprintMB(); d["t"] = CACurrentMediaTime()
        return d
    }
    private func snapshotPNG() -> Data? {
        guard let w = view.window else { return nil }
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let img = UIGraphicsImageRenderer(bounds: w.bounds, format: f).image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        return img.pngData()
    }
    private func writeR2(_ name: String, _ data: Data?) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("r2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data { try? data.write(to: dir.appendingPathComponent(name)) } else { GFRecorder.shared.mark("script: \(name) had no data") }
    }

    private func togglePanel() {
        panel.isHidden.toggle()
        panel.setLive(!panel.isHidden)
        view.setNeedsLayout()
    }

    @objc private func saveNow() {
        let url = GFRecorder.shared.save(name: "manual-" + GFRecorder.stamp(), meta: screen?.recordingMeta ?? [:])
        panel.status("saved \(url?.lastPathComponent ?? "FAILED")")
    }

    private func runBench(_ name: String, seconds: Double) {
        let S = GFSettings.shared
        let rec = GFRecorder.shared
        let tag = "bench-\(name.lowercased())-\(S.variant.rawValue)-\(S.theme.rawValue)\(S.flat ? "-flat" : "")\(S.live ? "" : "-liveoff")-r\(S.liveRate)" + (S.liveScale.map { "-x\(Int($0))" } ?? "") + (S.liveZoneImage ? "-zone" : "") + (S.scrollRedraw ? "-redraw" : "") + (GFDraw.pass2OnlyArm ? "-pass2" : "") + "-" + GFRecorder.stamp()
        writeProgress(["state": "settling", "tag": tag])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            rec.reset(); rec.mark("bench start (programmatic) \(S.describe)")
            self.screen?.setProgrammatic(true)
            self.writeProgress(["state": "moving", "tag": tag, "seconds": seconds])
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                self.screen?.setProgrammatic(false)
                rec.mark("bench input end; rest 10 s")
                self.writeProgress(["state": "rest", "tag": tag])
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) {
                    var meta = self.screen?.recordingMeta ?? [:]
                    meta["bench"] = name; meta["seconds"] = seconds; meta["input"] = "programmatic"
                    let url = rec.save(name: tag, meta: meta)
                    self.writeProgress(["state": "done", "done": true, "tag": tag, "file": url?.lastPathComponent ?? ""])
                    self.panel.status("bench saved \(tag)")
                }
            }
        }
    }
    private func writeProgress(_ d: [String: Any]) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: d).write(to: dir.appendingPathComponent("bench-done.json"))
    }
}

/// The switch panel. One row per switch; the same names as the launch arguments (GFSettings.swift).
final class GFPanel: UIView {
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private let statusLabel = UILabel()
    private var timer: Timer?
    private var recording = false
    var onSave: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.10, alpha: 0.88)
        layer.cornerRadius = 14
        overrideUserInterfaceStyle = .dark
        addSubview(scroll); scroll.addSubview(stack)
        stack.axis = .vertical; stack.spacing = 8
        let S = GFSettings.shared
        let isMac = ProcessInfo.processInfo.isMacCatalystApp
        row("Case", GFSettings.Case.allCases.map(\.rawValue), GFSettings.Case.allCases.firstIndex(of: S.caseName)!) { S.caseName = GFSettings.Case.allCases[$0] }
        row("Theme", ["Light", "Dark"], S.theme == .light ? 0 : 1) { S.theme = $0 == 0 ? .light : .dark }
        row("Glass", ["Off", "Clear 0.6"], S.glass ? 1 : 0) { S.glass = $0 == 1 }
        row("Edge bend", ["Off", "0.5"], S.edgeBend ? 1 : 0) { S.edgeBend = $0 == 1 }
        row("Variant", GFVariant.allCases.map(\.rawValue), GFVariant.allCases.firstIndex(of: S.variant)!) { S.variant = GFVariant.allCases[$0] }
        row("Hash", ["Stable", "Bench"], S.benchHash ? 1 : 0) { S.benchHash = $0 == 1 }
        row("Pools", GFPoolsMode.allCases.map(\.rawValue), GFPoolsMode.allCases.firstIndex(of: S.pools)!) { S.pools = GFPoolsMode.allCases[$0] }
        row("Live", ["Off", "30", "60"], !S.live ? 0 : (S.liveRate == 60 ? 2 : 1)) { i in
            if i == 0 { S.live = false } else { S.liveRate = i == 2 ? 60 : 30; S.live = true }
        }
        row("Flat control", ["Off", "On"], S.flat ? 1 : 0) { S.flat = $0 == 1 }
        row("Map master", ["128 px", "256 px"], S.mapCap >= 256 ? 1 : 0) { S.mapCap = $0 == 1 ? 256 : 128 }
        if isMac {
            row("Detail fit (presets)", ["Bench", "Width"], S.detailFitWidth ? 1 : 0) { S.detailZoom = nil; S.detailFitWidth = $0 == 1 }
            slider("Detail scale (Bench 0 → Width 1)", -0.15, 1.15, 0) { [weak self] v in self?.onDetailScale?(v) }
            row("Scrolled band", ["On", "Off", "Only"], ["on", "off", "only"].firstIndex(of: S.scrolledBand) ?? 0) { S.scrolledBand = ["on", "off", "only"][$0] }
        }
        row("Dark-cast fix", ["Off", "On"], S.deepFix ? 1 : 0) { S.deepFix = $0 == 1 }
        row("Live layer scale", ["Display", "2×"], S.liveScale == 2 ? 1 : 0) { S.liveScale = $0 == 1 ? 2 : nil }
        row("Live card zone", ["Whole card", "Image zone"], S.liveZoneImage ? 1 : 0) { S.liveZoneImage = $0 == 1 }
        row("Scroll redraw", ["Off (move)", "On (round 1)"], S.scrollRedraw ? 1 : 0) { S.scrollRedraw = $0 == 1 }
        row("Map reveal", ["On", "All Good Flow"], S.reveal ? 0 : 1) { S.reveal = $0 == 0 }
        slider("Reveal size (on-screen pt)", 20, 240, Float(S.revealSize)) { S.revealSize = $0 }
        slider("Reveal annulus (pt from centre)", 60, 1400, Float(S.revealAnnulus)) { S.revealAnnulus = $0 }
        slider("Reveal blend (soft)", 0.02, 0.6, Float(S.revealSoft)) { S.revealSoft = $0 }
        let simIdx = S.simReduceMotion ? 1 : S.simLowPower ? 2 : S.simThermal >= 2 ? 3 : 0
        row("Simulate", ["None", "Reduce Motion", "Low Power", "Thermal"], simIdx) { i in
            S.simReduceMotion = i == 1; S.simLowPower = i == 2; S.simThermal = i == 3 ? 2 : 0
        }
        row("Record", ["Off", "Recording"], 0) { [weak self] i in self?.setRecording(i == 1) }
        // Standing rule (AirPad CLAUDE.md, dev tuners): a "Copy values" button. T dials, then reports what he landed on.
        let copy = UIButton(type: .system, primaryAction: UIAction(title: "Copy values") { [weak self] _ in self?.onCopy?() })
        copy.contentHorizontalAlignment = .leading
        copy.accessibilityIdentifier = "panel.copyValues"
        stack.addArrangedSubview(copy)
        let save = UIButton(type: .system, primaryAction: UIAction(title: isMac ? "Save recording now (⌃⌥⌘P)" : "Save recording now") { [weak self] _ in self?.onSave?() })
        save.contentHorizontalAlignment = .leading
        stack.addArrangedSubview(save)
        let note = UILabel()
        note.text = "Housing dials are the bench defaults (T's were never saved)"
        note.font = .systemFont(ofSize: 12); note.numberOfLines = 0; note.textColor = UIColor(white: 0.85, alpha: 1)
        stack.addArrangedSubview(note)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); statusLabel.numberOfLines = 0
        statusLabel.textColor = UIColor(white: 0.8, alpha: 1)
        stack.addArrangedSubview(statusLabel)
        accessibilityIdentifier = "panel"
    }
    required init?(coder: NSCoder) { fatalError() }

    var onDetailScale: ((Double) -> Void)?
    var onCopy: (() -> Void)?
    /// A continuous dial; its value is shown beside its name.
    func slider(_ title: String, _ lo: Float, _ hi: Float, _ v: Float, _ act: @escaping (Double) -> Void) {
        let l = UILabel(); l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .white
        l.text = String(format: "%@: %.2f", title, v)
        let sl = UISlider(); sl.minimumValue = lo; sl.maximumValue = hi; sl.value = v
        sl.accessibilityIdentifier = "slider." + title.lowercased().replacingOccurrences(of: " ", with: "")
        sl.addAction(UIAction { a in
            let x = Double((a.sender as! UISlider).value); l.text = String(format: "%@: %.2f", title, x); act(x)
        }, for: .valueChanged)
        let v = UIStackView(arrangedSubviews: [l, sl]); v.axis = .vertical; v.spacing = 3
        stack.addArrangedSubview(v)
    }
    private func row(_ title: String, _ items: [String], _ sel: Int, _ act: @escaping (Int) -> Void) {
        let l = UILabel(); l.text = title; l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .white
        let seg = UISegmentedControl(items: items); seg.selectedSegmentIndex = sel
        seg.accessibilityIdentifier = "switch." + title.lowercased().replacingOccurrences(of: " ", with: "")
        seg.addAction(UIAction { a in act((a.sender as! UISegmentedControl).selectedSegmentIndex) }, for: .valueChanged)
        let v = UIStackView(arrangedSubviews: [l, seg]); v.axis = .vertical; v.spacing = 3
        stack.addArrangedSubview(v)
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        stack.systemLayoutSizeFitting(CGSize(width: width - 24, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height + 24
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let h = fittingHeight(width: bounds.width) - 24
        stack.frame = CGRect(x: 12, y: 12, width: bounds.width - 24, height: h)
        scroll.contentSize = CGSize(width: bounds.width, height: h + 24)
    }

    /// The status line ticks once a second only while the panel is open (a closed panel costs nothing at rest).
    func setLive(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }
    private func update() {
        let S = GFSettings.shared
        statusLabel.text = "\(S.describe)\nrecorded frames \(GFRecorder.shared.frameCount) · footprint \(String(format: "%.0f", GFRecorder.physFootprintMB())) MB"
            + (recording ? " · RECORDING" : "") + (S.liveBlockedBy.map { "\nlive blocked: \($0)" } ?? "")
    }
    func status(_ s: String) { statusLabel.text = s }

    private func setRecording(_ on: Bool) {
        let rec = GFRecorder.shared
        if on { rec.reset(); rec.mark("manual recording start (T's hand)"); recording = true }
        else if recording {
            recording = false
            let url = rec.save(name: "manual-" + GFRecorder.stamp(), meta: (GFRecorder.extraMeta?() ?? [:]).merging(["input": "T"]) { $1 })
            status("saved \(url?.lastPathComponent ?? "FAILED")")
        }
    }
}
