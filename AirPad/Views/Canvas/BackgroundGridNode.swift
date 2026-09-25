import SpriteKit
import simd

/// Procedural adaptive dot-matrix grid. GPU-rendered: per-fragment SDF
/// against three explicit frequency layers (no shader loops — each layer
/// unrolled to dodge the iOS 26 SpriteKit GLSL→Metal landmine on
/// uniform-gated loops). Dot centers sit at cell centers of a square
/// lattice; layers nest at ratio 5 so finer dots appear *between* coarser
/// dots without coarser ones drifting.
///
/// Dots are STEADY. The earlier build flowed a translating value-noise
/// field across the lattice to modulate each dot's radius (breathing) and
/// luma (shimmer); T dialed that to zero and it was removed (bake-and-
/// delete), so the field no longer samples noise or reads `u_time` — the
/// grid is static per-frame.
///
/// Replaces the line-grid implementation (AT18.1.10): same camera-
/// reconstruction approach (camera position + scale uniforms, world-space
/// position rebuilt from v_tex_coord), same screen-space stroke convention,
/// same `levelOpacity` LOD curve. UV displacement is gone (dots don't need
/// the organic wiggle that lines did).
enum BackgroundGridNode {

    /// Per-frame: push camera position and scale into the shader uniforms.
    static func update(_ shape: SKShapeNode, cameraPosition: CGPoint, cameraScale: CGFloat) {
        guard let uniforms = shape.fillShader?.uniforms else { return }
        for u in uniforms {
            switch u.name {
            case "u_camera_position":
                u.vectorFloat2Value = vector_float2(Float(cameraPosition.x), Float(cameraPosition.y))
            case "u_camera_scale":
                u.floatValue = Float(cameraScale)
            default:
                break
            }
        }
    }

    /// Build the shape and shader. Caller adds it as a child of cameraNode
    /// at low zPosition, and resizes it via `resize(_:to:)` on scene size change.
    /// Both mount sites now pass explicit geometry — the Map and the list/grid
    /// `BackgroundGridView` both run 0.5 dot / 83 period — and drive per-mode dot
    /// color + opacity live via `setDotAppearance`. The 1.5 / 0.25 / 50 defaults
    /// are an unused fallback, kept for any future no-arg mount.
    static func makeShape(viewportSize: CGSize, fillTexture: SKTexture,
                          dotSizePx: Float = 1.5,
                          dotOpacity: Float = 0.25,
                          period: Float = 50,
                          ratio: Float = 5,
                          lodLevels: Float = 3) -> SKShapeNode {
        let half = CGSize(width: viewportSize.width / 2, height: viewportSize.height / 2)
        let rect = CGRect(x: -half.width, y: -half.height,
                          width: viewportSize.width, height: viewportSize.height)
        let shape = SKShapeNode(path: CGPath(rect: rect, transform: nil))
        shape.zPosition = -1000
        shape.name = "backgroundGrid"
        shape.fillColor = .white
        shape.strokeColor = .clear
        shape.lineWidth = 0
        shape.fillTexture = fillTexture
        shape.alpha = 1.0
        shape.blendMode = .alpha
        shape.fillShader = makeShader(viewportSize: viewportSize,
                                      dotSizePx: dotSizePx, dotOpacity: dotOpacity,
                                      period: period, ratio: ratio, lodLevels: lodLevels)
        return shape
    }

    /// Push the per-theme dot color + opacity into an existing grid's shader
    /// (live appearance flip). Both are baked into the makeShape uniforms, so
    /// list-view grids that never call this stay byte-identical; only the Map
    /// pushes a light-mode tint + per-mode opacity (ws-dark-light-mode). Color
    /// and opacity flip together on the same trait, so one uniform pass sets
    /// both. `opacity` is `u_dot_opacity` — the shipped single-constant dot
    /// alpha, now per-mode (0.18 dark · 0.47 light) via AppearancePalette.
    static func setDotAppearance(_ shape: SKShapeNode, r: Float, g: Float, b: Float, opacity: Float) {
        guard let uniforms = shape.fillShader?.uniforms else { return }
        for u in uniforms {
            switch u.name {
            case "u_dot_color":   u.vectorFloat3Value = vector_float3(r, g, b)
            case "u_dot_opacity": u.floatValue = opacity
            default: break
            }
        }
    }

