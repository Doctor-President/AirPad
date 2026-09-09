#if DEBUG
import SwiftUI
import UIKit
import QuartzCore
import SpriteKit   // SKBlendMode for the orb blend control (addendum B)

// ws-ios-polish item 5 — the BLOB-BLEND tuner (THROWAWAY / DEBUG-ONLY, compiled out of Release).
//
// T's ask (2026-09-05): the blend picker belongs on the EXISTING blob animation — the DETAIL HERO
// and the CARDS (BlobField.metal), where that look ships — NOT the map orbs. This is a live switch
// over the full Photoshop/AE blend set, applied to the REAL `NodeGradientLayer` card + hero blobs,
// so T judges how the existing blobs COMPOSITE (additive vs screen vs …). It persists across
// relaunch and BlobFieldView reads it everywhere in DEBUG, so the real app surfaces honour it too.
// NOTE the internal disagreement this is settling: style 0 (lava) is ADDITIVE, styles 1/2
// (card/hero) are SOURCE-OVER, in one file — part of the question is whether they unify.
// Also carries the FAMILY palette mode (N blobs from one node-seeded family, spread-dialable),
// applied to the blob surfaces per the same brief. Reached via `-BLOBBLEND YES`.

/// Persisted, live blob-tuner state. `@Observable` so the REAL `BlobFieldView` / `NodeGradientLayer`
/// re-render the instant a value changes — with NO per-frame `UserDefaults` read (that trap is
/// [[swiftui-appstorage-perf]]); persistence happens once per edit in `didSet`.
// Not @MainActor: the nonisolated colour accessors (AppearancePalette.mapBackground /
// CardSurfaceResolved.ground) read `mapGroundHex`/`cardGroundHex`, and SwiftUI observation drives
// live re-render regardless of actor. All mutation is on the main thread (SwiftUI + the SKScene update).
@Observable final class BlobFieldTuning {
    static let shared = BlobFieldTuning()

    /// Full Photoshop/AE blend names — order MUST match `BlobField.metal` blendColor (0…12).
    /// † = tends to go black on a dark ground (Diff/Exclus make a dark core where colours cancel).
    static let blendNames = ["Normal", "Add", "Screen", "Lighten", "Darken†", "Multiply†",
                             "Overlay", "SoftLt", "HardLt", "Dodge", "Burn†", "Diff", "Exclus"]

    /// Whether the floating in-app tuner panel is showing (NOT persisted — session UI state).
    var isPresented = false

    /// Blob-compositing blend index, order matches `BlobField.metal`'s `blendColor` (0 = NORMAL /
    /// source-over = today's card/hero look → byte-identical).
    var blend: Int { didSet { UserDefaults.standard.set(blend, forKey: "blobTuner.blend") } }
    /// FAMILY palette: node-seeded variants of one base hue instead of the 3-colour tag palette.
    var family: Bool { didSet { UserDefaults.standard.set(family, forKey: "blobTuner.family") } }
    /// Family hue spread: 0 → near-monochrome family · 1 → wide (toward the unrelated look).
    var spread: Double { didSet { UserDefaults.standard.set(spread, forKey: "blobTuner.spread") } }

    // ── ORB controls (CorpusPhysicsScene) — off by default → baked look byte-identical until dialed.
    /// Master switch: when false the scene ignores every orb value below (uses the baked DarkOrbTuning
    /// / styleUnfocusedOrb / title values). The scene polls this in `update()` and restyles on change.
    var orbOverride: Bool { didSet { UserDefaults.standard.set(orbOverride, forKey: "blobTuner.orbOverride") } }
    var orbFillOpacity: Double { didSet { UserDefaults.standard.set(orbFillOpacity, forKey: "blobTuner.orbFillOpacity") } }
    var orbStrokeOpacity: Double { didSet { UserDefaults.standard.set(orbStrokeOpacity, forKey: "blobTuner.orbStrokeOpacity") } }
    var orbDarkSat: Double { didSet { UserDefaults.standard.set(orbDarkSat, forKey: "blobTuner.orbDarkSat") } }   // dark hue richness
    var orbDarkVal: Double { didSet { UserDefaults.standard.set(orbDarkVal, forKey: "blobTuner.orbDarkVal") } }
    var orbDarkRim: Double { didSet { UserDefaults.standard.set(orbDarkRim, forKey: "blobTuner.orbDarkRim") } }
    var orbTitleScale: Double { didSet { UserDefaults.standard.set(orbTitleScale, forKey: "blobTuner.orbTitleScale") } }
    var orbTitleOpacity: Double { didSet { UserDefaults.standard.set(orbTitleOpacity, forKey: "blobTuner.orbTitleOpacity") } }
    /// Orb title FONT (addendum A): 0 = baked (TypeTuning.fontChoice) · 1…N = MapLabelFont.allCases[i-1].
    var orbTitleFont: Int { didSet { UserDefaults.standard.set(orbTitleFont, forKey: "blobTuner.orbTitleFont") } }
    /// Orb title COLOUR override — empty = the auto-contrast `legibleInk`; hex = forced.
    var orbTitleColorHex: String { didSet { UserDefaults.standard.set(orbTitleColorHex, forKey: "blobTuner.orbTitleColorHex") } }
    /// Orb BLEND (addendum B) — how the orb SPRITE composites onto the ground, PER APPEARANCE. Index into
    /// the SpriteKit-native `SKBlendMode` set (0 = alpha/source-over = baked). NOT the 13-mode blob set:
    /// orbs are separate sprites and can't read the ground, so only SKBlendMode is available here.
    var orbBlendLight: Int { didSet { UserDefaults.standard.set(orbBlendLight, forKey: "blobTuner.orbBlendLight") } }
    var orbBlendDark: Int { didSet { UserDefaults.standard.set(orbBlendDark, forKey: "blobTuner.orbBlendDark") } }

