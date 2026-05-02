import SpriteKit
import UIKit
import simd

/// Tiled square grid background with animated luma matte and noise-driven
/// UV displacement. White lines on transparent background, alpha modulated
/// per-fragment by a 3D value-noise field evolving in time.
///
/// AT18.1.6 — May 2, 2026. Geometry swapped from the AT18.1.3-1.5 isometric
/// tile to a square 1:1 tile (asset renamed in the catalog from
/// `IsometricGrid` to `BackgroundGrid`). Tile dimensions go from 70x80 to
/// 70x70; chunk size 560pt still divides cleanly (560 / 70 = 8 tiles per
/// chunk side). Zoom is decoupled from this node: the parent scene applies a
/// per-frame inverse-scale counter-transform so the grid stays at constant
/// screen-pixel size regardless of camera zoom (fixes moire shimmer at extreme
/// zoom-out). Pan still works because the grid sits at world origin and the
/// camera moves over it. The noise field is therefore anchored to the grid
/// surface itself — correct, since noise is a property of the grid, not the
/// world.
///
/// Preserved from AT18.1.3-1.5: chunked architecture (each chunk gets its own
/// SKShader instance with a per-chunk u_chunkCenter uniform so noise stays
/// continuous across chunk seams); ASCII-only shader source; u_time
/// auto-supplied by SpriteKit; premultiplied alpha; locked design values
/// (baseAlpha 0.30, noise scale 0.008, intensity 0.74, speed 0.5,
/// displacement scale 0.012, speed 0.5, amplitude 6.0).
///
/// Tiling strategy (preserved): SKShapeNode.fillTexture and SKSpriteNode.texture
/// both stretch a single texture across their bounds in this SpriteKit version,
/// neither tiles. So we tile explicitly: bake a chunk image once, then lay out
/// a grid of identical SKSpriteNode chunks across `rectSize`. All chunks share
/// one SKTexture. Per-chunk shader instances mean SpriteKit can no longer batch
/// them into a single draw call, but the shader is light (one texture sample,
/// two 3D noise calls) so the draw-call cost is acceptable on iPad at 120Hz.
enum BackgroundGridNode {

    /// Total side length covered by the grid in world points.
    static let rectSize: CGFloat = 8192

    /// On-screen size of one tile. Square 1:1, locked at fine-texture density.
    static let tileSize = CGSize(width: 70, height: 70)

    /// Base opacity. Bumped from the original 0.07 because the high-res
    /// source PNG downsampled to 70pt washes out the strokes. Now applied
    /// inside the shader as `baseOpacity` so the noise matte modulates around
    /// it; the parent node's alpha stays at 1.0.
    static let baseAlpha: CGFloat = 0.30

    /// Side length of one baked chunk. Must be an integer multiple of the
    /// tile size so chunk-to-chunk borders fall on tile borders and the
    /// pattern continues seamlessly. 560 = 70 x 8.
    private static let chunkSize: CGFloat = 560

    static func make() -> SKNode {
        let tile = loadTileImage()
        let chunkTexture = bakeChunkTexture(from: tile)
        let shaderSource = makeShaderSource()

        let parent = SKNode()
        parent.zPosition = -1000
        parent.name = "backgroundGrid"

        let chunkCount = Int((rectSize / chunkSize).rounded(.up))
        let half = CGFloat(chunkCount) * chunkSize * 0.5
        for i in 0..<chunkCount {
            for j in 0..<chunkCount {
                let chunk = SKSpriteNode(
                    texture: chunkTexture,
                    size: CGSize(width: chunkSize, height: chunkSize)
                )
                let center = CGPoint(
                    x: -half + chunkSize * (CGFloat(i) + 0.5),
                    y: -half + chunkSize * (CGFloat(j) + 0.5)
                )
                chunk.position = center
                chunk.blendMode = .alpha

                let shader = SKShader(source: shaderSource)
                shader.uniforms = [
                    SKUniform(
                        name: "u_chunkCenter",
                        vectorFloat2: vector_float2(Float(center.x), Float(center.y))
                    )
                ]
                chunk.shader = shader

                parent.addChild(chunk)
            }
        }
        return parent
    }

    /// Resize the source PNG once to the locked 70pt tile size. Decouples
    /// the source asset's pixel resolution from on-screen tile dimensions.
    private static func loadTileImage() -> UIImage {
        guard let source = UIImage(named: "BackgroundGrid") else {
            fatalError("BackgroundGrid asset missing from asset catalog")
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: tileSize))
        }
    }

    /// Stamp the resized tile across a `chunkSize`-square image. Done once
    /// at scene setup; the resulting SKTexture is shared by every chunk
    /// sprite so the bake cost is paid exactly once.
    private static func bakeChunkTexture(from tile: UIImage) -> SKTexture {
        let size = CGSize(width: chunkSize, height: chunkSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            var y: CGFloat = 0
            while y < chunkSize {
                var x: CGFloat = 0
                while x < chunkSize {
                    tile.draw(in: CGRect(
                        x: x,
                        y: y,
                        width: tileSize.width,
                        height: tileSize.height
                    ))
                    x += tileSize.width
                }
                y += tileSize.height
            }
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    /// GLSL ES source. Identical for every chunk; only `u_chunkCenter` differs
    /// at the uniform level. The 560.0 constant is interpolated from
    /// `chunkSize` so the two stay in sync if the chunk dimensions ever change.
    private static func makeShaderSource() -> String {
        return """
        // 3D value noise -- helpers must precede main per GLSL ES rules.

        float hash3(vec3 p) {
            return fract(sin(p.x * 127.1 + p.y * 311.7 + p.z * 74.7) * 43758.5453);
        }

        float smoothstep3(float t) {
            return t * t * (3.0 - 2.0 * t);
        }

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

        void main() {
            // World-space coordinate for noise sampling. v_tex_coord runs 0..1
            // across this chunk's own span; u_chunkCenter (per-chunk uniform)
            // shifts into world space so noise stays continuous across seams.
            vec2 worldPos = (v_tex_coord - vec2(0.5)) * \(chunkSize) + u_chunkCenter;

            // --- Displacement layer ---
            // Sample a separate noise field to compute a UV offset.
            // Independent z-offsets (+1000.0 / +2000.0) decorrelate from the
            // luma noise so the two effects don't pulse in lockstep.
            const float displaceScale = 0.012;
            const float displaceSpeed = 0.5;
            const float displaceAmp   = 6.0;

            float dx_noise = valueNoise3(vec3(worldPos * displaceScale, u_time * displaceSpeed + 1000.0));
            float dy_noise = valueNoise3(vec3(worldPos * displaceScale, u_time * displaceSpeed + 2000.0));

            vec2 displacement = vec2(dx_noise - 0.5, dy_noise - 0.5) * 2.0 * displaceAmp;
            vec2 displacedUV = v_tex_coord + displacement / \(chunkSize);

            vec4 tex = texture2D(u_texture, displacedUV);

            const float noiseScale     = 0.008;
            const float noiseIntensity = 0.74;
            const float noiseSpeed     = 0.5;
            const float baseOpacity    = 0.30;

            float n = valueNoise3(vec3(worldPos * noiseScale, u_time * noiseSpeed));
            float matte = 1.0 + (n - 0.5) * 2.0 * noiseIntensity;

            float alpha = clamp(tex.a * baseOpacity * matte, 0.0, 1.0);

            // SpriteKit uses premultiplied alpha. White lines -> RGB = alpha.
            gl_FragColor = vec4(alpha, alpha, alpha, alpha);
        }
        """
    }
}
