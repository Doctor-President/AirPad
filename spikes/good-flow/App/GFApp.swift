// Good Flow spike (throwaway, never merged) · app entry, launch modes, and the tiny test screen.
// No library code at all: every entry is synthetic (look.json).
//
// Launch modes (arguments, also UserDefaults keys):
//   -RenderStills <dir>     render the 120 reference stills into <dir> (relative = Documents in the container), then quit
//     -StillsGrain 0        bake without the final grain term     -StillsRepeat N   timing draws per still (default 5)
//     -StillsOnly <substr>  only stills whose name contains it    -ShaderVariant metallib|safe|fast|precise-sin
//   -Measure3b <dir>        step 3B's offscreen numbers (variants, equality stills, Map memory per cap, fills), then quit
//   -Screen test            part A's test screen
//   (none)                  the three cases (GFRootViewController); switches in GFSettings.swift, bench runs below
import UIKit

@main
final class GFAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = GFRecorder.shared
        // Scripted runs on the phone (bench readings, stills): keep the screen awake, or Auto-Lock suspends the app mid-
        // reading (T's touch, 2026-11-27: benches 2 and 4 stalled at "moving" ~5 min after the last touch).
        let d = UserDefaults.standard
        if d.string(forKey: "Bench") != nil || d.string(forKey: "RenderStills") != nil { application.isIdleTimerDisabled = true }
        if let dir = UserDefaults.standard.string(forKey: "RenderStills") {
            DispatchQueue.main.async {
                GFStillsBatch.run(dir: dir)
                exit(0)
            }
        }
        if let dir = UserDefaults.standard.string(forKey: "Measure3b") {   // step 3B's offscreen numbers (GFMeasure.swift)
            DispatchQueue.global(qos: .userInitiated).async {
                GFMeasure.run(dir: dir)
                exit(0)
            }
        }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting s: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: s.role)
        c.delegateClass = GFSceneDelegate.self
        return c
    }
}

final class GFSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UserDefaults.standard.string(forKey: "Screen") == "test" ? GFTestViewController() : GFRootViewController()
        w.makeKeyAndVisible()
        window = w
        #if targetEnvironment(macCatalyst)
        ws.title = "Good Flow"
        ws.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 500)
        #endif
    }
}