    // ── GLOW beneath the orbs (addendum C) — a soft radial glow per orb, pooling onto the map
    // ground BELOW the orbs + titles (z-guaranteed). Off by default → no overlay → byte-identical.
    var glowOn: Bool { didSet { UserDefaults.standard.set(glowOn, forKey: "blobTuner.glowOn") } }
    var glowRadius: Double { didSet { UserDefaults.standard.set(glowRadius, forKey: "blobTuner.glowRadius") } }      // reach in orb radii (resting → not annulus-tied)
    /// PERSISTENT glow (T ruling): baseline intensity everywhere (>0 = the wash is always present, a
    /// PROPERTY of the field) + an in-band MULTIPLIER the annulus adds on top. Decoupled so the annulus
    /// curve and the glow can be tuned independently.
    var glowBaseline: Double { didSet { UserDefaults.standard.set(glowBaseline, forKey: "blobTuner.glowBaseline") } }
    var glowInBand: Double { didSet { UserDefaults.standard.set(glowInBand, forKey: "blobTuner.glowInBand") } }
    var glowFalloff: Double { didSet { UserDefaults.standard.set(glowFalloff, forKey: "blobTuner.glowFalloff") } }   // e-fold softness
    /// Glow POOL blend per appearance (full 13-set — how overlapping glows combine WITH EACH OTHER;
    /// single-pass shader so it can do all 13).
    var glowBlendLight: Int { didSet { UserDefaults.standard.set(glowBlendLight, forKey: "blobTuner.glowBlendLight") } }
    var glowBlendDark: Int { didSet { UserDefaults.standard.set(glowBlendDark, forKey: "blobTuner.glowBlendDark") } }
    /// Glow GROUND blend per appearance — how the glow LAYER composites onto the map ground (the
    /// SKBlendMode 7-set). ★ THIS is the "muddy on light" lever: over cream, source-over washes out;
    /// multiply/darken deepen the paper toward the glow colour. (An orb-overlay→ground composite can
    /// only be an SKBlendMode — SpriteKit can't read the framebuffer for the full 13 there.)
    var glowGroundLight: Int { didSet { UserDefaults.standard.set(glowGroundLight, forKey: "blobTuner.glowGroundLight") } }
    var glowGroundDark: Int { didSet { UserDefaults.standard.set(glowGroundDark, forKey: "blobTuner.glowGroundDark") } }

    /// Orb separation gap (item 2) — the band-relaxation `breathingGap`, dialable so amplified orbs
    /// push further apart (they overlap because bodies are STATIC — no physics collision — and the PBD
    /// gap was fixed). Default 30 = baked. (Body-radius sync is a non-fix: the bodies don't collide.)
    var orbGap: Double { didSet { UserDefaults.standard.set(orbGap, forKey: "blobTuner.orbGap") } }

    /// Region-label separation (item 3): labels get a repel-from-orbs + tether-to-centroid solver so they
    /// settle in gaps. Off = today's raw centroid. Tether strength dial: low = escapes to gaps, high =
    /// hugs the region.
    var labelSepOn: Bool { didSet { UserDefaults.standard.set(labelSepOn, forKey: "blobTuner.labelSepOn") } }
    var labelTether: Double { didSet { UserDefaults.standard.set(labelTether, forKey: "blobTuner.labelTether") } }

    // ── PER-EXPRESSION blob params (addendum D) — 4 surfaces × {spread, anim, distort, blur}, each
    // INDEPENDENT. The card trio (vscroll/carousel/canvas) currently SHARE one set; this adds the axis.
    // Order = BlobExpr indices: 0 vscroll · 1 carousel · 2 grid · 3 hero. Off → each call site's baked values.
    var blobExprOverride: Bool { didSet { UserDefaults.standard.set(blobExprOverride, forKey: "blobTuner.blobExprOverride") } }
    var blobExprSel: Int { didSet { UserDefaults.standard.set(blobExprSel, forKey: "blobTuner.blobExprSel") } }   // which surface the panel edits
    var blobSpread: [Double] { didSet { UserDefaults.standard.set(blobSpread, forKey: "blobTuner.blobSpread") } }   // positional (offsetScale)
    var blobAnim: [Double] { didSet { UserDefaults.standard.set(blobAnim, forKey: "blobTuner.blobAnim") } }         // drift/churn (driftSpeedScale)
    var blobDistort: [Double] { didSet { UserDefaults.standard.set(blobDistort, forKey: "blobTuner.blobDistort") } } // undulation
    var blobBlur: [Double] { didSet { UserDefaults.standard.set(blobBlur, forKey: "blobTuner.blobBlur") } }         // blurScale