    /// Resize when the viewport changes (e.g. orientation).
    static func resize(_ shape: SKShapeNode, to size: CGSize) {
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let rect = CGRect(x: -half.width, y: -half.height,
                          width: size.width, height: size.height)
        shape.path = CGPath(rect: rect, transform: nil)
        if let uniforms = shape.fillShader?.uniforms {
            for u in uniforms where u.name == "u_viewport_size" {
                u.vectorFloat2Value = vector_float2(Float(size.width), Float(size.height))
            }
        }
    }

    private static func makeShader(viewportSize: CGSize,
                                   dotSizePx: Float, dotOpacity: Float,
                                   period: Float, ratio: Float, lodLevels: Float) -> SKShader {
        // GRID-WARP SPIKE (2026-09-11): the pooling glow is retired; this warps the SAMPLED
        // coordinate before the existing SDF runs (nothing new is drawn). Two approaches, live-
        // switchable by u_warp_mode: 1 = IN-SHADER (per-fragment summed orb pull, CONSTANT loop
        // bound = 48 to dodge the uniform-gated-loop → Metal landmine); 2 = FIELD TEXTURE (a low-res
        // displacement field, CPU-built once/frame → constant per-fragment cost); 3 = DOT RELOCATION
        // (mode C, the one T is ruling on — moves dot CENTRES using B's field). 0 = off (byte-id).
        // MAXWARPORBS is a compile constant so the loop unrolls.
        //
        // MASS (2026-09-11 addendum): every orb used to displace the lattice by exactly the same
        // amount — a tiny node pinched as hard as the biggest one, so visual weight and gravitational
        // weight didn't correspond and the deformation read as unnatural. Each orb's contribution is
        // now weighted by its AMPLIFIED radius (the size the annulus produces, i.e. the size actually
        // on screen), and its reach widens with that radius too. The CPU packs the result; the shader
        // just decodes it against `u_warp_mass_range` (= 1 when the mass-influence dial is 0, which
        // makes BOTH the orb texture and the field byte-identical to the pre-mass encoding).
        let source = """
        // --- Helpers (must precede main per GLSL ES rules) ---

        float levelOpacity(float screenPeriod, float targetPx) {
            float t = log2(screenPeriod / targetPx);
            return clamp(1.0 - abs(t) * 0.3, 0.0, 1.0);
        }

        // --- Main ---

        void main() {
            // Screen offset (px from viewport centre) BEFORE any warp. EVERYTHING below is in PIXEL
            // space — pixels are isotropic, so there is NO aspect correction and no unit mismatch.
            vec2 screenOffset = (v_tex_coord - vec2(0.5)) * u_viewport_size;

            // WARP: the shipping path is DOT RELOCATION (mode 3), which leaves the sampled coordinate
            // UNSHIFTED — dots move, space doesn't, so nothing can smear; the SDF below relocates each
            // dot's centre using the displacement field. (The two sample-displacement approaches —
            // A in-shader per-fragment pull, B whole-field offset — were deleted at the 2026-09-14 bake:
            // mode C is the ruled shape, so they were unreachable.) Mode 0 = no warp at all.
            //
            // Reconstruct world position. SpriteKit camera convention: xScale > 1 = zoomed out.
            vec2 worldPos = u_camera_position + screenOffset * u_camera_scale;

            // --- LOD constants ---
            // Three layers, ratio 5: p1 (period) sits near the 60px visibility
            // peak at xScale=1, so the look is dominated by the p1 layer, with
            // p0 = p1/ratio fading in on zoom in and p2 = p1*ratio on zoom out.
            // dotBasePx / baseOpac / period are UNIFORMS set per mount site: both
            // the Map and the list/grid BackgroundGridView run 0.5 / 83 with
            // per-mode opacity (0.18 dark · 0.47 light) pushed via setDotAppearance.
            // p0/p1/p2 stay ratio-5 nested off the period.
            //
            // The translating value-noise field was REMOVED (bake-and-delete):
            // dots are steady, no radius breathing / luma shimmer and no u_time
            // dependence, so the grid is static.
            const float targetPx   = 60.0;
            float dotBasePx  = u_dot_base_px;   // dot radius, screen pixels
            float baseOpac   = u_dot_opacity;   // dot alpha at xScale=1

            float baseR    = dotBasePx * u_camera_scale;  // world units
            float feather  = 0.75 * u_camera_scale;       // edge softness in world units

            float p1 = u_period1;
            float p0 = p1 / u_ratio;   // finer lattice — u_ratio dots per cell edge
            float p2 = p1 * u_ratio;   // coarser lattice

            float a0 = levelOpacity(p0 / u_camera_scale, targetPx);
            float a1 = levelOpacity(p1 / u_camera_scale, targetPx);
            float a2 = levelOpacity(p2 / u_camera_scale, targetPx);

            float c0, c1, c2;
            if (u_warp_mode > 2.5) {
                // ── MODE C: DOT RELOCATION ──────────────────────────────────────────────────────
                // MOVE each dot's centre by the field-sampled warp, then measure a ROUND dot around
                // the MOVED centre. A circle evaluated around a point cannot smear (the sample-
                // coordinate reformulations do). Check the containing cell + its 8 NEIGHBOURS (3×3 =
                // 9 cells/layer) because a moved dot can land in a neighbour's cell. Dots also SHRINK
                // near mass (a depression recedes from the viewer). All bounds constant → unrolls.
                // The field's pull now carries MASS (full-scale u_warp_mass_range), so a big orb both
                // moves dots further and shrinks them harder — the dimple deepens with visible size.
                float kBase = u_warp_strength * u_camera_scale;   // world units per unit of pull
                float ps[3]; ps[0] = p0; ps[1] = p1; ps[2] = p2;
                float as[3]; as[0] = a0; as[1] = a1; as[2] = a2;
                float covs[3]; covs[0] = 0.0; covs[1] = 0.0; covs[2] = 0.0;
                for (int L = 0; L < 3; L++) {
                    float p = ps[L];
                    // The 3×3 search can only find a dot that stayed inside ONE cell. Mass lets the
                    // offset exceed a cell (the FINE lattice p0 could already overshoot pre-mass), and
                    // past that a dot silently vanishes — so cap the offset per LAYER, not globally.
                    float maxOff = 0.9 * p;
                    vec2 cell = floor(worldPos / p);
                    float cov = 0.0;
                    for (int ny = -1; ny <= 1; ny++) {
                        for (int nx = -1; nx <= 1; nx++) {
                            vec2 cc = (cell + vec2(float(nx), float(ny)) + 0.5) * p;    // cell centre, world
                            vec2 ccUV = ((cc - u_camera_position) / u_camera_scale) / u_viewport_size + vec2(0.5);
                            vec2 pull = (texture2D(u_disp_field, ccUV).rg - vec2(0.5)) * (2.0 * u_warp_mass_range);
                            float pullLen = length(pull);                  // reused by the shrink below
                            // RELOCATION inverts vs sample-displacement: to CONVERGE, move the dot
                            // centre TOWARD the orb (−away). sign flips it (button: Converge/Diverge).
                            float off = pullLen * kBase;
                            float k = off > maxOff ? kBase * (maxOff / off) : kBase;
                            vec2 moved = cc - pull * (k * u_warp_sign);
                            float shrink = clamp(1.0 - u_warp_shrink * pullLen, 0.15, 1.0);
                            float d = length(worldPos - moved) - baseR * shrink;
                            cov = max(cov, 1.0 - smoothstep(0.0, feather, d));
                        }
                    }
                    covs[L] = cov * as[L];
                }
                c0 = covs[0]; c1 = covs[1]; c2 = covs[2];
            } else {
                // Modes 0/1/2: SDF against the containing cell's centre (worldPos already sample-warped
                // for 1/2; unwarped for 0). center = (cell+0.5)*period; d = dist - baseR.
                vec2  cell0   = floor(worldPos / p0);
                float d0      = length(worldPos - (cell0 + 0.5) * p0) - baseR;
                c0 = (1.0 - smoothstep(0.0, feather, d0)) * a0;
                vec2  cell1   = floor(worldPos / p1);
                float d1      = length(worldPos - (cell1 + 0.5) * p1) - baseR;
                c1 = (1.0 - smoothstep(0.0, feather, d1)) * a1;
                vec2  cell2   = floor(worldPos / p2);
                float d2      = length(worldPos - (cell2 + 0.5) * p2) - baseR;
                c2 = (1.0 - smoothstep(0.0, feather, d2)) * a2;
            }

            // Recursion gate: u_lod_levels 1 = c1 only, 2 = + coarse, 3 = all.
            // Baked to 3 (the shipped level count) — all layers composite.
            float c0g = c0 * step(2.5, u_lod_levels);
            float c2g = c2 * step(1.5, u_lod_levels);
            float coverage = max(c1, max(c0g, c2g));
            float alpha    = clamp(coverage * baseOpac, 0.0, 1.0);

            // (The COLOUR REACTION — dot opacity rising where the grid compresses — was baked to 0
            // and deleted at the 2026-09-14 bake; T never dialled it on.)

            // Brief AS — MASS-FIELD RIPPLE (dark only; u_ripple_amt = 0 in light → byte-identical dots).
            // R (‖warp‖/K → invert → AE Levels gamma) is baked into the field B channel on the CPU at FULL
            // precision (no in-shader gamma on an 8-bit field → no stepping); the shader reads that single
            // linear-filtered channel and composites it Normal over (opaque ground ▸ dots) at u_ripple_amt.
            if (u_ripple_amt > 0.0) {
                float R = texture2D(u_disp_field, v_tex_coord).b;
                vec3 groundDots = u_ground_color * (1.0 - alpha) + u_dot_color * alpha;
                gl_FragColor = vec4(mix(groundDots, vec3(R), u_ripple_amt), 1.0);
            } else if (u_light_ground_on > 0.5) {
                // Brief AT — LIGHT comp: the grid OWNS the opaque #FFEEED ground (u_ground_color) so the
                // dots read on T's chosen ground. Pool was removed at the lock; just ground ▸ dots, opaque.
                vec3 groundDots = u_ground_color * (1.0 - alpha) + u_dot_color * alpha;
                gl_FragColor = vec4(groundDots, 1.0);
            } else {
                // Premultiplied output. u_dot_color is the per-theme dot tint
                // (default white → dark byte-identical: (1,1,1)*alpha reproduces the
                // old vec4(alpha,alpha,alpha,alpha)); light mode pushes a cool
                // graphite so the dots read on cream (ws-dark-light-mode item 3).
                gl_FragColor = vec4(u_dot_color * alpha, alpha);
            }
        }
        """

        let shader = SKShader(source: source)
        // Placeholder texture (no warp until the scene feeds the field).
        // u_disp_field = a low-res displacement field the CPU rewrites each frame.
        let fieldZero = SKTexture(data: Data(count: 4), size: CGSize(width: 1, height: 1))
        fieldZero.filteringMode = .linear
        shader.uniforms = [
            SKUniform(name: "u_camera_position", vectorFloat2: vector_float2(0, 0)),
            SKUniform(name: "u_camera_scale",    float: 1.0),
            SKUniform(name: "u_viewport_size",   vectorFloat2: vector_float2(Float(viewportSize.width),
                                                                              Float(viewportSize.height))),
            SKUniform(name: "u_dot_base_px", float: dotSizePx),
            SKUniform(name: "u_dot_opacity", float: dotOpacity),
            SKUniform(name: "u_period1",     float: period),
            SKUniform(name: "u_ratio",       float: ratio),
            SKUniform(name: "u_lod_levels",  float: lodLevels),
            SKUniform(name: "u_dot_color",   vectorFloat3: vector_float3(1, 1, 1)),
            // Warp (SHIPS — dot relocation). Mode 0 = off → byte-identical resting grid.
            SKUniform(name: "u_warp_mode",     float: 0),
            SKUniform(name: "u_warp_strength", float: 0),
            SKUniform(name: "u_warp_sign",     float: 1),
            SKUniform(name: "u_warp_shrink",   float: 0.4),   // mode 3: dots shrink near mass (depression recedes)
            SKUniform(name: "u_warp_mass_range", float: 1),   // 1 = mass influence 0 → encodings byte-identical
            SKUniform(name: "u_disp_field",    texture: fieldZero),
            // Brief AS — mass-field ripple (dark only; 0 in light → byte-identical). u_ground_color = #111115.
            SKUniform(name: "u_ripple_amt",   float: 0),
            SKUniform(name: "u_ground_color", vectorFloat3: vector_float3(0.0667, 0.0667, 0.0824)),
            // Brief AT — LIGHT comp owns the opaque ground (0 → dark/list byte-identical). Pool removed.
            SKUniform(name: "u_light_ground_on", float: 0)
        ]
        return shader
    }

