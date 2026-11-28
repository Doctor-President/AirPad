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
    private var paragraphs: [UILabel] = []
    private let hostLink = GFHostLink()
    private var programmatic: CADisplayLink?
    private var progStart = 0.0
    private let entry = GFLook.shared.entries[0]
    private var settingsObs: NSObjectProtocol?

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
            l.text = i == 0 ? "Entry 3 · placeholder title"
                : "Entry 3 · placeholder paragraph \(i). " + String(repeating: "Invented words stand in for the entry's text so the page has something to scroll; none of it comes from a library. ", count: 3)
            scroll.addSubview(l); paragraphs.append(l)
        }
        settingsObs = NotificationCenter.default.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    }
    deinit { settingsObs.map(NotificationCenter.default.removeObserver); programmatic?.invalidate(); hostLink.stop() }

    private var bandHeight: CGFloat { 200 + view.safeAreaInsets.top }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
        let w = view.bounds.width
        let f = CGRect(x: 0, y: 0, width: w, height: bandHeight)
        if band.frame != f { band.frame = f; apply() }
        let colW = min(720, w - 40), x = (w - colW) / 2
        var y = f.maxY + 20
        for l in paragraphs {
            let h = l.sizeThatFits(CGSize(width: colW, height: .greatestFiniteMagnitude)).height
            l.frame = CGRect(x: x, y: y, width: colW, height: h); y += h + 16
        }
        scroll.contentSize = CGSize(width: w, height: max(y + 200, view.bounds.height * 2.2))
    }

    /// The band's uniforms: the bench's detail image at the band's size (+ the Mac's fit switch and the housing switches).
    static func uniforms(widthPt: Double, heightPt: Double, scale: Double, entry: GFEntry, theme: GFTheme, fitWidth: Bool) -> GFUniforms {
        let cs = GFCase.detail(widthPt: widthPt, heightPt: heightPt, scale: scale)
        var u = GFUniforms.make(cs, entry, theme)
        if fitWidth { u.zoom = Float(max(widthPt, heightPt) / min(widthPt, heightPt)) }   // hm = .5 × width
        GFSettings.shared.apply(&u)
        return u
    }

    func apply() {
        guard band.bounds.width > 0 else { return }
        let S = GFSettings.shared
        let s = Double(view.window?.traitCollection.displayScale ?? traitCollection.displayScale)
        band.mode = S.mode
        band.liveRate = S.liveRate
        band.base = Self.uniforms(widthPt: Double(band.bounds.width), heightPt: Double(band.bounds.height), scale: s, entry: entry,
                                  theme: S.theme, fitWidth: ProcessInfo.processInfo.isMacCatalystApp && S.detailFitWidth)
        band.isLive = S.live
        view.backgroundColor = GFSettings.pageColor(S.theme)
        scroll.backgroundColor = view.backgroundColor
        let ink: UIColor = S.theme == .light ? UIColor(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : UIColor(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255, alpha: 1)
        paragraphs.forEach { $0.textColor = ink }
        band.reevaluate()
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

    func scrollViewDidScroll(_ s: UIScrollView) {
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

    var recordingMeta: [String: Any] {
        ["screen": "detail", "band": [band.bounds.width, band.bounds.height], "drawable": [band.metalLayer.drawableSize.width, band.metalLayer.drawableSize.height],
         "drawnFrames": band.drawnFrames, "ticks": band.ticks, "liveAllowed": band.liveAllowed, "liveBlockedBy": GFSettings.shared.liveBlockedBy ?? "",
         "mode": band.mode.label, "programmatic": programmatic != nil]
    }
}