    static let exprNames = ["V-scroll", "Carousel", "Grid", "Hero"]

    // ── BACKGROUND per view (item 2) — currently ONE token (mapBackground / CardSurfaceResolved.ground).
    // Empty = follow the shared token. Non-empty = override THIS view's ground, so T can preview map and
    // card grounds DIVERGING before ruling on whether to split the token. (Show-don't-enforce.)
    var mapGroundHex: String { didSet { UserDefaults.standard.set(mapGroundHex, forKey: "blobTuner.mapGroundHex") } }
    var cardGroundHex: String { didSet { UserDefaults.standard.set(cardGroundHex, forKey: "blobTuner.cardGroundHex") } }

    // ── REGION PALETTE FAMILIES (commit 2) — the map territory tints. 0 = Current (shipping hex,
    // byte-identical A/B baseline) · 1 Subdued · 2 Jewel · 3 Pastel · 4 Neon (see RegionPaletteFamily).
    // The scene re-tints orbs live off `regionFamily`; families 1…4 regenerate 12 slots from HSL params.
    var regionFamily: Int { didSet { UserDefaults.standard.set(regionFamily, forKey: "blobTuner.regionFamily") } }
    /// Per (family, appearance) dialled params + per-slot hue nudges, keyed "<fam>.<L|D>.<key>".
    /// family-level keys: hueStart/hueSpread/sat/light · per-slot: "s<slot>h" (hue offset). Empty = defaults.
    var regionParams: [String: Double] { didSet { UserDefaults.standard.set(regionParams, forKey: "blobTuner.regionParams") } }
    /// Which appearance's params the panel EDITS (the panel chrome is forced-dark, so it can't infer
    /// the map's appearance). The scene always resolves with its OWN `currentIsLight`; this only
    /// selects which set of numbers the sliders write. Default dark (where mud matters most).
    var regionEditLight: Bool { didSet { UserDefaults.standard.set(regionEditLight, forKey: "blobTuner.regionEditLight") } }

    private func regionKey(_ fam: Int, _ isLight: Bool, _ k: String) -> String { "\(fam).\(isLight ? "L" : "D").\(k)" }
    func regionParam(_ fam: Int, _ isLight: Bool, _ k: String, default d: Double) -> Double { regionParams[regionKey(fam, isLight, k)] ?? d }
    func setRegionParam(_ fam: Int, _ isLight: Bool, _ k: String, _ v: Double) { regionParams[regionKey(fam, isLight, k)] = v }
    func regionSlotHueOffset(_ fam: Int, _ isLight: Bool, _ slot: Int) -> Double { regionParams[regionKey(fam, isLight, "s\(slot)h")] ?? 0 }
    func setRegionSlotHue(_ fam: Int, _ isLight: Bool, _ slot: Int, _ v: Double) { regionParams[regionKey(fam, isLight, "s\(slot)h")] = v }
    func resetRegion(_ fam: Int, _ isLight: Bool) {
        let keys = ["hueStart", "hueSpread", "sat", "light"] + (0..<12).map { "s\($0)h" }
        for k in keys { regionParams[regionKey(fam, isLight, k)] = nil }
    }
    /// Poll signature — any family/param change re-tints the orbs (via the scene's refreshOrbTuning).
    var regionSig: String { "\(regionFamily)|" + regionParams.keys.sorted().map { "\($0):\(regionParams[$0]!)" }.joined(separator: ",") }