    /// How many nearest orbs contribute to the displacement field (the CPU-side "48-set").
    static let maxWarpOrbs = 48

    /// Ceiling on a single orb's mass multiplier, and therefore the full-scale of the displacement
    /// field's 8-bit `rg` at mass influence 1. Doubles as the clip point of the summed field — it was
    /// 1.0 pre-mass, which orb centres already SATURATED, so without this headroom a heavy orb's
    /// dimple would flatten to a normal orb's at its core.
    ///
    /// 4 is not arbitrary: mode C clamps a dot's relocation to 0.9 of a lattice cell (see the shader),
    /// which at the dialled strength caps the expressible pull at ~3.4, and the dot-shrink term floors
    /// out around 2.1. Past ~4 the extra magnitude is invisible but would still cost every encoded
    /// value precision, so this is the point where headroom stops buying anything.
    static let warpMassCeiling: Float = 4

    /// The single source of truth for the mass encoding scale: the CPU divides by it, the shader
    /// multiplies by it (`u_warp_mass_range`).
    static func warpMassRange(influence: Double) -> Double {
        1 + min(1, max(0, influence)) * (Double(warpMassCeiling) - 1)
    }

    /// Per-frame push of the warp state. `mode` 0 = off · 3 = dot relocation (the shipping path).
    /// `field` = the low-res RG signed-pull texture (full-scale `massRange`), the sole warp input;
    /// pass nil to leave it untouched. `massRange` MUST be `warpMassRange(influence:)` — it is what
    /// both ends encode/decode with.
    static func setWarp(_ shape: SKShapeNode, mode: Float, strength: Float,
                        sign: Float, shrink: Float, massRange: Float, field: SKTexture?) {
        guard let uniforms = shape.fillShader?.uniforms else { return }
        for u in uniforms {
            switch u.name {
            case "u_warp_mode":       u.floatValue = mode
            case "u_warp_strength":   u.floatValue = strength
            case "u_warp_sign":       u.floatValue = sign
            case "u_warp_shrink":     u.floatValue = shrink
            case "u_warp_mass_range": u.floatValue = massRange
            case "u_disp_field":      if let t = field { u.textureValue = t }
            default: break
            }
        }
    }
}
