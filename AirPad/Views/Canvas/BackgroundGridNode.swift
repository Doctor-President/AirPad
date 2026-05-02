import SpriteKit
import simd

/// Procedural adaptive square grid. Fully GPU-rendered: lines computed
/// per-fragment in world space, with three levels of adaptive subdivision
/// that fade in/out by screen-space density. World-space animated noise
/// (luma matte + UV displacement) modulates the lines.
///
/// AT18.1.10 — May 2, 2026. Replaces the chunked-tile approach (AT18.1.3-1.9)
/// which couldn't satisfy correct pan AND zoom anchor with a single scaled
/// parent. The shape is parented to cameraNode so its screen position is
/// fixed; the shader reconstructs world coordinates from v_tex_coord plus
/// camera position + scale uniforms. No transform gymnastics.
///
/// Locked design values (preserved from AT18.1.4-1.5):
///   stroke 0.50pt screen-space, base opacity 0.30, white,
///   luma noise scale 0.008 / intensity 0.74 / speed 0.5,
///   displacement noise scale 0.006 / amplitude 6.0 / speed 0.5,
///   z-offsets +1000 / +2000 to decorrelate displacement from luma.
///
/// Adaptive subdivision: three levels at periods 100 / 500 / 2500 world
/// points (ratio 5), peak opacity at ~60px screen-space spacing.
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

        // World-space distance to nearest line of a square grid at given period.
        // d <= 0 means the fragment is within halfStrokeWorld of a line (on-line);
        // d > 0 means off-line. min over axes because a fragment is on a line if
        // EITHER axis distance puts it inside the stroke band.
        float lineDistance(vec2 worldPos, float period, float halfStrokeWorld) {
            vec2 m = mod(worldPos, period);
            // distance from nearest cell edge, range [0, period/2]
            vec2 distFromEdge = (period * 0.5) - abs(m - period * 0.5);
            // negative when within halfStrokeWorld of the edge
            vec2 d = distFromEdge - halfStrokeWorld;
            return min(d.x, d.y);
        }

        // Adaptive opacity for one grid level, by screen-space period.
        // Steepness 0.3: each level visible for ~6.67 octaves (vs 4 at 0.5).
        // Adjacent ratio-5 levels overlap ~4.35 octaves so 2-3 levels are
        // typically active at once -- finer grids fade in earlier as you
        // zoom out, coarser ones linger as you zoom in.
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

            // --- Displacement (samples in screen space) ---
            // Noise sampled at screenOffset so the pattern is welded to the
            // screen during zoom/pan. Amplitude expressed in screen pixels and
            // converted to world units via u_camera_scale so the wiggle
            // magnitude is constant regardless of zoom.
            const float displaceScale     = 0.006;
            const float displaceSpeed     = 0.5;
            const float displaceAmpScreen = 6.0;  // screen pixels
            float displaceAmpWorld = displaceAmpScreen * u_camera_scale;
            float dx_n = valueNoise3(vec3(screenOffset * displaceScale, u_time * displaceSpeed + 1000.0));
            float dy_n = valueNoise3(vec3(screenOffset * displaceScale, u_time * displaceSpeed + 2000.0));
            vec2 displacement = vec2(dx_n - 0.5, dy_n - 0.5) * 2.0 * displaceAmpWorld;
            vec2 displacedWorld = worldPos + displacement;

            // --- Adaptive subdivision: five grid levels ---
            // Ratio 5: each coarse cell subdivides into 5x5 finer cells.
            // Periods 2, 10, 50, 250, 1250 -- p2=50 sits near the 60px
            // visibility peak at xScale=1, so the default look is dominated
            // by the 50-world-point level with crossfade emerging on either
            // side as the user zooms. Adjacent levels overlap ~1.68 octaves;
            // if crossfade pops, lower steepness in levelOpacity from 0.5.
            const float targetPx = 60.0;
            const float strokePx = 0.5;     // screen-space stroke width

            // Convert screen-space stroke into world space at this zoom.
            // 1 screen point = u_camera_scale world points (zoom-out convention).
            float halfStrokeWorld = (strokePx * 0.5) * u_camera_scale;
            float feather = halfStrokeWorld * 0.5;

            float p0 = 2.0;
            float p1 = 10.0;
            float p2 = 50.0;
            float p3 = 250.0;
            float p4 = 1250.0;

            // Screen period = world period / world-per-screen ratio.
            float a0 = levelOpacity(p0 / u_camera_scale, targetPx);
            float a1 = levelOpacity(p1 / u_camera_scale, targetPx);
            float a2 = levelOpacity(p2 / u_camera_scale, targetPx);
            float a3 = levelOpacity(p3 / u_camera_scale, targetPx);
            float a4 = levelOpacity(p4 / u_camera_scale, targetPx);

            float d0 = lineDistance(displacedWorld, p0, halfStrokeWorld);
            float d1 = lineDistance(displacedWorld, p1, halfStrokeWorld);
            float d2 = lineDistance(displacedWorld, p2, halfStrokeWorld);
            float d3 = lineDistance(displacedWorld, p3, halfStrokeWorld);
            float d4 = lineDistance(displacedWorld, p4, halfStrokeWorld);

            float c0 = (1.0 - smoothstep(0.0, feather, d0)) * a0;
            float c1 = (1.0 - smoothstep(0.0, feather, d1)) * a1;
            float c2 = (1.0 - smoothstep(0.0, feather, d2)) * a2;
            float c3 = (1.0 - smoothstep(0.0, feather, d3)) * a3;
            float c4 = (1.0 - smoothstep(0.0, feather, d4)) * a4;
            float lineCoverage = max(max(c0, c1), max(c2, max(c3, c4)));

            // --- Luma matte (samples in screen space, decorrelated z) ---
            // Pattern stays welded to the screen during zoom/pan, like a veil
            // over the camera rather than a texture on the world.
            const float lumaScale     = 0.008;
            const float lumaIntensity = 0.74;
            const float lumaSpeed     = 0.5;
            float n = valueNoise3(vec3(screenOffset * lumaScale, u_time * lumaSpeed));
            float matte = 1.0 + (n - 0.5) * 2.0 * lumaIntensity;

            // --- Composite ---
            // baseOpacity 0.25 = peak line opacity; matte modulates around it.
            const float baseOpacity = 0.25;
            float alpha = clamp(lineCoverage * baseOpacity * matte, 0.0, 1.0);

            // Premultiplied output (white lines).
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