/// The test screen: a detail image (full width, the bench's detail height) live in a LiveSurfaceView, in a scroll view
/// (scrolling is an input wake), with light / dark, entry, live on/off, 30/60 and save-recording controls.
final class GFTestViewController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let surface = LiveSurfaceView()
    private let status = UILabel()
    private var theme: GFTheme = .light
    private var entryIndex = 0
    private var statusTimer: Timer?

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Save recording", action: #selector(saveRecording), input: "p", modifierFlags: [.control, .alternate, .command])]
    }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        surface.surfaceName = "detail"
        scroll.addSubview(surface)

        let themeSeg = UISegmentedControl(items: ["Light", "Dark"]); themeSeg.selectedSegmentIndex = 0
        themeSeg.addAction(UIAction { [weak self] a in self?.theme = (a.sender as! UISegmentedControl).selectedSegmentIndex == 0 ? .light : .dark; self?.apply() }, for: .valueChanged)
        let entrySeg = UISegmentedControl(items: GFLook.shared.entries.map(\.id)); entrySeg.selectedSegmentIndex = 0
        entrySeg.addAction(UIAction { [weak self] a in self?.entryIndex = (a.sender as! UISegmentedControl).selectedSegmentIndex; self?.apply() }, for: .valueChanged)
        let liveSeg = UISegmentedControl(items: ["Still", "Live 30", "Live 60", "Flat 30"]); liveSeg.selectedSegmentIndex = 0
        liveSeg.addAction(UIAction { [weak self] a in
            guard let self else { return }
            let i = (a.sender as! UISegmentedControl).selectedSegmentIndex
            self.surface.liveRate = i == 2 ? 60 : 30
            self.flat = i == 3
            self.apply()
            self.surface.isLive = i != 0
        }, for: .valueChanged)
        let save = UIButton(type: .system, primaryAction: UIAction(title: "Save recording (⌃⌥⌘P)") { [weak self] _ in self?.saveRecording() })
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular); status.numberOfLines = 0

        let controls = UIStackView(arrangedSubviews: [themeSeg, entrySeg, liveSeg, save, status])
        controls.axis = .vertical; controls.spacing = 10; controls.alignment = .leading
        controls.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(controls)
        controls.tag = 7
        apply()
        if UserDefaults.standard.double(forKey: "AutoRecord") == 0 {   // scripted runs keep the main thread quiet
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
        }
    }
    private var flat = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); becomeFirstResponder()
        if !scripted { scripted = true; runScript() }
    }
    private var scripted = false

    /// Headless checks of the rest rule (no taps needed). Arguments:
    ///   -TestTheme light|dark  -TestEntry e0…e5  -TestMode still|live30|live60|flat30
    ///   -TestInputPulse <s>    from 1 s after launch, an input wake every 50 ms for <s> seconds (stands in for a scroll)
    ///   -TestLiveOffAt <s>     switch live off at <s> seconds (the rest that follows must be 0 ticks)
    ///   -AutoRecord <s>        save the recording (Documents/recordings/<-AutoRecordName or auto>.json) at <s>, then
    ///   -AutoQuit YES          quit
    private func runScript() {
        let d = UserDefaults.standard
        if d.string(forKey: "TestTheme") == "dark" { theme = .dark }
        if let e = d.string(forKey: "TestEntry"), let i = GFLook.shared.entries.firstIndex(where: { $0.id == e }) { entryIndex = i }
        switch d.string(forKey: "TestMode") ?? "still" {
        case "live30": surface.liveRate = 30; surface.isLive = true
        case "live60": surface.liveRate = 60; surface.isLive = true
        case "flat30": surface.liveRate = 30; flat = true; surface.isLive = true
        default: break
        }
        apply()
        let pulse = d.double(forKey: "TestInputPulse")
        if pulse > 0 {
            let start = CACurrentMediaTime() + 1
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                let now = CACurrentMediaTime()
                if now > start + pulse { t.invalidate(); GFRecorder.shared.mark("input pulse end"); return }
                if now >= start { self?.surface.noteInput() }
            }
            GFRecorder.shared.mark("input pulse start", at: start)
        }
        let off = d.double(forKey: "TestLiveOffAt")
        if off > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + off) { [weak self] in self?.surface.isLive = false } }
        let rec = d.double(forKey: "AutoRecord")
        if rec > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + rec) { [weak self] in
                guard let self else { return }
                GFRecorder.shared.save(name: d.string(forKey: "AutoRecordName"), meta: [
                    "screen": "test", "mode": d.string(forKey: "TestMode") ?? "still", "entry": GFLook.shared.entries[self.entryIndex].id,
                    "theme": self.theme.rawValue, "drawnFrames": self.surface.drawnFrames, "ticks": self.surface.ticks,
                    "drawable": [self.surface.metalLayer.drawableSize.width, self.surface.metalLayer.drawableSize.height]])
                if d.bool(forKey: "AutoQuit") { exit(0) }
            }
        }
    }

    private var detailHeight: CGFloat {
        ProcessInfo.processInfo.isMacCatalystApp ? 252 : 262    // the reference's detail-mac / detail-iphone heights (pt)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
        let w = view.bounds.width
        let f = CGRect(x: 0, y: 0, width: w, height: detailHeight)
        if surface.frame != f { surface.frame = f; apply() }
        if let c = scroll.viewWithTag(7) {
            let sz = c.systemLayoutSizeFitting(CGSize(width: w - 32, height: 0))
            c.frame = CGRect(x: 16, y: detailHeight + 16, width: w - 32, height: sz.height)
            scroll.contentSize = CGSize(width: w, height: max(view.bounds.height * 2, c.frame.maxY + 400))
        }
    }

    private func apply() {
        guard surface.bounds.width > 0 else { return }
        let s = Double(view.window?.traitCollection.displayScale ?? traitCollection.displayScale)
        let cs = GFCase.detail(widthPt: Double(surface.bounds.width), heightPt: Double(surface.bounds.height), scale: s)
        var u = GFUniforms.make(cs, GFLook.shared.entries[entryIndex], theme)
        u.flat = flat ? 1 : 0
        surface.base = u
        view.backgroundColor = theme == .light ? UIColor(white: 0.83, alpha: 1) : .black
        overrideUserInterfaceStyle = theme == .light ? .light : .dark
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        guard s.isTracking || s.isDragging || s.isDecelerating else { return }   // layout-time offsets are not input
        surface.noteInput(); surface.reevaluate()
    }

    private func updateStatus() {
        let r = GFRecorder.shared
        status.text = "frames \(surface.drawnFrames) · ticks \(surface.ticks) · recorded \(r.frameCount) · t \(String(format: "%.2f", surface.currentTime)) · live \(surface.isLive) allowed \(surface.liveAllowed)"
    }

    @objc func saveRecording() {
        let url = GFRecorder.shared.save(meta: ["screen": "test", "entry": GFLook.shared.entries[entryIndex].id, "theme": theme.rawValue,
                                                "live": surface.isLive, "liveRate": surface.liveRate, "flat": flat])
        status.text = "saved \(url?.lastPathComponent ?? "FAILED")"
    }
}
