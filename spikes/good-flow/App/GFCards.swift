// Good Flow spike (throwaway, never merged) · case (b): cards as stills, one live.
// A real UICollectionView. Mac: a grid of the 262 synthetic entries, 228 × 320 pt, spacing 10, corners 14, image zone the
// top 43 %, the title below (colour ends above the words: uFadeV); the HOVERED card comes alive in its own card-sized
// LiveSurfaceView over its still, starting at the still's time value, and goes back to a still (redrawn at the last
// live frame's time) when the pointer leaves. iPhone: a horizontal paging carousel of 0.79 × width cards (348 × 532 at
// 440), corners 30, image zone the top 40 %; the CENTRED card is live.
// Stills: drawn once each by GFDraw (the same variant + hash as the live card) into an IOSurface the cell's layer shows
// directly (no copy); visible cards first, then one screen each way; everything else evicted; a byte budget
// (-CardsBudgetMB, default 40) drops the farthest first. Until a still lands the card shows a flat fill in its hue.
// Flat control (-Flat on): the same host, flat stills, the live layer drawing flat.
import UIKit
import Metal
import IOSurface

/// One card's still: an IOSurface (the layer's contents) with a Metal texture over the same memory.
final class GFCardStill {
    let surface: IOSurface
    let tex: MTLTexture
    let time: Double
    let mode: GFDrawMode
    let flat: Bool
    var bytes: Int { surface.allocationSize }
    init?(w: Int, h: Int, time: Double, mode: GFDrawMode, flat: Bool) {
        guard let s = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .pixelFormat: 0x42475241 /* 'BGRA' */]) else { return nil }
        if let cs = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() { IOSurfaceSetValue(s, kIOSurfaceColorSpace, cs) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let t = GFRenderer.shared.device.makeTexture(descriptor: td, iosurface: s, plane: 0) else { return nil }
        surface = s; tex = t; self.time = time; self.mode = mode; self.flat = flat
    }
}

