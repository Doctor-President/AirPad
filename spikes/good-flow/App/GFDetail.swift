// Good Flow spike (throwaway, never merged) · case (a): the detail view's image, live.
// A scroll view; the image band at the top is part of the page (it scrolls with it): iPhone 440 × (200 + the safe-area
// top) pt, Mac the window's width × (200 + the top inset). Square corners, the foot fading into the page (uFadeB 0.24),
// a page of placeholder text below. The band is a LiveSurfaceView: live 30 a second (60 a switch); scrolling is an input
// wake (the trial's rule); at rest only the live clock draws, and with live off nothing does.
// Mac switch "Detail fit": bench = the bench's own sizing (the field by the band's short side, centred: in this spike the
// document column is the window, there is no Librarian column); width = the field scaled to the band's width (sheet
// option 2). Option 3 (more pools across the width) is a shader change and is not built.
import UIKit

protocol GFCaseScreen: UIViewController {
    /// Programmatic motion for the bench runs (scroll / swipe / pan-and-zoom loop). Recorded as "programmatic".
    func setProgrammatic(_ on: Bool)
    /// What the screen adds to a saved recording.
    var recordingMeta: [String: Any] { get }
    /// Round 2: the screen's geometry / state for a `-Script` dump (what is on screen, measured, not inferred).
    var diagnostics: [String: Any] { get }
    /// Round 2: a screen-specific `-Script` action (e.g. "scroll:300"); returns false if it is not this screen's.
    func scriptAction(_ verb: String, _ arg: String) -> Bool
}
extension GFCaseScreen {
    var diagnostics: [String: Any] { recordingMeta }
    func scriptAction(_ verb: String, _ arg: String) -> Bool { false }
}

