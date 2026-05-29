import SpriteKit
import simd

/// Procedural adaptive dot-matrix grid. GPU-rendered: per-fragment SDF
/// against three explicit frequency layers (no shader loops — each layer
/// unrolled to dodge the iOS 26 SpriteKit GLSL→Metal landmine on
/// uniform-gated loops). Dot centers sit at cell centers of a square
/// lattice; layers nest at ratio 5 so finer dots appear *between* coarser
/// dots without coarser ones drifting.
///
/// A 2D translating noise field flows across the lattice — sample
/// coordinates offset by `velocity * time` (no z-axis time evolution).
/// Each dot samples the field once at its screen-space center, and the
/// returned noise value modulates *both* that dot's radius (breathing)
/// and its luma (shimmer). Slow diagonal drift reads as ripples passing
/// through, not a pulsing shimmer.
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
    static func makeShape(viewportSize: CGSize, fillTexture: SKTexture) -> SKShapeNode {
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
        shape.fillShader = makeShader(viewportSize: viewportSize)
        return shape
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

    private static func makeShader(viewportSize: CGSize) -> SKShader {
        let source = """
        // --- Helpers (must precede main per GLSL ES rules) ---

        float hash3(vec3 p) {
            return fract(sin(p.x * 127.1 + p.y * 311.7 + p.z * 74.7) * 43758.5453);
        }
        float smoothstep3(float t) { return t * t * (3.0 - 2.0 * t); }
        float valueNoise3(vec3 p) {
            vec3 i = floor(p);
            vec3 f = p - i;
            float u = smoothstep3(f.x);
            float v = smoothstep3(f.y);
            float w = smoothstep3(f.z);
            float c000 = hash3(i + vec3(0.0, 0.0, 0.0));
            float c100 = hash3(i + vec3(1.0, 0.0, 0.0));
            float c010 = hash3(i + vec3(0.0, 1.0, 0.0));
            float c110 = hash3(i + vec3(1.0, 1.0, 0.0));
            float c001 = hash3(i + vec3(0.0, 0.0, 1.0));
            float c101 = hash3(i + vec3(1.0, 0.0, 1.0));
            float c011 = hash3(i + vec3(0.0, 1.0, 1.0));
            float c111 = hash3(i + vec3(1.0, 1.0, 1.0));
            float x00 = mix(c000, c100, u);
            float x10 = mix(c010, c110, u);
            float x01 = mix(c001, c101, u);
            float x11 = mix(c011, c111, u);
            float y0  = mix(x00, x10, v);
            float y1  = mix(x01, x11, v);
            return mix(y0, y1, w);
        }

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

            // --- Translating noise (the key visual change) ---
            // Sample coordinates are offset by velocity * time, so the noise
            // field FLOWS across the lattice (ripples in water) rather than
            // evolving in place (a pulsing shimmer). Sampled in screen space
            // so the flow feels welded to the viewport during pan/zoom; flow
            // speed is in screen pixels per second.
            const float flowScale  = 0.008;
            const float flowSpeedX = 56.0;
            const float flowSpeedY = 20.0;
            vec2 flow = vec2(flowSpeedX, flowSpeedY) * u_time;

            // --- LOD constants ---
            // Three layers, ratio 5: p1=50 sits near the 60px visibility peak
            // at xScale=1, so default look is dominated by the 50-world-point
            // layer with p0=10 fading in on zoom in and p2=250 on zoom out.
            const float targetPx   = 60.0;
            const float dotBasePx  = 1.5;   // peak dot radius, screen pixels
            const float dotModPx   = 0.8;   // breathing amplitude, screen pixels
            const float lumaInten  = 0.74;  // luma shimmer depth
            const float baseOpac   = 0.25;  // peak dot alpha at xScale=1

            float baseR    = dotBasePx * u_camera_scale;  // world units
            float modR     = dotModPx  * u_camera_scale;
            float feather  = 0.75 * u_camera_scale;       // edge softness in world units

            float p0 = 10.0;
            float p1 = 50.0;
            float p2 = 250.0;

            float a0 = levelOpacity(p0 / u_camera_scale, targetPx);
            float a1 = levelOpacity(p1 / u_camera_scale, targetPx);
            float a2 = levelOpacity(p2 / u_camera_scale, targetPx);

            // --- Layer 0 (finest) ---
            // Center of containing cell. cell index = floor(worldPos / period),
            // center = (cell + 0.5) * period. SDF distance is then
            // length(worldPos - center) - radius -- negative inside the dot.
            // Noise sample is taken once at the dot's SCREEN-space center, so
            // every fragment inside a given dot resolves to the same radius
            // and luma (no within-dot wobble).
            vec2  cell0     = floor(worldPos / p0);
            vec2  center0   = (cell0 + 0.5) * p0;
            vec2  dotScrn0  = (center0 - u_camera_position) / u_camera_scale;
            float n0        = valueNoise3(vec3((dotScrn0 - flow) * flowScale, 0.0));
            float r0        = max(0.0, baseR + (n0 - 0.5) * 2.0 * modR);
            float d0        = length(worldPos - center0) - r0;
            float luma0     = 1.0 + (n0 - 0.5) * 2.0 * lumaInten;
            float c0        = (1.0 - smoothstep(0.0, feather, d0)) * a0 * luma0;

            // --- Layer 1 (default-visible) ---
            vec2  cell1     = floor(worldPos / p1);
            vec2  center1   = (cell1 + 0.5) * p1;
            vec2  dotScrn1  = (center1 - u_camera_position) / u_camera_scale;
            float n1        = valueNoise3(vec3((dotScrn1 - flow) * flowScale, 0.0));
            float r1        = max(0.0, baseR + (n1 - 0.5) * 2.0 * modR);
            float d1        = length(worldPos - center1) - r1;
            float luma1     = 1.0 + (n1 - 0.5) * 2.0 * lumaInten;
            float c1        = (1.0 - smoothstep(0.0, feather, d1)) * a1 * luma1;

            // --- Layer 2 (coarsest) ---
            vec2  cell2     = floor(worldPos / p2);
            vec2  center2   = (cell2 + 0.5) * p2;
            vec2  dotScrn2  = (center2 - u_camera_position) / u_camera_scale;
            float n2        = valueNoise3(vec3((dotScrn2 - flow) * flowScale, 0.0));
            float r2        = max(0.0, baseR + (n2 - 0.5) * 2.0 * modR);
            float d2        = length(worldPos - center2) - r2;
            float luma2     = 1.0 + (n2 - 0.5) * 2.0 * lumaInten;
            float c2        = (1.0 - smoothstep(0.0, feather, d2)) * a2 * luma2;

            float coverage = max(c0, max(c1, c2));
            float alpha    = clamp(coverage * baseOpac, 0.0, 1.0);

            // Premultiplied output (white dots).
            gl_FragColor = vec4(alpha, alpha, alpha, alpha);
        }
        """

        let shader = SKShader(source: source)
        shader.uniforms = [
            SKUniform(name: "u_camera_position", vectorFloat2: vector_float2(0, 0)),
            SKUniform(name: "u_camera_scale",    float: 1.0),
            SKUniform(name: "u_viewport_size",   vectorFloat2: vector_float2(Float(viewportSize.width),
                                                                              Float(viewportSize.height)))
        ]
        return shader
    }
}