/// The stills, filled off the main thread on their own queue, visible first. Main thread: `want`, `still(for:)`.
final class GFCardStillCache {
    struct Job { let item: Int; let u: GFUniforms; let time: Double; let gen: Int; let reason: String }
    private(set) var stills: [Int: GFCardStill] = [:]
    private var jobs: [Job] = []            // guarded by lock, highest priority first
    private var inFlight = Set<Int>()       // main
    var inFlightCount: Int { inFlight.count }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "gf.cards.fill", qos: .userInitiated)
    private let cq = GFRenderer.shared.device.makeCommandQueue()!
    private let scratch = GFScratch()
    private var running = false             // guarded by lock
    private(set) var generation = 0
    var budgetBytes: Int
    var onReady: ((Int) -> Void)?
    private(set) var truncated = 0          // items the budget dropped from the last wanted set
    private(set) var filled = 0
    private(set) var fillStart: Double?
    private(set) var firstVisibleDoneAt: Double?
    private var visibleWaiting = Set<Int>()

    init(budgetMB: Double) { budgetBytes = Int(budgetMB * 1_048_576) }

    var totalBytes: Int { stills.values.reduce(0) { $0 + $1.bytes } }
    func still(for i: Int) -> GFCardStill? { stills[i] }

    /// Everything changes (theme, variant, hash, switches, size): drop it all and refill.
    func invalidate() {
        generation += 1; stills.removeAll(); inFlight.removeAll()
        lock.lock(); jobs.removeAll(); lock.unlock()
        firstVisibleDoneAt = nil; fillStart = nil; filled = 0
    }

    /// `wanted` in priority order (visible first); `bytesEach` the size of one still; `make` the uniforms for an item.
    func want(_ wanted: [Int], visible: Set<Int>, bytesEach: Int, make: (Int) -> GFUniforms) {
        var keep = wanted
        if budgetBytes > 0, bytesEach > 0 {
            let fit = max(visible.count, budgetBytes / bytesEach)
            truncated = max(0, keep.count - fit); keep = Array(keep.prefix(fit))
        } else { truncated = 0 }
        let keepSet = Set(keep)
        for k in stills.keys where !keepSet.contains(k) { stills[k] = nil }
        // Round 2 fix (outcome 3, the light Cards break): the queue is rebuilt in the new priority order, and an item whose
        // queued job is dropped LEAVES inFlight. Before, a second want() while fills were queued threw their jobs away but
        // left them inFlight, so they were never queued again: those cards showed the flat fill until a theme / variant
        // switch cleared the cache (T's 16:06: the first want ran at the layout's default 50 × 50 item size, queued all
        // 262, the next want dropped 252 of them).
        lock.lock()
        let dropped = jobs.filter { !(keepSet.contains($0.item) && $0.gen == generation) || $0.reason == "fill" }
        jobs.removeAll { !(keepSet.contains($0.item) && $0.gen == generation) || $0.reason == "fill" }
        lock.unlock()
        var orphanedDone: [() -> Void] = []
        for j in dropped {
            inFlight.remove(j.item)
            if j.reason != "fill", let d = pendingDone.removeValue(forKey: j.item) { orphanedDone.append(d) }   // its live surface goes
        }
        let missing = keep.filter { stills[$0] == nil && !inFlight.contains($0) }
        if fillStart == nil, !missing.isEmpty { fillStart = CACurrentMediaTime(); visibleWaiting = visible.filter { stills[$0] == nil } }
        let newJobs = missing.map { i -> Job in let u = make(i); return Job(item: i, u: u, time: Double(u.time), gen: generation, reason: "fill") }
        lock.lock()
        jobs += newJobs
        missing.forEach { inFlight.insert($0) }
        let start = !running && !jobs.isEmpty; if start { running = true }
        lock.unlock()
        orphanedDone.forEach { $0() }
        if start { queue.async { [weak self] in self?.drain() } }
    }

    /// The live card ended at `time`: its still is redrawn at that time value (the last live frame becomes the still).
    func redraw(_ i: Int, u: GFUniforms, done: @escaping () -> Void) {
        pendingDone[i] = done
        inFlight.insert(i)
        lock.lock()
        jobs.insert(Job(item: i, u: u, time: Double(u.time), gen: generation, reason: "liveEnded"), at: 0)
        let start = !running; if start { running = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }
    private var pendingDone: [Int: () -> Void] = [:]

    private func drain() {
        while true {
            lock.lock()
            guard !jobs.isEmpty else { running = false; lock.unlock(); return }
            let j = jobs.removeFirst()
            lock.unlock()
            let w = Int(j.u.res.x), h = Int(j.u.res.y)
            let t0 = CACurrentMediaTime()
            guard let st = GFCardStill(w: w, h: h, time: j.time, mode: currentMode, flat: j.u.flat == 1) else { continue }
            let cb = cq.makeCommandBuffer()!
            GFDraw.encode(cb, target: st.tex, j.u, currentMode, scratch: scratch)
            cb.commit()
            let encMs = (CACurrentMediaTime() - t0) * 1000
            cb.waitUntilCompleted()
            let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let m0 = CACurrentMediaTime()
                self.inFlight.remove(j.item)
                guard j.gen == self.generation else { return }
                self.stills[j.item] = st; self.filled += 1
                self.onReady?(j.item)
                if let d = self.pendingDone.removeValue(forKey: j.item) { d() }
                self.visibleWaiting.remove(j.item)
                if self.visibleWaiting.isEmpty, self.firstVisibleDoneAt == nil, let s = self.fillStart {
                    self.firstVisibleDoneAt = CACurrentMediaTime(); GFRecorder.shared.mark(String(format: "cards visible filled in %.0f ms", (self.firstVisibleDoneAt! - s) * 1000))
                }
                GFRecorder.shared.still(kind: "card", reason: j.reason, gpuMs: gpu, mainMs: encMs + (CACurrentMediaTime() - m0) * 1000, px: w * h)
            }
        }
    }
    /// The mode stills are drawn with (set on the main thread before `invalidate`; read by the fill queue).
    var currentMode: GFDrawMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    private var _mode = GFDrawMode()
}

