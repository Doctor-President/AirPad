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
        // displacement field, CPU-built once/frame → constant per-fragment cost). 0 = off (byte-id).
        // MAXWARPORBS is a compile constant so the loop unrolls.
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

            // WARP: displace the SAMPLE coordinate to make the dot lattice CONVERGE toward each orb
            // (a mass on a stretched sheet, viewed top-down — density rises near the orb). Displacement
            // maps invert: pushing the lookup AWAY drags the visible pattern INWARD. u_warp_sign flips it.
            vec2 warp = vec2(0.0);
            if (u_warp_mode > 0.5 && u_warp_mode < 1.5) {
                // A — IN-SHADER. u_orb_data: rg = orb screen pos 0..1, b = MEMBERSHIP WEIGHT (fades to 0
                // at the nearest-48 boundary so orbs entering/leaving the set don't POP). Constant loop.
                for (int i = 0; i < 48; i++) {
                    vec4 P = texture2D(u_orb_data, vec2((float(i) + 0.5) / u_orb_texw, 0.5));
                    float w = P.b;                                          // membership weight (0..1)
                    if (w < 0.01) continue;
                    vec2 orbPx = (P.rg - vec2(0.5)) * u_viewport_size;      // orb, px from centre
                    vec2 rel = screenOffset - orbPx;                        // FRAGMENT - orb = AWAY (converge)
                    float dist = length(rel);                              // real px (isotropic)
                    if (dist > u_warp_reach) continue;
                    float f = pow(clamp(1.0 - dist / u_warp_reach, 0.0, 1.0), 1.0 + u_warp_falloff * 4.0);
                    vec2 dir = dist > 1e-3 ? rel / dist : vec2(0.0);       // unit direction, px space
                    warp += dir * f * w;                                   // px (× strength below)
                }
                warp *= u_warp_strength * u_warp_sign;
            } else if (u_warp_mode > 1.5 && u_warp_mode < 2.5) {
                // B — FIELD TEXTURE. rg = signed AWAY-pull (0.5-biased), same px sign convention as A.
                vec4 F = texture2D(u_disp_field, v_tex_coord);
                warp = (F.rg - vec2(0.5)) * 2.0 * u_warp_strength * u_warp_sign;
            }
            // C (mode 3) leaves worldPos UNSHIFTED — dots move, space doesn't (no smear); the SDF below
            // relocates cell centres. Still capture the fragment's pull for the colour reaction.
            float warpMag = length(warp);                                   // px, for the colour reaction
            if (u_warp_mode > 2.5) {
                warpMag = length((texture2D(u_disp_field, v_tex_coord).rg - vec2(0.5)) * 2.0) * u_warp_strength;
            }

            // Reconstruct world position from the WARPED screen offset. SpriteKit camera convention:
            // xScale > 1 = zoomed out. world = camPos + screenOffset * u_camera_scale.
            vec2 worldPos = u_camera_position + (screenOffset + warp) * u_camera_scale;

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
                float ps[3]; ps[0] = p0; ps[1] = p1; ps[2] = p2;
                float as[3]; as[0] = a0; as[1] = a1; as[2] = a2;
                float covs[3]; covs[0] = 0.0; covs[1] = 0.0; covs[2] = 0.0;
                for (int L = 0; L < 3; L++) {
                    float p = ps[L];
                    vec2 cell = floor(worldPos / p);
                    float cov = 0.0;
                    for (int ny = -1; ny <= 1; ny++) {
                        for (int nx = -1; nx <= 1; nx++) {
                            vec2 cc = (cell + vec2(float(nx), float(ny)) + 0.5) * p;    // cell centre, world
                            vec2 ccUV = ((cc - u_camera_position) / u_camera_scale) / u_viewport_size + vec2(0.5);
                            vec2 pull = (texture2D(u_disp_field, ccUV).rg - vec2(0.5)) * 2.0;   // AWAY-from-orb
                            // RELOCATION inverts vs sample-displacement: to CONVERGE, move the dot
                            // centre TOWARD the orb (−away). sign flips it (button: Converge/Diverge).
                            vec2 moved = cc - pull * (u_warp_strength * u_warp_sign * u_camera_scale);
                            float shrink = clamp(1.0 - u_warp_shrink * length(pull), 0.15, 1.0);
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

            // COLOUR REACTION: compressed regions (high displacement) read hotter — raise the dot
            // opacity where mass warps the grid. May make the dark-mode grid legible: texture where
            // there's mass, quiet elsewhere. `u_warp_react` 0 = off (byte-identical).
            alpha = clamp(alpha * (1.0 + u_warp_react * warpMag), 0.0, 1.0);

            // Premultiplied output. u_dot_color is the per-theme dot tint
            // (default white → dark byte-identical: (1,1,1)*alpha reproduces the
            // old vec4(alpha,alpha,alpha,alpha)); light mode pushes a cool
            // graphite so the dots read on cream (ws-dark-light-mode item 3).
            gl_FragColor = vec4(u_dot_color * alpha, alpha);
        }
        """

        let shader = SKShader(source: source)
        // Placeholder textures (warp off until the scene feeds them). u_orb_data = 48×1 RGBA;
        // u_disp_field = a low-res field the CPU rewrites each frame.
        let orbZero = SKTexture(data: Data(count: maxWarpOrbs * 4), size: CGSize(width: maxWarpOrbs, height: 1))
        orbZero.filteringMode = .nearest
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
            // Warp (grid-deformation spike). Mode 0 = off → byte-identical resting grid.
            SKUniform(name: "u_warp_mode",     float: 0),
            SKUniform(name: "u_warp_strength", float: 0),
            SKUniform(name: "u_warp_reach",    float: 220),
            SKUniform(name: "u_warp_falloff",  float: 0.5),
            SKUniform(name: "u_warp_react",    float: 0),
            SKUniform(name: "u_warp_sign",     float: 1),
            SKUniform(name: "u_warp_shrink",   float: 0.4),   // mode 3: dots shrink near mass (depression recedes)
            SKUniform(name: "u_orb_texw",      float: Float(maxWarpOrbs)),
            SKUniform(name: "u_orb_data",      texture: orbZero),
            SKUniform(name: "u_disp_field",    texture: fieldZero)
        ]
        return shader
    }

    /// In-shader loop bound (constant → unrolls, dodges the uniform-gated-loop landmine).
    static let maxWarpOrbs = 48

    /// Per-frame push of the warp state (spike). `mode` 0 off · 1 in-shader · 2 field.
    /// `orbData` (48×1 RGBA: rg = orb screen pos 0..1, b = active) drives mode 1; `field` (low-res
    /// RG signed-pull) drives mode 2. Pass nil to leave a texture untouched.
    static func setWarp(_ shape: SKShapeNode, mode: Float, strength: Float, reach: Float,
                        falloff: Float, react: Float, sign: Float, shrink: Float, orbData: SKTexture?, field: SKTexture?) {
        guard let uniforms = shape.fillShader?.uniforms else { return }
        for u in uniforms {
            switch u.name {
            case "u_warp_mode":     u.floatValue = mode
            case "u_warp_strength": u.floatValue = strength
            case "u_warp_reach":    u.floatValue = reach
            case "u_warp_falloff":  u.floatValue = falloff
            case "u_warp_react":    u.floatValue = react
            case "u_warp_sign":     u.floatValue = sign
            case "u_warp_shrink":   u.floatValue = shrink
            case "u_orb_data":      if let t = orbData { u.textureValue = t }
            case "u_disp_field":    if let t = field { u.textureValue = t }
            default: break
            }
        }
    }
}