final class GFDetailViewController: UIViewController, UIScrollViewDelegate, GFCaseScreen {
    private let scroll = UIScrollView()
    let band = LiveSurfaceView()
    /// Round 2 (outcome 1): today's AirPad Mac detail collapses its hero into a pinned band (top inset + 52 pt, full width)
    /// that fades in as the hero scrolls away (NodeDetailView.collapsedBand on ws-mac: opacity = scroll offset / the hero's
    /// visible height). Here that band shows Good Flow at WIDTH scale, as a still (AirPad's band is static too).
    let pinned = LiveSurfaceView()
    private let scaleLabel = UILabel()
    private var paragraphs: [UILabel] = []
    private let hostLink = GFHostLink()
    private var programmatic: CADisplayLink?
    private var progStart = 0.0
    private let entry = GFLook.shared.entries[0]
    private var settingsObs: NSObjectProtocol?
    private let isMac = ProcessInfo.processInfo.isMacCatalystApp

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "detail.scroll"
        view.addSubview(scroll)
        band.surfaceName = "detail"
        band.accessibilityIdentifier = "detail.band"
        scroll.addSubview(band)
        for i in 0..<14 {
            let l = UILabel()
            l.numberOfLines = 0
            l.font = i == 0 ? .systemFont(ofSize: 28, weight: .semibold) : .systemFont(ofSize: 17)
            l.text = i == 0 ? "Entry 0 · placeholder title"
                : "Entry 0 · placeholder paragraph \(i). " + String(repeating: "Invented words stand in for the entry's text so the page has something to scroll; none of it comes from a library. ", count: 3)
            scroll.addSubview(l); paragraphs.append(l)
        }
        pinned.surfaceName = "detailBand"
        pinned.isUserInteractionEnabled = false
        view.addSubview(pinned)
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = .white; scaleLabel.backgroundColor = UIColor(white: 0, alpha: 0.45)
        scaleLabel.layer.cornerRadius = 6; scaleLabel.layer.masksToBounds = true; scaleLabel.textAlignment = .center
        scaleLabel.accessibilityIdentifier = "detail.scaleLabel"
        view.addSubview(scaleLabel)
        settingsObs = NotificationCenter.default.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    }
    deinit { settingsObs.map(NotificationCenter.default.removeObserver); programmatic?.invalidate(); hostLink.stop() }

    private var bandHeight: CGFloat { 200 + view.safeAreaInsets.top }
    /// AirPad's collapsed band: the top inset + its 52 pt chrome row.
    private var pinnedHeight: CGFloat { view.safeAreaInsets.top + 52 }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
        let w = view.bounds.width
        let f = CGRect(x: 0, y: 0, width: w, height: bandHeight)
        let pf = CGRect(x: 0, y: 0, width: w, height: pinnedHeight)
        var changed = false
        if band.frame != f { band.frame = f; changed = true }
        if pinned.frame != pf { pinned.frame = pf; changed = true }
        if changed { apply() }
        let colW = min(720, w - 40), x = (w - colW) / 2
        var y = f.maxY + 20
        for l in paragraphs {
            let h = l.sizeThatFits(CGSize(width: colW, height: .greatestFiniteMagnitude)).height
            l.frame = CGRect(x: x, y: y, width: colW, height: h); y += h + 16
        }
        scroll.contentSize = CGSize(width: w, height: max(y + 200, view.bounds.height * 2.2))
        layoutLabel()
        updatePinned()
    }
    private func layoutLabel() {
        let sz = scaleLabel.sizeThatFits(CGSize(width: 600, height: 30))
        scaleLabel.frame = CGRect(x: 12 + view.safeAreaInsets.left, y: view.bounds.height - sz.height - 14 - view.safeAreaInsets.bottom, width: sz.width + 16, height: sz.height + 6)
    }

    /// The Mac detail zoom (outcome 1): 1 = Bench (the field by the band's short side), w / h = Width. -DetailZoom, the panel's
    /// Scale slider; -DetailFit width = Width.
    static func zoomRange(widthPt: Double, heightPt: Double) -> (bench: Double, width: Double) { (1, max(widthPt, heightPt) / min(widthPt, heightPt)) }
    func currentZoom() -> Double {
        let S = GFSettings.shared
        guard isMac else { return 1 }
        let r = Self.zoomRange(widthPt: Double(band.bounds.width), heightPt: Double(band.bounds.height))
        if let z = S.detailZoom { return z }
        return S.detailFitWidth ? r.width : r.bench
    }

    /// The band's uniforms: the bench's detail image at the band's size, its field `zoom` × the bench's own size, centred
    /// on the document column (the window's centre here: no Librarian column), + the housing switches.
    static func uniforms(widthPt: Double, heightPt: Double, scale: Double, entry: GFEntry, theme: GFTheme, zoom: Double) -> GFUniforms {
        let cs = GFCase.detail(widthPt: widthPt, heightPt: heightPt, scale: scale)
        var u = GFUniforms.make(cs, entry, theme)
        u.zoom = Float(zoom)
        GFSettings.shared.apply(&u)
        return u
    }

    func apply() {
        guard band.bounds.width > 0 else { return }
        let S = GFSettings.shared
        let s = Double(view.window?.traitCollection.displayScale ?? traitCollection.displayScale)
        band.mode = S.mode
        band.liveRate = S.liveRate
        let bw = Double(band.bounds.width), bh = Double(band.bounds.height)
        band.base = Self.uniforms(widthPt: bw, heightPt: bh, scale: s, entry: entry, theme: S.theme, zoom: currentZoom())
        band.isLive = S.live
        // the pinned band: Width scale (its own width / height), a still
        let pw = Double(pinned.bounds.width), ph = Double(max(pinned.bounds.height, 1))
        pinned.mode = S.mode
        var pu = Self.uniforms(widthPt: pw, heightPt: ph, scale: s, entry: entry, theme: S.theme, zoom: max(pw, ph) / min(pw, ph))
        pu.fadeB = 0                                   // AirPad's band has a hard foot (the chrome row's edge)
        pinned.base = pu
        pinned.isLive = false
        view.backgroundColor = GFSettings.pageColor(S.theme)
        scroll.backgroundColor = view.backgroundColor
        let ink: UIColor = S.theme == .light ? UIColor(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : UIColor(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255, alpha: 1)
        paragraphs.forEach { $0.textColor = ink }
        let r = Self.zoomRange(widthPt: bw, heightPt: bh), z = currentZoom()
        let pos = log(z) / max(log(r.width), 1e-6)   // 0 = Bench, 1 = Width
        scaleLabel.text = isMac ? String(format: "Scale %.2f · zoom %.2f× (Bench 1×, Width %.2f×) · band %@ · %@", pos, z, r.width, S.scrolledBand, S.variant.rawValue)
                                : String(format: "zoom %.2f× · %@", z, S.variant.rawValue)
        layoutLabel()
        band.reevaluate()
        updatePinned()
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

    /// The pinned band's opacity: AirPad's bandProgress = scroll offset / the hero's visible height, clamped 0…1.
    private func updatePinned() {
        let mode = GFSettings.shared.scrolledBand
        let p = min(1, max(0, scroll.contentOffset.y / max(band.bounds.height, 1)))
        let a: CGFloat = mode == "only" ? 1 : (mode == "off" ? 0 : p)
        pinned.isHidden = a <= 0.001
        if pinned.alpha != a { pinned.alpha = a }
        if mode == "only" { band.isHidden = true } else if band.isHidden { band.isHidden = false }
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        updatePinned()
        guard s.isTracking || s.isDragging || s.isDecelerating || programmatic != nil else { return }   // layout offsets are not input
        band.noteInput(); band.reevaluate(); hostLink.noteInput()
    }

    // MARK: programmatic motion (bench runs): the page scrolls down 900 pt and back every 4 s, eased.
    func setProgrammatic(_ on: Bool) {
        let was = programmatic != nil
        programmatic?.invalidate(); programmatic = nil
        guard on else {
            if was { scroll.setContentOffset(.zero, animated: false); band.reevaluate() }   // the rest row: the band on screen
            GFRecorder.shared.mark("programmatic end"); return
        }
        GFRecorder.shared.mark("programmatic start: detail scroll loop (900 pt, 4 s period)")
        progStart = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(progStep(_:)))
        let m = Float(UIScreen.main.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, m), maximum: m, preferred: m)
        l.add(to: .main, forMode: .common); programmatic = l
    }
    @objc private func progStep(_ l: CADisplayLink) {
        let t = l.targetTimestamp - progStart
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.contentOffset.y = min(maxY, 900) * (1 - cos(2 * .pi * t / 4)) / 2
    }

    /// Round 2 · -Script verbs: zoom:<z> | scale:<0…1, Bench → Width> | scroll:<y pt> | still:<name> (the band's current
    /// frame drawn OFFSCREEN with its own uniforms and mode → Documents/r2/<name>.png; the pinned band too as <name>-band)
    /// | override:k=v|k=v | band:on|off|only | deep:on|off.
    func scriptAction(_ verb: String, _ arg: String) -> Bool {
        let S = GFSettings.shared
        switch verb {
        case "zoom": S.detailZoom = Double(arg)
        case "scale":
            guard let v = Double(arg) else { return false }
            let r = Self.zoomRange(widthPt: Double(band.bounds.width), heightPt: Double(band.bounds.height))
            S.detailZoom = exp(v * log(r.width))
        case "scroll": scroll.setContentOffset(CGPoint(x: 0, y: Double(arg) ?? 0), animated: false); updatePinned()
        case "override": S.overrides = GFSettings.parseOverrides(arg)
        case "band": S.scrolledBand = arg
        case "deep": S.deepFix = arg == "on"
        case "still":
            writeStill(band, name: arg)
            if !pinned.isHidden { writeStill(pinned, name: arg + "-band") }
        default: return false
        }
        return true
    }
    private func writeStill(_ v: LiveSurfaceView, name: String) {
        let sz = v.metalLayer.drawableSize
        let u = v.frameUniforms(width: Int(sz.width), height: Int(sz.height))
        let r = GFStillRenderer(); r.mode = v.mode
        let res = r.render(u)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("r2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? GFStillRenderer.writePNG(res, to: dir.appendingPathComponent(name + ".png"))
        GFRecorder.shared.mark(String(format: "still %@ %dx%d zoom %.3f gpu %.2f ms", name, res.width, res.height, Double(u.zoom), res.gpuMs))
    }

    var recordingMeta: [String: Any] {
        ["screen": "detail", "band": [band.bounds.width, band.bounds.height], "drawable": [band.metalLayer.drawableSize.width, band.metalLayer.drawableSize.height],
         "drawnFrames": band.drawnFrames, "ticks": band.ticks, "liveAllowed": band.liveAllowed, "liveBlockedBy": GFSettings.shared.liveBlockedBy ?? "",
         "mode": band.mode.label, "programmatic": programmatic != nil, "zoom": currentZoom(), "scaleLabel": scaleLabel.text ?? "",
         "pinned": [pinned.bounds.width, pinned.bounds.height, pinned.alpha], "pinnedDrawn": pinned.drawnFrames, "scrollY": scroll.contentOffset.y]
    }
}