final class GFCardCell: UICollectionViewCell {
    let stillView = UIView()
    let hueLayer = CALayer()
    let title = UILabel()
    let sub = UILabel()
    var item = -1
    weak var live: LiveSurfaceView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(stillView)
        stillView.layer.addSublayer(hueLayer)
        title.font = .systemFont(ofSize: 17, weight: .semibold); title.numberOfLines = 2
        sub.font = .systemFont(ofSize: 13); sub.numberOfLines = 2
        contentView.addSubview(title); contentView.addSubview(sub)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var geo: (CGFloat, CGFloat)?
    /// Round 2 fix (outcome 3): the cell lays its parts out on EVERY layout pass at its current bounds. Before, only
    /// configure() did, so a cell configured at any other size than its final one (the flow layout's default 50 × 50 item
    /// before viewDidLayoutSubviews set the real one) kept a thumbnail-sized picture and cut titles ("E…", "1 it…").
    override func layoutSubviews() {
        super.layoutSubviews()
        if let g = geo { place(heroFrac: g.0, radius: g.1) }
    }
    func layout(heroFrac: CGFloat, radius: CGFloat) {
        geo = (heroFrac, radius); place(heroFrac: heroFrac, radius: radius); setNeedsLayout()
    }
    private func place(heroFrac: CGFloat, radius: CGFloat) {
        stillView.frame = contentView.bounds
        let b = contentView.bounds
        hueLayer.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height * heroFrac)
        hueLayer.cornerRadius = radius; hueLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        stillView.layer.cornerRadius = radius
        let y = b.height * heroFrac + 14
        title.frame = CGRect(x: 16, y: y, width: b.width - 32, height: 46)
        sub.frame = CGRect(x: 16, y: y + 50, width: b.width - 32, height: 36)
        live?.frame = b
    }
    /// The still (IOSurface contents) or the flat fill in the entry's hue.
    func show(_ st: GFCardStill?, hue: Double, theme: GFTheme) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let st {
            stillView.layer.contents = st.surface
            stillView.layer.backgroundColor = nil; hueLayer.isHidden = true
        } else {
            stillView.layer.contents = nil
            stillView.layer.backgroundColor = GFSettings.cardColor(theme).cgColor
            hueLayer.backgroundColor = GFSettings.color(GFColor.flat(hue, theme)).cgColor; hueLayer.isHidden = false
        }
        CATransaction.commit()
    }
    override func prepareForReuse() { super.prepareForReuse(); item = -1 }
}

final class GFCardsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, GFCaseScreen {
    private let lib = GFLibrary.shared
    private let isMac = ProcessInfo.processInfo.isMacCatalystApp
    private var cv: UICollectionView!
    private let layoutF = UICollectionViewFlowLayout()
    private lazy var cache = GFCardStillCache(budgetMB: UserDefaults.standard.object(forKey: "CardsBudgetMB") != nil ? UserDefaults.standard.double(forKey: "CardsBudgetMB") : 40)
    private let hostLink = GFHostLink()
    private var settingsObs: NSObjectProtocol?
    private var liveItem = -1
    private var liveView: LiveSurfaceView?
    private var hoverPoint: CGPoint?            // in the window (content scrolls under a still pointer)
    private var programmatic: Timer?
    private var progPage = 0, progDir = 1
    private var progHover = false
    private var lastWantKey = ""
    private let checkJump = UserDefaults.standard.bool(forKey: "CheckJump")
    private(set) var jumpResults: [[String: Any]] = []

    // Geometry (pt)
    private var cardSize: CGSize {
        if isMac { return CGSize(width: 228, height: 320) }
        let w = (view.bounds.width * 0.79).rounded()
        return CGSize(width: w, height: (w * 1.53).rounded())
    }
    private var radius: CGFloat { isMac ? 14 : 30 }
    private var heroFrac: CGFloat { isMac ? 0.43 : 0.40 }
    private var scale: Double { Double(view.window?.traitCollection.displayScale ?? traitCollection.displayScale) }

