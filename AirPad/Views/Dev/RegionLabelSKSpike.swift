#if DEBUG
import SpriteKit
import UIKit

// ── SPIKE: NATIVE-SPRITEKIT REGION LABELS (ws-ios-polish, 2026-09-12) — THROWAWAY ────────────────
//
// Brief: Ops/briefs/region-label-native-sk-spike.md (+ T's two amendments).
//
// THE QUESTION. The shipping region-label pill is a SwiftUI view (`TerritoryLabelPill`,
// `.ultraThinMaterial`) drawn in an overlay ABOVE the SpriteView, positioned from a bridged
// snapshot. Two renderers on two clocks → the pill lands ~1 frame behind the orb it is pinned to,
// and further behind as fps dips. That is the SWIM T reports. It is not a math bug: the scene
// computes label positions from the same sprite positions it just moved. It is the handoff.
//
// A native SK label cannot swim BY CONSTRUCTION: it is a node in the same scene, drawn in the same
// pass, moved by the same camera transform, on the same display link as the orbs. This spike puts
// one on screen next to the SwiftUI one so T can judge (a) does it stick, (b) is the look
// acceptable without live frosted glass, (c) what does each cost in fps.
//
// WHY THE LOOK IS THE WHOLE TRADE. The ONLY reason the labels are SwiftUI is `.ultraThinMaterial`
// (see `setTerritoryLabels`' note). SpriteKit cannot blur live content behind a node cheaply —
// `SKEffectNode` blurs the node's OWN backing, not the map behind it (the same framebuffer-read
// limit that killed the glow-ground blend). So the three treatments below are the honest options:
//   • FLAT     — solid capsule, palette-stroked. Cheapest. No depth cue.
//   • GRADIENT — vertical light→dark fill. Still one draw, a hint of dimension.
//   • FROST    — ★ amendment B: a UIVisualEffectView(.ultraThinMaterial) capsule rendered ONCE at
//                first use and reused as an SKTexture. It is a STATIC BAKE, not live sampling:
//                it cannot respond to what is behind it (pan a bright orb under it and the frost
//                will not change). That is exactly the compromise T is being asked to rule on.
//
// Text is MSDF (`MSDFLabel`), the same crisp resolution-independent path the orb titles already
// use — no new atlas, no raster text.
//
// EVERYTHING HERE IS `#if DEBUG` AND THROWAWAY. Nothing graduates until T rules; graduation is a
// separate arc (retire the SwiftUI overlay, port the fade/hysteresis — already in-scene — onto the
// SK node's alpha instead of a bridged `declutterAlpha`).

/// Which renderer(s) draw the region labels (amendment A).
enum RegionLabelSpikeMode: Int, CaseIterable {
    case swiftUIOnly = 0, skOnly = 1, both = 2
    var name: String { ["SwiftUI", "SK", "Both"][rawValue] }
}

/// Capsule treatment behind the SK glyphs (amendment B adds `.frost`).
enum RegionLabelSpikeTreatment: Int, CaseIterable {
    case flat = 0, gradient = 1, frost = 2
    var name: String { ["Flat", "Gradient", "Frost"][rawValue] }
}

/// Builds + maintains the SK region-label nodes. One layer, one node per label, reused per frame
/// (never rebuilt unless the text/treatment changes) so the spike's own cost stays honest.
final class RegionLabelSKLayer {
    /// Scene-space layer. Above orbs (z=1) so a label is never buried, below the focal z (1000).
    private let layer = SKNode()
    private var nodes: [String: Node] = [:]
    /// The treatment the current capsules were built for — a change forces a rebuild.
    private var builtTreatment: RegionLabelSpikeTreatment?

    private struct Node {
        let root: SKNode
        let capsule: SKSpriteNode
        let glyphs: SKNode
        let text: String
    }

    init(parent: SKNode) {
        layer.zPosition = 6          // above orbs + their titles, below the focal card
        layer.name = "regionLabelSKSpike"
        parent.addChild(layer)
    }

    /// Hide everything (mode = SwiftUI-only, or the spike is off) without tearing state down.
    func setHidden(_ hidden: Bool) { layer.isHidden = hidden }

    /// Per-frame update. `items` carries each label's WORLD position (so the node rides the camera
    /// exactly like an orb — this is the anti-swim property) plus the alpha the scene already
    /// computed for the SwiftUI path, so both renderers fade identically and the A/B is fair.
    ///
    /// `cameraScale` keeps the pill a CONSTANT ON-SCREEN SIZE (the SwiftUI pill doesn't zoom, and
    /// the comparison would be meaningless if one scaled and the other didn't).
    func update(items: [(key: String, text: String, world: CGPoint, alpha: CGFloat, colorHex: String)],
                cameraScale: CGFloat,
                treatment: RegionLabelSpikeTreatment,
                isLight: Bool) {
        if builtTreatment != treatment {          // treatment switched → rebuild the capsules
            for (_, n) in nodes { n.root.removeFromParent() }
            nodes.removeAll()
            builtTreatment = treatment
        }
        var live = Set<String>()
        for item in items {
            live.insert(item.key)
            let node: Node
            if let existing = nodes[item.key], existing.text == item.text {
                node = existing
            } else {
                nodes[item.key]?.root.removeFromParent()
                node = build(text: item.text, colorHex: item.colorHex, treatment: treatment, isLight: isLight)
                layer.addChild(node.root)
                nodes[item.key] = node
            }
            node.root.position = item.world        // WORLD space → same transform as the orbs
            node.root.setScale(cameraScale)        // constant on-screen size
            node.root.alpha = item.alpha
        }
        for (key, n) in nodes where !live.contains(key) {   // gone this frame → drop
            n.root.removeFromParent()
            nodes.removeValue(forKey: key)
        }
    }