    private init() {
        blend = UserDefaults.standard.integer(forKey: "blobTuner.blend")   // default 0 = NORMAL
        // Default FAMILY ON — the blend comparison is only meaningful within a colour family
        // (across unrelated tag colours, screen/add just wash to white). Tag palette is the A/B.
        family = (UserDefaults.standard.object(forKey: "blobTuner.family") as? Bool) ?? true
        // `double(forKey:)` also parses a launch-arg string ("-blobTuner.spread 0.9") for screenshots.
        spread = UserDefaults.standard.object(forKey: "blobTuner.spread") != nil
            ? UserDefaults.standard.double(forKey: "blobTuner.spread") : 0.5
        func dbl(_ k: String, _ d: Double) -> Double {
            UserDefaults.standard.object(forKey: k) != nil ? UserDefaults.standard.double(forKey: k) : d
        }
        orbOverride     = UserDefaults.standard.bool(forKey: "blobTuner.orbOverride")   // default false = baked
        orbFillOpacity  = dbl("blobTuner.orbFillOpacity", 1.0)
        orbStrokeOpacity = dbl("blobTuner.orbStrokeOpacity", 1.0)
        orbDarkSat      = dbl("blobTuner.orbDarkSat", 2.00)   // DarkOrbTuning baked defaults
        orbDarkVal      = dbl("blobTuner.orbDarkVal", 1.25)
        orbDarkRim      = dbl("blobTuner.orbDarkRim", 0.20)
        orbTitleScale   = dbl("blobTuner.orbTitleScale", 1.0)
        orbTitleOpacity = dbl("blobTuner.orbTitleOpacity", 1.0)
        orbTitleFont    = UserDefaults.standard.integer(forKey: "blobTuner.orbTitleFont")   // 0 = baked
        orbTitleColorHex = UserDefaults.standard.string(forKey: "blobTuner.orbTitleColorHex") ?? ""
        orbBlendLight   = UserDefaults.standard.integer(forKey: "blobTuner.orbBlendLight")   // 0 = alpha
        orbBlendDark    = UserDefaults.standard.integer(forKey: "blobTuner.orbBlendDark")
        mapGroundHex    = UserDefaults.standard.string(forKey: "blobTuner.mapGroundHex") ?? ""
        cardGroundHex   = UserDefaults.standard.string(forKey: "blobTuner.cardGroundHex") ?? ""
        glowOn          = UserDefaults.standard.bool(forKey: "blobTuner.glowOn")          // default off
        glowRadius      = dbl("blobTuner.glowRadius", 3.0)
        glowBaseline    = dbl("blobTuner.glowBaseline", 0.35)   // persistent floor
        glowInBand      = dbl("blobTuner.glowInBand", 1.0)      // annulus adds this on top
        glowFalloff     = dbl("blobTuner.glowFalloff", 0.6)
        glowBlendLight  = UserDefaults.standard.object(forKey: "blobTuner.glowBlendLight") != nil ? UserDefaults.standard.integer(forKey: "blobTuner.glowBlendLight") : 2  // Screen
        glowBlendDark   = UserDefaults.standard.object(forKey: "blobTuner.glowBlendDark") != nil ? UserDefaults.standard.integer(forKey: "blobTuner.glowBlendDark") : 2
        glowGroundLight = UserDefaults.standard.object(forKey: "blobTuner.glowGroundLight") != nil ? UserDefaults.standard.integer(forKey: "blobTuner.glowGroundLight") : 3  // default MULTIPLY (item 2): on near-white cream, source-over/Add have no headroom to add light → a muddy wash. Multiply DEEPENS the cream toward the glow hue = colour reads as a tint. (Coloured LIGHT pooling only reads on a dark ground.)
        glowGroundDark  = UserDefaults.standard.integer(forKey: "blobTuner.glowGroundDark")
        orbGap          = dbl("blobTuner.orbGap", 30.0)
        labelSepOn      = UserDefaults.standard.bool(forKey: "blobTuner.labelSepOn")
        labelTether     = dbl("blobTuner.labelTether", 0.5)
        blobExprOverride = UserDefaults.standard.bool(forKey: "blobTuner.blobExprOverride")
        blobExprSel     = UserDefaults.standard.integer(forKey: "blobTuner.blobExprSel")
        blobSpread      = (UserDefaults.standard.array(forKey: "blobTuner.blobSpread") as? [Double]) ?? [1, 1, 1, 1]
        blobAnim        = (UserDefaults.standard.array(forKey: "blobTuner.blobAnim") as? [Double]) ?? [1, 1, 1, 1]
        blobDistort     = (UserDefaults.standard.array(forKey: "blobTuner.blobDistort") as? [Double]) ?? [0, 0, 0, 0]
        blobBlur        = (UserDefaults.standard.array(forKey: "blobTuner.blobBlur") as? [Double]) ?? [1, 1, 1, 1]
        regionFamily    = UserDefaults.standard.integer(forKey: "blobTuner.regionFamily")   // 0 = Current
        regionParams    = (UserDefaults.standard.dictionary(forKey: "blobTuner.regionParams") as? [String: Double]) ?? [:]
        regionEditLight = UserDefaults.standard.bool(forKey: "blobTuner.regionEditLight")   // default dark
    }

    /// Orb-title CURATED FONT SET — baked MSDF atlases (Resources/MSDF/*.{png,json}). Index → name +
    /// atlas file (parallel arrays); the scene loads the atlas via `MSDFFont.named`. 0 = Fraunces (ships).
    // Curated set (6) + BOLDER cuts (item 4): each face's heaviest weight the family offers —
    // Black (900) for Fraunces/Source Serif/Lato/Playfair; Bold (700, family max) for Space
    // Grotesk. Lora is OMITTED from the bold set: its family tops out at Bold (700), which the
    // base "Lora" atlas already is — no meaningfully-bolder cut exists. Appended (not inserted)
    // so a saved `orbTitleFont` index never shifts.
    static let orbFontNames   = ["Fraunces", "Source Serif", "Lora", "Lato", "Playfair", "Space Grotesk",
                                 "Fraunces Black", "Source Serif Black", "Lato Black", "Playfair Black", "Space Grotesk Bold"]
    static let orbFontAtlases = ["fraunces_msdf", "sourceserif_msdf", "lora_msdf", "lato_msdf", "playfair_msdf", "spacegrotesk_msdf",
                                 "frauncesblack_msdf", "sourceserifblack_msdf", "latoblack_msdf", "playfairblack_msdf", "spacegroteskbold_msdf"]
    /// Set by the scene when a chosen atlas fails to load → shown in the panel (VISIBLE, not the silent
    /// SourceSerif4 fallback that reads as "the picker did nothing"). Empty = all good.
    var fontLoadWarning = ""
    /// SKBlendMode set for the orb sprite (index 0 = alpha = baked source-over).
    static let orbBlendNames = ["Alpha", "Add", "Screen", "Multiply", "Mult×2", "Subtract", "Replace"]
    static func skBlend(_ i: Int) -> SKBlendMode {
        switch i {
        case 1: return .add; case 2: return .screen; case 3: return .multiply
        case 4: return .multiplyX2; case 5: return .subtract; case 6: return .replace
        default: return .alpha
        }
    }
}