    override func viewDidLoad() {
        super.viewDidLoad()
        layoutF.scrollDirection = isMac ? .vertical : .horizontal
        layoutF.minimumInteritemSpacing = 10; layoutF.minimumLineSpacing = isMac ? 10 : 14
        if isMac { layoutF.itemSize = CGSize(width: 228, height: 320) }   // round 2: never lay out at the default 50 × 50
        cv = UICollectionView(frame: view.bounds, collectionViewLayout: layoutF)
        cv.dataSource = self; cv.delegate = self
        cv.register(GFCardCell.self, forCellWithReuseIdentifier: "c")
        cv.accessibilityIdentifier = "cards.collection"
        cv.showsHorizontalScrollIndicator = false
        if !isMac { cv.decelerationRate = .fast }
        view.addSubview(cv)
        cache.onReady = { [weak self] i in self?.stillLanded(i) }
        if isMac {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            cv.addGestureRecognizer(hover)
        }
        settingsObs = NotificationCenter.default.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main) { [weak self] n in
            self?.settingsChanged(n.userInfo?["what"] as? String ?? "")
        }
    }
    deinit { settingsObs.map(NotificationCenter.default.removeObserver); hostLink.stop(); programmatic?.invalidate() }

    private var stillPxKey = ""
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let changed = cv.frame != view.bounds
        let cs = cardSize
        if layoutF.itemSize != cs || changed {   // round 2: the item size is set BEFORE the frame (whose scroll callback asks for stills)
            layoutF.itemSize = cs
            if isMac {
                let cols = max(1, floor((view.bounds.width - 48 + 10) / (cs.width + 10)))
                let side = (view.bounds.width - cols * cs.width - (cols - 1) * 10) / 2
                layoutF.sectionInset = UIEdgeInsets(top: max(24, view.safeAreaInsets.top + 12), left: side, bottom: 40, right: side)
            } else {
                let side = (view.bounds.width - cs.width) / 2
                layoutF.sectionInset = UIEdgeInsets(top: max(0, (view.bounds.height - cs.height) / 2 - 20), left: side, bottom: 0, right: side)
            }
            layoutF.invalidateLayout()
        }
        cv.frame = view.bounds
        sized = true
        // Round 2: stills are redrawn when the CARD's pixel size changes (design §1), not on every window size: on the Mac
        // the card is 228 × 320 whatever the window, so a resize (or the full-screen animation) keeps every still.
        let (pw, ph) = cardCase().pixelSize, key = "\(pw)x\(ph)"
        if key != stillPxKey { if !stillPxKey.isEmpty { cache.invalidate(); endLive(animated: false) }; stillPxKey = key; lastWantKey = "" }
        if changed { lastWantKey = "" }
        DispatchQueue.main.async { [weak self] in self?.refreshWanted(); self?.updateLive() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); applyTheme(); refreshWanted(); updateLive()
        // Headless checks (locked screen): -SimHoverItem N hovers card N after 2 s; -SimHoverOffAt S takes the pointer away.
        let d = UserDefaults.standard
        if let n = d.object(forKey: "SimHoverItem") as? String, let i = Int(n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let a = self.layoutF.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { return }
                self.hoverPoint = self.cv.convert(a.center, to: self.view); self.updateLive()
            }
        }
        let off = d.double(forKey: "SimHoverOffAt")
        if off > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + off) { [weak self] in self?.hoverPoint = nil; self?.updateLive() } }
    }

    private func applyTheme() {
        let t = GFSettings.shared.theme
        view.backgroundColor = GFSettings.pageColor(t); cv.backgroundColor = view.backgroundColor
    }

    private func settingsChanged(_ what: String) {
        switch what {
        case "liveRate": liveView?.liveRate = GFSettings.shared.liveRate
        case "live": updateLive()
        case "case", "detailFit", "mapCap", "sim", "detailZoom", "scrolledBand", "reveal", "revealDial", "overrides": break
        default:   // theme, glass, edgeBend, variant, hash, flat: every still is redrawn
            applyTheme(); endLive(animated: false)
            cache.invalidate(); lastWantKey = ""
            cv.visibleCells.forEach { c in if let c = c as? GFCardCell { configure(c, c.item) } }
            refreshWanted(); updateLive()
        }
    }

    // MARK: uniforms
    private func cardCase() -> GFCase {
        let cs = cardSize
        return GFCase.card(w: Double(cs.width), h: Double(cs.height), r: Double(radius), heroFrac: Double(heroFrac), scale: scale)
    }
    func uniforms(_ i: Int, time: Double) -> GFUniforms {
        var u = GFUniforms.make(cardCase(), lib.items[i].entry, GFSettings.shared.theme, time: time)
        GFSettings.shared.apply(&u)
        return u
    }

    // MARK: data source
    func collectionView(_ c: UICollectionView, numberOfItemsInSection s: Int) -> Int { lib.items.count }
    func collectionView(_ c: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = c.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! GFCardCell
        configure(cell, ip.item)
        return cell
    }
    private func configure(_ cell: GFCardCell, _ i: Int) {
        let t = GFSettings.shared.theme
        // A reused cell may still hold a live surface (or an outgoing one waiting for its still): it belongs to the old item.
        if let lv = cell.live, lv.superview === cell.contentView, !(liveView === lv && liveItem == i) {
            if liveView === lv { endLive(animated: false) } else { lv.removeFromSuperview() }
            cell.live = nil
        }
        cell.item = i
        if abs(cell.contentView.bounds.width - layoutF.itemSize.width) > 0.5 || abs(cell.contentView.bounds.height - layoutF.itemSize.height) > 0.5 {
            GFRecorder.shared.mark("r2 configure item \(i) at \(cell.contentView.bounds.size) (layout item \(layoutF.itemSize))")
        }
        cell.contentView.backgroundColor = GFSettings.pageColor(t)
        cell.layout(heroFrac: heroFrac, radius: radius)
        let it = lib.items[i]
        cell.title.text = it.title
        cell.sub.text = "\(it.items) item\(it.items == 1 ? "" : "s") · synthetic entry"
        let ink: UIColor = t == .light ? UIColor(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : UIColor(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255, alpha: 1)
        cell.title.textColor = ink; cell.sub.textColor = ink.withAlphaComponent(0.6)
        cell.show(cache.still(for: i), hue: it.entry.hue, theme: t)
        cell.accessibilityIdentifier = "card.\(i)"
        if let lv = liveView, liveItem == i, lv.superview !== cell.contentView {
            cell.contentView.insertSubview(lv, aboveSubview: cell.stillView); cell.live = lv; lv.frame = cell.contentView.bounds
        }
    }
    func collectionView(_ c: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if ip.item == liveItem, let lv = liveView, lv.superview === (cell as? GFCardCell)?.contentView { lv.reevaluate() }
    }
    private func stillLanded(_ i: Int) {
        guard let cell = cv.cellForItem(at: IndexPath(item: i, section: 0)) as? GFCardCell, cell.item == i else { return }
        cell.show(cache.still(for: i), hue: lib.items[i].entry.hue, theme: GFSettings.shared.theme)
    }

    // MARK: which stills to keep (visible first, then one screen each way)
    private var sized = false        // round 2: viewDidLayoutSubviews has set the real item size for these bounds
    private func refreshWanted() {
        guard cv.bounds.width > 0, sized else { return }
        let b = cv.bounds
        let ahead = isMac ? b.insetBy(dx: 0, dy: -b.height) : b.insetBy(dx: -b.width, dy: 0)
        let vis = Set((layoutF.layoutAttributesForElements(in: b) ?? []).map(\.indexPath.item))
        let key = "\(vis.min() ?? -1)-\(vis.max() ?? -1)"
        if key == lastWantKey { return }
        lastWantKey = key
        let c = CGPoint(x: b.midX, y: b.midY)
        let all = (layoutF.layoutAttributesForElements(in: ahead) ?? []).map { a -> (Int, CGFloat, Bool) in
            (a.indexPath.item, hypot(a.center.x - c.x, a.center.y - c.y), vis.contains(a.indexPath.item))
        }.sorted { ($0.2 ? 0 : 1, $0.1) < ($1.2 ? 0 : 1, $1.1) }
        let (pw, ph) = cardCase().pixelSize
        cache.currentMode = GFSettings.shared.mode
        cache.want(all.map(\.0), visible: vis, bytesEach: pw * ph * 4) { [weak self] i in
            self?.uniforms(i, time: GFLook.shared.stillTime) ?? GFUniforms()
        }
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        refreshWanted()
        guard s.isTracking || s.isDragging || s.isDecelerating || programmatic != nil else { return }
        hostLink.noteInput(); liveView?.noteInput()
        updateLive()
    }
    func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity v: CGPoint, targetContentOffset t: UnsafeMutablePointer<CGPoint>) {
        guard !isMac else { return }
        let page = cardSize.width + layoutF.minimumLineSpacing
        var idx = (t.pointee.x / page).rounded()
        let cur = (s.contentOffset.x / page).rounded()
        idx = min(max(idx, cur - 1), cur + 1)
        t.pointee.x = max(0, min(idx * page, s.contentSize.width - s.bounds.width))
    }
    func scrollViewDidEndDecelerating(_ s: UIScrollView) { updateLive() }

    // MARK: the one live card
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hoverPoint = g.location(in: view)
        default: hoverPoint = nil
        }
        updateLive()
    }
    /// The card that should be live now: the hovered one (Mac) or the centred one (iPhone); -1 = none.
    private func targetLiveItem() -> Int {
        guard GFSettings.shared.live else { return -1 }
        if isMac {
            guard let p = hoverPoint else { return -1 }
            return cv.indexPathForItem(at: view.convert(p, to: cv))?.item ?? -1
        }
        let c = CGPoint(x: cv.bounds.midX, y: cv.bounds.midY)
        return cv.indexPathForItem(at: c)?.item ?? (layoutF.layoutAttributesForElements(in: cv.bounds)?
            .min { abs($0.center.x - c.x) < abs($1.center.x - c.x) }?.indexPath.item ?? -1)
    }
    private func updateLive() {
        let want = targetLiveItem()
        guard want != liveItem else { liveView?.reevaluate(); return }
        endLive(animated: true)
        guard want >= 0, let cell = cv.cellForItem(at: IndexPath(item: want, section: 0)) as? GFCardCell else { return }
        let S = GFSettings.shared
        let st = cache.still(for: want)
        let t0 = st?.time ?? GFLook.shared.stillTime
        let lv = LiveSurfaceView(frame: cell.contentView.bounds)
        lv.surfaceName = isMac ? "hoverCard" : "centreCard"
        lv.mode = S.mode; lv.liveRate = S.liveRate
        lv.base = uniforms(want, time: t0)
        lv.stillTime = t0
        if checkJump, let st {
            lv.onFirstLiveFrame = { [weak self] u in self?.checkFirstFrame(item: want, u: u, still: st, mode: lv.mode) }
        }
        cell.contentView.insertSubview(lv, aboveSubview: cell.stillView); cell.live = lv
        liveView = lv; liveItem = want
        lv.isLive = true
        GFRecorder.shared.mark("live card \(want) from t=\(t0)")
    }
    /// Live ends: the surface stays on screen showing its last frame until the still redrawn at that time value lands.
    private func endLive(animated: Bool) {
        guard let lv = liveView else { liveItem = -1; return }
        let item = liveItem
        liveView = nil; liveItem = -1
        var ended = false
        lv.onLiveEnded = { [weak self, weak lv] t in
            guard let self, !ended else { return }; ended = true
            let u = self.uniforms(item, time: t)
            self.cache.redraw(item, u: u) { lv?.removeFromSuperview() }
        }
        lv.isLive = false
        if !ended {   // it never ran live (blocked, hidden): nothing to carry over
            lv.removeFromSuperview()
        }
        if !animated { lv.removeFromSuperview() }
    }

    /// Still ↔ live (design §1): draw the first live frame's uniforms offscreen with the live surface's own path and compare
    /// with the still's pixels (mean absolute difference, 8-bit steps).
    private func checkFirstFrame(item: Int, u: GFUniforms, still: GFCardStill, mode: GFDrawMode) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = GFJump.compare(u: u, mode: mode, still: still.tex)
            DispatchQueue.main.async {
                self?.jumpResults.append(["item": item, "mean": d.mean, "max": d.max, "stillTime": still.time, "liveT": Double(u.time)])
                GFRecorder.shared.mark(String(format: "jump card %d: first live frame vs still mean %.4f max %.0f (8-bit steps)", item, d.mean, d.max))
            }
        }
    }

    // MARK: programmatic motion: Mac scrolls the grid down / up (one screen every 1.5 s); iPhone swipes a card every 1.2 s.
    func setProgrammatic(_ on: Bool) {
        programmatic?.invalidate(); programmatic = nil
        guard on else {
            if progHover { progHover = false; hoverPoint = nil; updateLive() }   // the rest row: nothing hovered
            GFRecorder.shared.mark("programmatic end"); return
        }
        GFRecorder.shared.mark("programmatic start: cards \(isMac ? "scroll one screen / 1.5 s" : "swipe one card / 1.2 s")")
        if isMac, hoverPoint == nil { hoverPoint = CGPoint(x: view.bounds.midX, y: view.bounds.midY); progHover = true }   // a still pointer over the grid
        programmatic = Timer.scheduledTimer(withTimeInterval: isMac ? 1.5 : 1.2, repeats: true) { [weak self] _ in self?.progStep() }
        progStep()
    }
    private func progStep() {
        if isMac {
            let maxY = cv.contentSize.height - cv.bounds.height
            var y = cv.contentOffset.y + CGFloat(progDir) * cv.bounds.height * 0.8
            if y > maxY || y < 0 { progDir = -progDir; y = min(max(y, 0), maxY) }
            cv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else {
            let page = cardSize.width + layoutF.minimumLineSpacing
            progPage += progDir
            if progPage >= lib.items.count - 1 || progPage <= 0 { progDir = -progDir }
            cv.setContentOffset(CGPoint(x: CGFloat(progPage) * page, y: 0), animated: true)
        }
        hostLink.noteInput()
    }
    func scrollViewDidEndScrollingAnimation(_ s: UIScrollView) { updateLive() }

    /// Round 2 · -Script verbs: scroll:<dy pt> (animated, as a wheel scroll would), jump:<y pt> (no animation),
    /// hover:<item> / hover:off (a still pointer over that card, as -SimHoverItem).
    func scriptAction(_ verb: String, _ arg: String) -> Bool {
        switch verb {
        case "scroll", "jump":
            guard let v = Double(arg) else { return false }
            let maxY = max(0, cv.contentSize.height - cv.bounds.height)
            let y = verb == "scroll" ? cv.contentOffset.y + v : v
            cv.setContentOffset(CGPoint(x: 0, y: min(max(-cv.adjustedContentInset.top, y), maxY)), animated: verb == "scroll")
            return true
        case "hover":
            if arg == "off" { hoverPoint = nil } else if let i = Int(arg), let a = layoutF.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) {
                hoverPoint = cv.convert(a.center, to: view)
            }
            updateLive(); return true
        default: return false
        }
    }

    /// Round 2: what each visible cell actually shows (frames, contents, flat fill) and the cache's state.
    var diagnostics: [String: Any] {
        var m = recordingMeta
        m["cv"] = ["bounds": [cv.bounds.minX, cv.bounds.minY, cv.bounds.width, cv.bounds.height], "contentSize": [cv.contentSize.width, cv.contentSize.height]]
        m["layout"] = ["itemSize": [layoutF.itemSize.width, layoutF.itemSize.height], "estimated": [layoutF.estimatedItemSize.width, layoutF.estimatedItemSize.height],
                       "inset": [layoutF.sectionInset.left, layoutF.sectionInset.top]]
        let cells = cv.visibleCells.compactMap { $0 as? GFCardCell }.sorted { $0.item < $1.item }
        var rows: [[String: Any]] = []
        for c in cells {
            var r: [String: Any] = ["item": c.item]
            r["frame"] = [c.frame.minX, c.frame.minY, c.frame.width, c.frame.height]
            r["content"] = [c.contentView.bounds.width, c.contentView.bounds.height]
            r["still"] = [c.stillView.frame.width, c.stillView.frame.height]
            r["title"] = [c.title.frame.minX, c.title.frame.minY, c.title.frame.width]
            r["hasContents"] = c.stillView.layer.contents != nil
            r["flatFill"] = !c.hueLayer.isHidden
            let st = cache.still(for: c.item)
            r["cached"] = st != nil
            r["contentsIsCached"] = st != nil && (c.stillView.layer.contents as AnyObject?) === st!.surface
            rows.append(r)
        }
        m["cells"] = rows
        m["cachedItems"] = cache.stills.keys.sorted()
        m["inFlight"] = cache.inFlightCount
        let item = layoutF.itemSize
        func cnt(_ f: (GFCardCell) -> Bool) -> Int { cells.filter(f).count }
        var sm: [String: Int] = ["visible": cells.count]
        sm["wrongFrame"] = cnt { abs($0.frame.width - item.width) > 0.5 || abs($0.frame.height - item.height) > 0.5 }
        sm["stillViewNotFull"] = cnt { abs($0.stillView.frame.width - $0.contentView.bounds.width) > 0.5 || abs($0.stillView.frame.height - $0.contentView.bounds.height) > 0.5 }
        sm["flatFill"] = cnt { !$0.hueLayer.isHidden }
        sm["flatButCached"] = cnt { !$0.hueLayer.isHidden && self.cache.still(for: $0.item) != nil }
        sm["staleContents"] = cnt { $0.stillView.layer.contents != nil && ($0.stillView.layer.contents as AnyObject?) !== self.cache.still(for: $0.item)?.surface }
        m["summary"] = sm
        return m
    }

    var recordingMeta: [String: Any] {
        ["screen": "cards", "card": [cardSize.width, cardSize.height], "stillsKept": cache.stills.count, "stillBytes": cache.totalBytes,
         "budgetMB": Double(cache.budgetBytes) / 1_048_576, "budgetTruncated": cache.truncated, "stillsFilled": cache.filled,
         "visibleFillMs": cache.firstVisibleDoneAt.flatMap { a in cache.fillStart.map { (a - $0) * 1000 } } ?? -1,
         "liveItem": liveItem, "liveDrawn": liveView?.drawnFrames ?? 0, "liveScratchBytes": liveView?.scratchBytes ?? 0,
         "jump": jumpResults, "programmatic": programmatic != nil, "liveBlockedBy": GFSettings.shared.liveBlockedBy ?? ""]
    }
}

/// The still ↔ live check: the live surface's uniforms drawn by GFDraw offscreen, compared with a still's texture.
enum GFJump {
    static func compare(u: GFUniforms, mode: GFDrawMode, still: MTLTexture) -> (mean: Double, max: Double) {
        let R = GFRenderer.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: still.width, height: still.height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let t = R.device.makeTexture(descriptor: td)!
        var uu = u; uu.res = SIMD2(Float(still.width), Float(still.height))
        let cb = R.queue.makeCommandBuffer()!
        GFDraw.encode(cb, target: t, uu, mode, scratch: nil)
        cb.commit(); cb.waitUntilCompleted()
        let a = GFStillRenderer.readRGBA(t), b = GFStillRenderer.readRGBA(still)
        var sum = 0.0, mx = 0.0, n = 0
        for i in stride(from: 0, to: a.count, by: 4) { for k in 0..<3 { let d = abs(Double(a[i + k]) - Double(b[i + k])); sum += d; mx = max(mx, d); n += 1 } }
        return (sum / Double(max(n, 1)), mx)
    }
}