    func teardown() {
        for (_, n) in nodes { n.root.removeFromParent() }
        nodes.removeAll()
        layer.removeFromParent()
    }

    // MARK: - Build

    private func build(text: String, colorHex: String,
                       treatment: RegionLabelSpikeTreatment, isLight: Bool) -> Node {
        let root = SKNode()
        let upper = text.uppercased()
        // Match the SHIPPING pill's geometry so the A/B compares LOOK, not size. Same shared
        // metrics the SwiftUI pill and the scene's declutter box read.
        let pointSize = RegionLabelPillMetrics.fontSize
        let font = MSDFFont.named("spacegroteskbold_msdf")
        let textW = MSDFLabel.textWidth(upper, pointSize: pointSize, font: font)
        let w = max(textW + RegionLabelPillMetrics.hPad * 2, RegionLabelPillMetrics.minHeight)
        let h = max(pointSize + RegionLabelPillMetrics.vPad * 2, RegionLabelPillMetrics.minHeight)

        let stroke = UIColor(hex: colorHex) ?? .gray
        let ink: UIColor = isLight ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 1, alpha: 0.95)

        let capsule = SKSpriteNode(texture: Self.capsuleTexture(size: CGSize(width: w, height: h),
                                                               treatment: treatment,
                                                               isLight: isLight,
                                                               stroke: stroke))
        capsule.size = CGSize(width: w, height: h)
        capsule.zPosition = 0
        root.addChild(capsule)

        let glyphs = MSDFLabel.makeContainer(lines: [upper], pointSize: pointSize,
                                             color: ink, fullTitle: upper, font: font)
        glyphs.zPosition = 1
        root.addChild(glyphs)
        return Node(root: root, capsule: capsule, glyphs: glyphs, text: text)
    }

    // MARK: - Capsule textures (cached per size+treatment+appearance)

    private static var textureCache: [String: SKTexture] = [:]

    private static func capsuleTexture(size: CGSize, treatment: RegionLabelSpikeTreatment,
                                       isLight: Bool, stroke: UIColor) -> SKTexture {
        // Round the size so near-identical labels share one texture (the cache is the point:
        // the FROST bake in particular must not run per label per frame).
        let w = (size.width / 4).rounded() * 4
        let key = "\(Int(w))x\(Int(size.height))|\(treatment.rawValue)|\(isLight ? "L" : "D")|\(stroke.hashValue)"
        if let t = textureCache[key] { return t }
        let sz = CGSize(width: w, height: size.height)
        let radius = sz.height / 2
        let image: UIImage

        switch treatment {
        case .flat, .gradient:
            let r = UIGraphicsImageRenderer(size: sz)
            image = r.image { ctx in
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: radius)
                ctx.cgContext.addPath(path.cgPath); ctx.cgContext.clip()
                if treatment == .flat {
                    // Solid ground-ish fill — the cheapest honest option.
                    (isLight ? UIColor(white: 1, alpha: 0.92) : UIColor(white: 0.10, alpha: 0.92)).setFill()
                    ctx.fill(CGRect(origin: .zero, size: sz))
                } else {
                    // Vertical light→dark: one draw, a hint of dimension without a blur.
                    let cs = CGColorSpaceCreateDeviceRGB()
                    let top = isLight ? UIColor(white: 1.0, alpha: 0.95) : UIColor(white: 0.20, alpha: 0.95)
                    let bot = isLight ? UIColor(white: 0.88, alpha: 0.95) : UIColor(white: 0.07, alpha: 0.95)
                    if let g = CGGradient(colorsSpace: cs, colors: [top.cgColor, bot.cgColor] as CFArray,
                                          locations: [0, 1]) {
                        ctx.cgContext.drawLinearGradient(g, start: .zero,
                                                         end: CGPoint(x: 0, y: sz.height), options: [])
                    }
                }
                // Palette stroke, same 1.5pt weight as the shipping pill.
                ctx.cgContext.resetClip()
                stroke.withAlphaComponent(0.95).setStroke()
                let sp = UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz).insetBy(dx: 0.75, dy: 0.75),
                                      cornerRadius: radius - 0.75)
                sp.lineWidth = 1.5
                sp.stroke()
            }

        case .frost:
            // ★ Amendment B — BAKE a real `.ultraThinMaterial` capsule ONCE and reuse it as a
            // texture. `UIVisualEffectView` blurs what is BEHIND it in the view hierarchy; rendered
            // standalone it resolves to the material's own base tint, which is precisely the point:
            // it LOOKS like the shipping glass but is STATIC — it cannot react to the map beneath.
            // T is ruling on whether that difference is perceptible in motion.
            let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            effect.frame = CGRect(origin: .zero, size: sz)
            effect.layer.cornerRadius = radius
            effect.layer.masksToBounds = true
            effect.layer.borderWidth = 1.5
            effect.layer.borderColor = stroke.withAlphaComponent(0.95).cgColor
            effect.overrideUserInterfaceStyle = isLight ? .light : .dark
            let r = UIGraphicsImageRenderer(size: sz)
            image = r.image { _ in
                // drawHierarchy renders the LIVE material (layer.render misses visual effects).
                effect.drawHierarchy(in: CGRect(origin: .zero, size: sz), afterScreenUpdates: true)
            }
        }

        let tex = SKTexture(image: image)
        textureCache[key] = tex
        return tex
    }
}
#endif