/// Display-refresh canary — pinned at the ceiling across all modes = no per-mode regression. (These
/// blob surfaces animate at 30fps by design; the blend is a few ALU ops on a small fragment area,
/// so any drop below the ceiling would be the signal.)
@MainActor final class BlobFPSMeter: ObservableObject {
    @Published var fps: Double = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ l: CADisplayLink) {
        frames += 1
        if last == 0 { last = l.timestamp; return }
        let dt = l.timestamp - last
        if dt >= 0.5 { fps = Double(frames) / dt; frames = 0; last = l.timestamp }
    }
}

/// `-BLOBBLEND YES` host — the REAL card + detail-hero blob surfaces for one node, side by side, so
/// the SAME colours can be judged under each blend mode on BOTH surfaces at once. Dark ground (where
/// they ship). All controls mutate the persisted singleton live.
struct BlobBlendCompareView: View {
    @Bindable private var tuning = BlobFieldTuning.shared
    @StateObject private var meter = BlobFPSMeter()

    private let blendNames = BlobFieldTuning.blendNames

    private var node: Node {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        return Node(id: "blobtune", createdAt: t, updatedAt: t,
                    title: "Blob Blend", summary: "", tags: ["design"])
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppearancePalette.mapBackground(dark: true).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("DETAIL HERO — \(blendNames[safe: tuning.blend] ?? "?") · \(tuning.family ? "family s\(String(format: "%.1f", tuning.spread))" : "tag palette")")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                NodeGradientLayer(node: node, circleScale: 1.3, blobSet: .hero)
                    .frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 20))
                Text("CARD").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                NodeGradientLayer(node: node)
                    .frame(width: 260, height: 170).clipShape(RoundedRectangle(cornerRadius: 22))
                Spacer()
            }
            .padding(.top, 60).padding(.horizontal, 16)
            controls
        }
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            HStack {
                Text(String(format: "%.0f fps", meter.fps))
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundStyle(meter.fps >= 55 ? .green : (meter.fps >= 28 ? .yellow : .red))
                Spacer()
                Text("lava(dashboard) stays ADDITIVE — the disagreement")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(0..<blendNames.count, id: \.self) { i in
                    Button { tuning.blend = i } label: {
                        Text(blendNames[i])
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(tuning.blend == i ? Color.white : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(tuning.blend == i ? .black
                                             : .white.opacity(blendNames[i].hasSuffix("†") ? 0.45 : 0.9))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Hue spread").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white).frame(width: 78, alignment: .leading)
                Slider(value: $tuning.spread, in: 0...1)
                Text(String(format: "%.1f", tuning.spread))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).frame(width: 28)
            }
            HStack(spacing: 8) {
                Button(tuning.family ? "Family" : "Tag palette") { tuning.family.toggle() }
                    .buttonStyle(.borderedProminent).tint(tuning.family ? .green : .gray)
                Spacer()
                Button("Copy") { copyValues() }.buttonStyle(.borderedProminent)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(11)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func copyValues() {
        let s = """
        ws-ios-polish item 5 — blob blend tuner
        blend = \(tuning.blend) (\(blendNames[safe: tuning.blend] ?? "?"))
        family = \(tuning.family)  spread = \(String(format: "%.2f", tuning.spread))
        fps = \(String(format: "%.0f", meter.fps)) (display canary; blob redraw is 30fps by design)
        note: applies to card + hero (source-over→blend); lava/dashboard stays additive.
        """
        UIPasteboard.general.string = s
    }
}

/// Floating IN-APP tuner — the SAME idiom as the palette tuner (`.paletteTunerHost()`): a trigger
/// button over the live app + a bottom panel. Because the real `BlobFieldView` / `NodeGradientLayer`
/// read `BlobFieldTuning.shared` in DEBUG, changing the blend / hue-spread / family here re-renders
/// EVERY visible blob (every card in the catalogue, every detail hero, tiles) LIVE with no relaunch —
/// so T judges COHESION ACROSS THE REAL CORPUS, not a two-blob preview. DEBUG-only, gated on the same
/// `InternalBuild.showsDevTuners`; the whole file is `#if DEBUG` so Release carries none of it.
extension View {
    func blobTunerHost() -> some View { modifier(BlobTunerHost()) }
}

struct BlobTunerHost: ViewModifier {
    @State private var tuning = BlobFieldTuning.shared
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if InternalBuild.showsDevTuners && !tuning.isPresented {
                    Button { tuning.isPresented = true } label: {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(9).background(.black.opacity(0.55)).clipShape(Circle())
                    }
                    .padding(.top, 52).padding(.trailing, 10)   // sits below the palette-tuner button
                }
            }
            .overlay(alignment: .bottom) {
                if tuning.isPresented { BlobTunerPanel(tuning: tuning) }
            }
    }
}

