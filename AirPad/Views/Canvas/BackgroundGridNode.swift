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
    /// Defaults are the shipped list-grid values (1.5 / 0.25 / 50 / 5 / 3); the
    /// Map passes its own baked literals (0.5 dot / 83 period) at construction
    /// and drives per-mode dot color + opacity live via `setDotAppearance`.
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
        let source = """
        // --- Helpers (must precede main per GLSL ES rules) ---

        // Adaptive opacity for one grid level, by screen-space period.
        // Steepness 0.3: each level visible for ~6.67 octaves (vs 4 at 0.5).
        // Adjacent ratio-5 levels overlap ~4.35 octaves so 2-3 levels are
        // typically active at once -- finer dots fade in earlier as you
        // zoom in, coarser ones linger as you zoom out.
        float levelOpacity(float screenPeriod, float targetPx) {
            float t = log2(screenPeriod / targetPx);
            return clamp(1.0 - abs(t) * 0.3, 0.0, 1.0);
        }

        // --- Main ---

        void main() {
            // Reconstruct world position of this fragment.
            // SpriteKit camera convention: xScale > 1 = zoomed out (more world
            // visible per screen point). So 1 screen point = u_camera_scale
            // world points -> world = camPos + screenOffset * u_camera_scale.
            vec2 screenOffset = (v_tex_coord - vec2(0.5)) * u_viewport_size;
            vec2 worldPos = u_camera_position + screenOffset * u_camera_scale;

            // --- LOD constants ---
            // Three layers, ratio 5: p1 (period) sits near the 60px visibility
            // peak at xScale=1, so the look is dominated by the p1 layer, with
            // p0 = p1/ratio fading in on zoom in and p2 = p1*ratio on zoom out.
            // dotBasePx / baseOpac / period are UNIFORMS baked at makeShape: the
            // Map bakes 0.5 / (per-mode 0.18 dark · 0.47 light) / 83; the 4
            // shared list grids keep 1.5 / 0.25 / 50. p0/p1/p2 stay ratio-5
            // nested off the period.
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

            // Each layer: SDF against the containing cell's centre dot.
            // cell index = floor(worldPos / period); center = (cell + 0.5) *
            // period; distance = length(worldPos - center) - baseR (negative
            // inside the dot). Uniform radius per layer (noise removed).

            // --- Layer 0 (finest) ---
            vec2  cell0     = floor(worldPos / p0);
            vec2  center0   = (cell0 + 0.5) * p0;
            float d0        = length(worldPos - center0) - baseR;
            float c0        = (1.0 - smoothstep(0.0, feather, d0)) * a0;

            // --- Layer 1 (default-visible) ---
            vec2  cell1     = floor(worldPos / p1);
            vec2  center1   = (cell1 + 0.5) * p1;
            float d1        = length(worldPos - center1) - baseR;
            float c1        = (1.0 - smoothstep(0.0, feather, d1)) * a1;

            // --- Layer 2 (coarsest) ---
            vec2  cell2     = floor(worldPos / p2);
            vec2  center2   = (cell2 + 0.5) * p2;
            float d2        = length(worldPos - center2) - baseR;
            float c2        = (1.0 - smoothstep(0.0, feather, d2)) * a2;

            // Recursion gate: u_lod_levels 1 = c1 only, 2 = + coarse, 3 = all.
            // Baked to 3 (the shipped level count) — all layers composite.
            float c0g = c0 * step(2.5, u_lod_levels);
            float c2g = c2 * step(1.5, u_lod_levels);
            float coverage = max(c1, max(c0g, c2g));
            float alpha    = clamp(coverage * baseOpac, 0.0, 1.0);

            // Premultiplied output. u_dot_color is the per-theme dot tint
            // (default white → dark byte-identical: (1,1,1)*alpha reproduces the
            // old vec4(alpha,alpha,alpha,alpha)); light mode pushes a cool
            // graphite so the dots read on cream (ws-dark-light-mode item 3).
            gl_FragColor = vec4(u_dot_color * alpha, alpha);
        }
        """

        let shader = SKShader(source: source)
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
            SKUniform(name: "u_dot_color",   vectorFloat3: vector_float3(1, 1, 1))
        ]
        return shader
    }
}