/// The in-app blob tuner controls. Compact bottom panel (leaves the catalogue visible above). The fps
/// readout is a CADisplayLink canary: on device under real catalogue load a heavy blend that the GPU
/// can't sustain stalls the compositor → the number drops. That drop is the shippability signal.
struct BlobTunerPanel: View {
    @Bindable var tuning: BlobFieldTuning
    @StateObject private var meter = BlobFPSMeter()
    @State private var showRegionSlots = false

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    blendSection
                    paletteSection
                    exprSection
                    orbSection
                    regionSection
                    glowSection
                    separationSection
                    backgroundSection
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.46)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .padding(8)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(format: "%.0f fps", meter.fps))
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundStyle(meter.fps >= 55 ? .green : (meter.fps >= 28 ? .yellow : .red))
            Text("real app · live").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button("Copy") { copyAll() }.buttonStyle(.bordered).controlSize(.small)
            Button { tuning.isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
    }

    private var blendSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("BLOB BLEND — card + hero (lava/dashboard stays additive)")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(0..<BlobFieldTuning.blendNames.count, id: \.self) { i in
                    Button { tuning.blend = i } label: {
                        Text(BlobFieldTuning.blendNames[i])
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(tuning.blend == i ? Color.white : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(tuning.blend == i ? .black
                                             : .white.opacity(BlobFieldTuning.blendNames[i].hasSuffix("†") ? 0.45 : 0.9))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BLOB PALETTE")
            slider("Hue spread", $tuning.spread, 0...1)
            Button(tuning.family ? "Family (derived)" : "Tag palette") { tuning.family.toggle() }
                .buttonStyle(.borderedProminent).tint(tuning.family ? .green : .gray)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }

    private var orbSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("ORBS — map")
                Spacer()
                Toggle("", isOn: $tuning.orbOverride).labelsHidden().scaleEffect(0.85)
            }
            if tuning.orbOverride {
                slider("Fill opacity", $tuning.orbFillOpacity, 0...1)
                slider("Stroke opac", $tuning.orbStrokeOpacity, 0...1)
                slider("Dark sat", $tuning.orbDarkSat, 0...3)
                slider("Dark val", $tuning.orbDarkVal, 0.5...2)
                slider("Dark rim", $tuning.orbDarkRim, 0...1)
                slider("Title size", $tuning.orbTitleScale, 0.5...2)
                slider("Title opac", $tuning.orbTitleOpacity, 0...1)
                menuPick("Title font", $tuning.orbTitleFont, BlobFieldTuning.orbFontNames)   // curated MSDF atlases
                hexRow("Title colour", $tuning.orbTitleColorHex)     // empty = auto-contrast
                menuPick("Blend · light", $tuning.orbBlendLight, BlobFieldTuning.orbBlendNames)
                menuPick("Blend · dark", $tuning.orbBlendDark, BlobFieldTuning.orbBlendNames)
                if !tuning.fontLoadWarning.isEmpty {
                    Text(tuning.fontLoadWarning).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                }
                Text("Fill opacity 1.0 = SOLID (blocks the dot grid) — tune down from there. Title font = 6 baked MSDF atlases; a switch rebuilds on-screen orb glyphs. Orb→ground blend is the SpriteKit set (7), per appearance.")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text("off → baked orb look (byte-identical)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func regionBind(_ key: String, _ def: Double) -> Binding<Double> {
        Binding(get: { tuning.regionParam(tuning.regionFamily, tuning.regionEditLight, key, default: def) },
                set: { tuning.setRegionParam(tuning.regionFamily, tuning.regionEditLight, key, $0) })
    }
    private func regionSlotBind(_ slot: Int) -> Binding<Double> {
        Binding(get: { tuning.regionSlotHueOffset(tuning.regionFamily, tuning.regionEditLight, slot) },
                set: { tuning.setRegionSlotHue(tuning.regionFamily, tuning.regionEditLight, slot, $0) })
    }

    private var regionSection: some View {
        let fam = RegionPaletteFamily(rawValue: tuning.regionFamily) ?? .current
        let isLight = tuning.regionEditLight
        let def = RegionPalette.defaults(fam, isLight: isLight)
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("REGION PALETTE — map territory tints (families)")
            menuPick("Family", $tuning.regionFamily, RegionPaletteFamily.allCases.map { $0.displayName })
            if fam == .current {
                Text("Current = shipping Paul Tol set, byte-identical. Pick a family to move the region hues OUT of the muddy mid-lightness zone. Subdued (desaturate) is the direct opposite of muddy — try it first.")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            } else {
                Picker("", selection: $tuning.regionEditLight) {
                    Text("Editing: Dark").tag(false); Text("Editing: Light").tag(true)
                }.pickerStyle(.segmented)
                slider("Saturation", regionBind("sat", def.sat), 0...1)
                slider("Lightness", regionBind("light", def.light), 0...1)
                slider("Hue rotate", regionBind("hueStart", def.hueStart), 0...1)
                slider("Hue spread", regionBind("hueSpread", def.hueSpread), 0.1...1)
                let distinct = RegionPalette.distinctSlotCount(fam, isLight: isLight)
                Text("Distinguishable: \(distinct)/12 slots  (ΔE≥12, normal-vision)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(distinct >= 12 ? .green : (distinct >= 9 ? .yellow : .red))
                HStack(spacing: 2) {
                    ForEach(0..<RegionPalette.slotCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(RegionPalette.color(isLight: isLight, slot: i)))
                            .frame(height: 16)
                    }
                }
                Toggle("Per-slot hue nudge", isOn: $showRegionSlots)
                    .font(.system(size: 10, design: .monospaced))
                if showRegionSlots {
                    ForEach(0..<RegionPalette.slotCount, id: \.self) { i in
                        slider("Slot \(i) hue", regionSlotBind(i), -0.08...0.08)
                    }
                }
                if fam.darkFavoured {
                    Text("\(fam.displayName) is DARK-FAVOURED — high-lightness colour needs a dark ground; on light it's pushed darker/more saturated (best it can do), never silently washed out.")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.orange.opacity(0.85))
                }
                Button("Reset \(fam.displayName)/\(isLight ? "light" : "dark")") { tuning.resetRegion(tuning.regionFamily, isLight) }
                    .buttonStyle(.bordered).controlSize(.mini)
                Text("Live on the map orbs. Family + S/L/spread + per-slot hue persist per appearance; Copy exports the 12 resolved hex.")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BACKGROUND per view — shared token, preview a split")
            hexRow("Map ground", $tuning.mapGroundHex)
            hexRow("Card ground", $tuning.cardGroundHex)
            Text("empty = follow the shared token. Set only card → the map follows it (the coupling). Set both → they diverge. Set Map ground to a solid hex to kill the dot grid showing through.")
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var glowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("GLOW — beneath orbs, pools on ground (addendum C)")
                Spacer()
                Toggle("", isOn: $tuning.glowOn).labelsHidden().scaleEffect(0.85)
            }
            if tuning.glowOn {
                slider("Radius", $tuning.glowRadius, 0.5...8)
                slider("Baseline", $tuning.glowBaseline, 0...1.5)      // persistent floor (>0 = always present)
                slider("In-band ×", $tuning.glowInBand, 0...2)         // annulus adds this on top
                slider("Falloff", $tuning.glowFalloff, 0...1)
                menuPick("Pool · light", $tuning.glowBlendLight, BlobFieldTuning.blendNames)     // 13-set (glow↔glow)
                menuPick("Pool · dark", $tuning.glowBlendDark, BlobFieldTuning.blendNames)
                menuPick("Ground · light", $tuning.glowGroundLight, BlobFieldTuning.orbBlendNames)  // SKBlendMode → the muddy-on-cream fix
                menuPick("Ground · dark", $tuning.glowGroundDark, BlobFieldTuning.orbBlendNames)
                Text("PERSISTENT: baseline + annulus adds in-band. POOL = how glows combine (13). GROUND = how the glow sits on the map ground (7) — ★ set light to Multiply/Darken to fix muddy-over-cream. Always beneath orbs + titles.")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text("off → no glow layer").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var separationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SEPARATION — orb gap + region labels")
            slider("Orb gap", $tuning.orbGap, 0...120)   // item 2: amplified orbs overlap; push apart
            HStack {
                Text("Label sep").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white).frame(width: 88, alignment: .leading)
                Toggle("", isOn: $tuning.labelSepOn).labelsHidden().scaleEffect(0.85)
                Spacer()
            }
            if tuning.labelSepOn { slider("Tether", $tuning.labelTether, 0...2) }
            Text("Orb gap: bodies are STATIC (no collision) → this PBD gap is the only separation. Labels: repel from orbs + tether to centroid; low tether = escapes to a gap, high = hugs the region.")
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var exprSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("BLOB · PER-EXPRESSION (addendum D)")
                Spacer()
                Toggle("", isOn: $tuning.blobExprOverride).labelsHidden().scaleEffect(0.85)
            }
            if tuning.blobExprOverride {
                Picker("", selection: $tuning.blobExprSel) {
                    ForEach(0..<BlobFieldTuning.exprNames.count, id: \.self) { Text(BlobFieldTuning.exprNames[$0]).tag($0) }
                }.pickerStyle(.segmented)
                let i = min(max(tuning.blobExprSel, 0), 3)
                slider("Spread", arrayBind(\.blobSpread, i), 0...3)
                slider("Animation", arrayBind(\.blobAnim, i), 0...3)
                slider("Distort", arrayBind(\.blobDistort, i), 0...1.5)
                slider("Blur", arrayBind(\.blobBlur, i), 0.1...3)
                Text("each surface INDEPENDENT (vscroll+carousel currently share one baked set — this splits them). values export per-surface via Copy.")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text("off → each surface's baked values").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// Binding into one element of a per-expression `[Double]` array on the tuner.
    private func arrayBind(_ kp: ReferenceWritableKeyPath<BlobFieldTuning, [Double]>, _ i: Int) -> Binding<Double> {
        Binding(get: { tuning[keyPath: kp][i] },
                set: { var a = tuning[keyPath: kp]; a[i] = $0; tuning[keyPath: kp] = a })
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).frame(width: 88, alignment: .leading)
            Slider(value: v, in: range)
            Text(String(format: "%.2f", v.wrappedValue))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).frame(width: 36)
        }
    }

    private func hexRow(_ label: String, _ hex: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).frame(width: 88, alignment: .leading)
            TextField("hex / empty", text: hex)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            if !hex.wrappedValue.isEmpty {
                Button { hex.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func menuPick(_ label: String, _ sel: Binding<Int>, _ names: [String]) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).frame(width: 88, alignment: .leading)
            Menu {
                ForEach(0..<names.count, id: \.self) { i in Button(names[i]) { sel.wrappedValue = i } }
            } label: {
                HStack(spacing: 4) {
                    Text(names[safe: sel.wrappedValue] ?? "?")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func copyAll() {
        func f(_ d: Double) -> String { String(format: "%.2f", d) }
        func exprRow(_ i: Int) -> String {
            "  \(BlobFieldTuning.exprNames[i]): spread=\(f(tuning.blobSpread[i])) anim=\(f(tuning.blobAnim[i])) distort=\(f(tuning.blobDistort[i])) blur=\(f(tuning.blobBlur[i]))"
        }
        UIPasteboard.general.string = """
        blob: blend=\(BlobFieldTuning.blendNames[safe: tuning.blend] ?? "?") hueSpread=\(f(tuning.spread)) family=\(tuning.family)
        orb(override=\(tuning.orbOverride)): fillOpacity=\(f(tuning.orbFillOpacity)) strokeOpacity=\(f(tuning.orbStrokeOpacity)) darkSat=\(f(tuning.orbDarkSat)) darkVal=\(f(tuning.orbDarkVal)) darkRim=\(f(tuning.orbDarkRim)) titleSize=\(f(tuning.orbTitleScale)) titleOpacity=\(f(tuning.orbTitleOpacity)) titleFont=\(BlobFieldTuning.orbFontNames[safe: tuning.orbTitleFont] ?? "?") titleColour=\(tuning.orbTitleColorHex.isEmpty ? "(auto)" : tuning.orbTitleColorHex) blendLight=\(BlobFieldTuning.orbBlendNames[safe: tuning.orbBlendLight] ?? "?") blendDark=\(BlobFieldTuning.orbBlendNames[safe: tuning.orbBlendDark] ?? "?")
        glow(on=\(tuning.glowOn)): radius=\(f(tuning.glowRadius)) baseline=\(f(tuning.glowBaseline)) inBand=\(f(tuning.glowInBand)) falloff=\(f(tuning.glowFalloff)) poolL=\(BlobFieldTuning.blendNames[safe: tuning.glowBlendLight] ?? "?") poolD=\(BlobFieldTuning.blendNames[safe: tuning.glowBlendDark] ?? "?") groundL=\(BlobFieldTuning.orbBlendNames[safe: tuning.glowGroundLight] ?? "?") groundD=\(BlobFieldTuning.orbBlendNames[safe: tuning.glowGroundDark] ?? "?")
        separation: orbGap=\(f(tuning.orbGap)) labelSep=\(tuning.labelSepOn) labelTether=\(f(tuning.labelTether))
        per-expression blobs (override=\(tuning.blobExprOverride)):
        \(exprRow(0))
        \(exprRow(1))
        \(exprRow(2))
        \(exprRow(3))
        bg: mapGround=\(tuning.mapGroundHex.isEmpty ? "(token)" : tuning.mapGroundHex) cardGround=\(tuning.cardGroundHex.isEmpty ? "(token)" : tuning.cardGroundHex)
        region: family=\((RegionPaletteFamily(rawValue: tuning.regionFamily) ?? .current).displayName) editing=\(tuning.regionEditLight ? "light" : "dark") distinct=\(RegionPalette.distinctSlotCount(RegionPaletteFamily(rawValue: tuning.regionFamily) ?? .current, isLight: tuning.regionEditLight))/12
          hex[\(tuning.regionEditLight ? "light" : "dark")]=\(RegionPalette.resolvedHex(isLight: tuning.regionEditLight).joined(separator: " "))
        fps=\(f(meter.fps))
        """
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
