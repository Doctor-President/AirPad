#include <metal_stdlib>
using namespace metal;

// BlobField — one GPU primitive, several costumes (see briefs 2026-07-02).
//
// Renders N animated blobs analytically in the fragment shader: no CPU
// rasterization, no Canvas, no Core Animation `.blur()` pass. Invoked as a
// SwiftUI `.colorEffect`. `position`/`color` are supplied by SwiftUI; every
// argument after that is passed by BlobFieldView, IN ORDER:
//   time         — seconds, pre-wrapped with fmod(t, 1000) on the Swift side
//   size         — view size in points (0..w, 0..h), matches `position`
//   globalOrigin — view's global origin (only used when sharedField > 0.5)
//   sharedField  — 0 = sample in local space (default); 1 = world space
//   style        — 0 = lava (additive radial, normalized); 1 = card
//                  (source-over, blurred-disc, absolute-point); 2 = hero
//                  (card + per-pixel harmonic wobble + drift/buoyancy/breathe)
//   anchor       — card rest reference as a fraction of size ((0.5,0.5) =
//                  center; (0.5,1.0) = bottom). Card style only; lava/hero ignore.
//   params       — flat float buffer; stride depends on `style` (see below)
//   paramCount   — element count of `params`, auto-appended by SwiftUI for the
//                  .floatArray argument. .floatArray ALWAYS binds TWO shader
//                  params (the `device const float *` pointer AND this trailing
//                  int); it must be declared or stitching fails ("Extra
//                  function argument ... int"). This int is SwiftUI's, not ours.
//
// LAVA layout (stride 10) — matches the Stage-1 lava lamp, unchanged:
//   [0] ox  [1] oy  [2] r  [3] spx  [4] spy  [5] phase  [6] peak
//   [7] cr  [8] cg  [9] cb
//
// CARD layout (stride 15) — the static NodeGradientLayer circles (Stage 2), now with an
// OPTIONAL boundary wobble (card-morph, 2026-08-16 — irregular edges WITH the card's colour):
//   [0] baseX [1] baseY  (points, relative to view center; baseY folds in
//                         centerYOffset)
//   [2] radius (points)  [3] driftFX  [4] driftFY
//   [5] phaseX [6] phaseY (already phase*seed, precomputed in Swift)
//   [7] driftAmp (points) [8] blurWidth (points, the falloff ramp half-width)
//   [9] peak   [10] cr [11] cg [12] cb
//   [13] undulation (domain-warp AMPLITUDE; 0 = plain disc → byte-identical)
//   [14] seed (per-blob noise offset so blobs don't warp in lockstep)
//   [15] warpScale (noise wavelength as a MULTIPLE of blob radius; larger = fewer, flowing lobes)
//
// HERO layout (stride 23) — the morphing detail-hero blobs (Stage 3). Same
// source-over blurred blob as CARD, but the boundary radius wobbles per pixel
// via a harmonic sum, plus drift / buoyancy / breathing. undulation, the three
// harmonics, and blurWidth ride in the per-blob buffer (no global uniforms):
//   [0] baseX [1] baseY  (points, rel. view center; baseY folds centerYOffset)
//   [2] baseSize (points, diameter before breathing)
//   [3] driftFX [4] driftFY  [5] buoyancyFreq  [6] breatheFreq
//   [7] seedPhase (per-blob seed; harmonic/drift phases derive from it)
//   [8..10] harmonic k0,k1,k2   [11..13] harmonic amp0,amp1,amp2
//   [14..16] harmonic speed0,speed1,speed2 (already base + index*0.03)
//   [17] undulation [18] blurWidth [19] peak  [20] cr [21] cg [22] cb

constant int LAVA_STRIDE = 10;
constant int CARD_STRIDE = 16;
constant int HERO_STRIDE = 23;

// Fixed hero motion constants — match the CPU morphBlob literals.
constant float HERO_BREATHE_AMP    = 0.10;   // ±10% size pulse
constant float HERO_DRIFT_AMP      = 30.0;   // ±30pt sin/cos drift
constant float HERO_BUOYANCY_SWELL = 45.0;   // ±45pt slow vertical swell

// CARD domain warp (2026-08-16 — REPLACES the angular-harmonic deform). The old deform was
// r(θ) = radius·(1 + u·Σ ampᵢ·sin(kᵢθ)) with k = [2,3,5] — a circle carrying 2/3/5-lobe standing
// waves, i.e. a flower BY CONSTRUCTION (no amplitude makes it organic). Instead we warp the sample
// point in POSITION space by 2-octave value-noise fbm BEFORE length(), so the boundary is
// irregular + non-repeating (lava-lamp organic). undulation scales the displacement → 0 leaves the
// sample untouched → today's plain disc (same byte-identity guarantee as deform·0 = 0).
// Wavelength is now the per-blob `warpScale` (param 15, in blob-radii) — NOT a hardcoded
// frequency — so T can dial the noise scale relative to radius (same value reads the same on a
// 60pt and a 200pt blob). SCALE (wavelength) and AMPLITUDE (`undulation`) are independent dials.
constant float CARD_WARP_AMP   = 0.40;   // max displacement as a fraction of radius at undulation 1
constant float CARD_WARP_SPEED = 0.20;   // noise-field drift rate (organic churn)

// Cheap 2D value noise + 2-octave fbm for the card domain warp. Value noise = a hash lattice with
// smoothstep interpolation → C1-continuous, so the warped boundary stays smooth, not faceted.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float dd = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, dd, u.x), u.y);
}
// 2 OCTAVES (T's call). Dropping to 1 is the device backoff if the canvas feels heavy.
static float fbm2(float2 p) {
    float v = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < 2; i++) { v += amp * valueNoise(p); norm += amp; p *= 2.0; amp *= 0.5; }
    return v / norm;   // normalized to [0,1]
}

// Imagery-derived bloom (2026-08-16). A soft ADDITIVE halo tinted by each blob's OWN colour,
// reaching beyond the disc so the glow comes FROM the colour — it follows the imagery, so there
// is no fixed radial to miscenter (replaces the SwiftUI `radialGlow` circle). Scaled by the
// global `bloom` uniform; bloom 0 → zero contribution → BYTE-IDENTICAL. The halo e-folds (exp)
// over BLOOM_FALLOFF·radius measured OUTSIDE the disc boundary, so bright cores bloom and the
// glow decays with real light falloff rather than a hand-drawn ramp.
constant float BLOOM_FALLOFF  = 0.70;   // glow e-folding length as a fraction of blob radius
constant float BLOOM_STRENGTH = 0.75;   // overall gain at bloom = 1

// LAVA piecewise opacity ramp by radius fraction f (0 = center, 1 = edge).
// Reproduces the four SwiftUI gradient stops exactly:
//   0.00 -> peak, 0.40 -> peak*0.73, 0.75 -> peak*0.33, 1.00 -> 0.
static float blobFalloff(float f, float peak) {
    f = clamp(f, 0.0, 1.0);
    if (f <= 0.40) {
        return mix(peak, peak * 0.73, f / 0.40);
    } else if (f <= 0.75) {
        return mix(peak * 0.73, peak * 0.33, (f - 0.40) / 0.35);
    } else {
        return mix(peak * 0.33, 0.0, (f - 0.75) / 0.25);
    }
}

// LAVA — four wide ambient blobs, additive, sampled in normalized space.
// Byte-for-byte the Stage-1 math; do not disturb.
static half4 lavaField(float2 samplePos, float time, float2 size,
                       device const float *params, int paramCount) {
    float tScaled = time * 8.0;
    float minDim  = min(size.x, size.y);

    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);

    int count = paramCount / LAVA_STRIDE;
    for (int i = 0; i < count; i++) {
        int b = i * LAVA_STRIDE;
        float ox    = params[b + 0];
        float oy    = params[b + 1];
        float r     = params[b + 2];
        float spx   = params[b + 3];
        float spy   = params[b + 4];
        float phase = params[b + 5];
        float peak  = params[b + 6];
        half3 col   = half3(params[b + 7], params[b + 8], params[b + 9]);

        float cx = (sin(tScaled * spx + phase) * 0.28 + ox) * size.x;
        float cy = (cos(tScaled * spy + phase * 0.7) * 0.28 + oy) * size.y;
        float radius = r * minDim;

        float f  = distance(samplePos, float2(cx, cy)) / radius;
        float op = blobFalloff(f, peak);

        accumRGB += col * half(op);
        accumA   += half(op);
    }

    // Additive: overlaps brighten. rgb <= a holds through the sum (both scale
    // by op), so the premultiplied result never oversaturates.
    return half4(saturate(accumRGB), saturate(accumA));
}

// CARD — the three static NodeGradientLayer circles. Opaque discs with a
// blurred rim, composited source-over in painter's order (blob 0 back →
// last front), so overlaps read exactly like the SwiftUI ZStack of blurred
// Circles. Coordinates are absolute points (center + drift), not fractions.
static half4 cardField(float2 samplePos, float time, float2 size,
                       float2 anchor, float bloom, device const float *params, int paramCount) {
    // Rest reference for the blobs. (0.5,0.5) = card center (default);
    // (0.5,1.0) = bottom edge, so on a hero-image card the color pools at
    // the floor beneath the photo instead of bleeding up into it.
    float2 center = size * anchor;

    // Premultiplied source-over accumulator.
    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);
    // Additive imagery bloom, accumulated separately then added on top (emitted light).
    half3 bloomRGB = half3(0.0);
    half  bloomA   = half(0.0);

    int count = paramCount / CARD_STRIDE;
    for (int i = 0; i < count; i++) {
        int b = i * CARD_STRIDE;
        float baseX     = params[b + 0];
        float baseY     = params[b + 1];
        float radius    = params[b + 2];
        float driftFX   = params[b + 3];
        float driftFY   = params[b + 4];
        float phaseX    = params[b + 5];
        float phaseY    = params[b + 6];
        float driftAmp  = params[b + 7];
        float blurWidth = params[b + 8];
        float peak      = params[b + 9];
        half3 col       = half3(params[b + 10], params[b + 11], params[b + 12]);
        float undulation = params[b + 13];
        float seed       = params[b + 14];
        float warpScale  = params[b + 15];

        float cx = center.x + baseX + sin(driftFX * time + phaseX) * driftAmp;
        float cy = center.y + baseY + cos(driftFY * time + phaseY) * driftAmp;

        // Blurred disc, but the sample point is DOMAIN-WARPED before measuring distance: displace
        // `rel` (blob-local) by a 2-octave fbm vector, scaled by undulation, so the boundary is
        // irregular + non-repeating (organic) rather than a smooth lobed circle. undulation 0 →
        // the warp block is skipped → relW = rel → the plain disc, byte-identical to today.
        float2 rel  = samplePos - float2(cx, cy);
        float2 relW = rel;
        if (undulation > 0.0) {
            float2 q    = rel / max(radius, 1.0);        // normalize → warp is size-independent
            float  freq = 1.0 / max(warpScale, 0.05);    // wavelength = warpScale·radius (cycles/radius)
            float  ts   = time * CARD_WARP_SPEED;        // drift the noise field so the boundary churns
            // Two decorrelated fbm samples form the warp vector; `seed` de-syncs each blob.
            float2 warp = float2(fbm2(q * freq + float2(seed + ts, seed)),
                                 fbm2(q * freq + float2(seed, seed - ts) + 19.3)) - 0.5;
            relW = rel + warp * (undulation * CARD_WARP_AMP * radius);
        }
        float d = length(relW);
        float a = peak * (1.0 - smoothstep(radius - blurWidth, radius + blurWidth, d));

        // Source-over, premultiplied: this blob on top of everything so far.
        half sa = half(a);
        accumRGB = col * sa + accumRGB * (1.0h - sa);
        accumA   = sa      + accumA   * (1.0h - sa);

        // Imagery bloom: a soft additive halo in THIS blob's colour, e-folding OUTSIDE the warped
        // boundary (radius, in warped space). bloom 0 → skipped → byte-identical. Follows the colour.
        if (bloom > 0.0) {
            float glowOut = max(0.0, d - radius);
            float halo    = exp(-glowOut / max(1.0, radius * BLOOM_FALLOFF));
            float bAmt    = bloom * BLOOM_STRENGTH * peak * halo;
            bloomRGB += col * half(bAmt);
            bloomA   += half(bAmt);
        }
    }

    return half4(saturate(accumRGB + bloomRGB), saturate(accumA + bloomA));
}

// HERO — the morphing detail-hero blobs. Same source-over blurred blob as
// CARD, but the disc boundary is not a fixed radius: for each pixel we take its
// angle around the blob center and evaluate the harmonic sum to get the
// boundary radius AT THAT ANGLE, then test the pixel against it. Same math the
// CPU BlobShape used to build a 60-point outline — moved from "build the shape"
// to "test each pixel against the shape." Plus drift, buoyancy, breathing.
static half4 heroField(float2 samplePos, float time, float2 size,
                       float bloom, device const float *params, int paramCount) {
    float2 center = size * 0.5;

    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);
    half3 bloomRGB = half3(0.0);
    half  bloomA   = half(0.0);

    int count = paramCount / HERO_STRIDE;
    for (int i = 0; i < count; i++) {
        int b = i * HERO_STRIDE;
        float baseX      = params[b + 0];
        float baseY      = params[b + 1];
        float baseSize   = params[b + 2];
        float driftFX    = params[b + 3];
        float driftFY    = params[b + 4];
        float buoyFreq   = params[b + 5];
        float breatheFreq = params[b + 6];
        float seed       = params[b + 7];
        float k0 = params[b + 8],  k1 = params[b + 9],  k2 = params[b + 10];
        float a0 = params[b + 11], a1 = params[b + 12], a2 = params[b + 13];
        float s0 = params[b + 14], s1 = params[b + 15], s2 = params[b + 16];
        float undulation = params[b + 17];
        float blurWidth  = params[b + 18];
        float peak       = params[b + 19];
        half3 col        = half3(params[b + 20], params[b + 21], params[b + 22]);

        // Breathing → base radius.
        float breatheSize = baseSize * (1.0 + HERO_BREATHE_AMP * sin(breatheFreq * time + seed));
        float baseR = breatheSize * 0.5;

        // Drift (+ buoyancy on y) → blob center.
        float driftX = baseX + sin(driftFX * time + seed * 1.3) * HERO_DRIFT_AMP;
        float driftY = cos(driftFY * time + seed * 0.9) * HERO_DRIFT_AMP
                     + sin(buoyFreq * time + seed) * HERO_BUOYANCY_SWELL;
        float cx = center.x + driftX;
        float cy = center.y + driftY + baseY;

        float2 rel = samplePos - float2(cx, cy);
        float d = length(rel);
        float theta = atan2(rel.y, rel.x);

        // Wobbling boundary: r(θ) = R·(1 + undulation·Σ ampᵢ·sin(kᵢθ + speedᵢ·t + φᵢ)),
        // φᵢ = seed + i·0.9 — the exact harmonic sum the CPU BlobShape used.
        float deform = a0 * sin(k0 * theta + s0 * time + seed)
                     + a1 * sin(k1 * theta + s1 * time + seed + 0.9)
                     + a2 * sin(k2 * theta + s2 * time + seed + 1.8);
        float boundaryR = baseR * (1.0 + undulation * deform);

        float a = peak * (1.0 - smoothstep(boundaryR - blurWidth, boundaryR + blurWidth, d));

        half sa = half(a);
        accumRGB = col * sa + accumRGB * (1.0h - sa);
        accumA   = sa      + accumA   * (1.0h - sa);

        // Imagery bloom (same as cardField; e-folds over baseR here). bloom 0 → byte-identical.
        if (bloom > 0.0) {
            float glowOut = max(0.0, d - boundaryR);
            float halo    = exp(-glowOut / max(1.0, baseR * BLOOM_FALLOFF));
            float bAmt    = bloom * BLOOM_STRENGTH * peak * halo;
            bloomRGB += col * half(bAmt);
            bloomA   += half(bAmt);
        }
    }

    return half4(saturate(accumRGB + bloomRGB), saturate(accumA + bloomA));
}

// Low-frequency domain warp for SLIGHT blob irregularity (#3). Displaces the
// sample point by a few low-freq sines so blob edges read wavy instead of
// perfectly circular. `amount` is the displacement in points; `scale` sets the
// spatial frequency. Gated by amount > 0 at the call site, so every existing
// caller (node cards, hero, dark lava) passes 0 and is BYTE-IDENTICAL.
static float2 blobWarp(float2 p, float t, float scale, float amount) {
    float2 q = p * scale * 0.01;
    float wx = sin(q.y * 1.3 + t * 0.30) + 0.5 * sin(q.x * 2.1 + t * 0.22);
    float wy = cos(q.x * 1.1 + t * 0.25) + 0.5 * cos(q.y * 1.9 + t * 0.18);
    return p + float2(wx, wy) * amount;
}

[[ stitchable ]] half4 blobField(float2 position,
                                 half4 color,
                                 float time,
                                 float2 size,
                                 float2 globalOrigin,
                                 float sharedField,
                                 float style,
                                 float2 anchor,
                                 float noiseAmount,
                                 float noiseScale,
                                 float bloom,
                                 device const float *params,
                                 int paramCount) {
    // sharedField switch: local space by default; offset the sample point by
    // the view's global origin when on, so sibling surfaces read different
    // slices of one continuous field. One `if`, wired but default-off.
    float2 samplePos = position + globalOrigin * step(0.5, sharedField);

    // #3 — slight-irregularity domain warp, off unless the caller dials it in.
    if (noiseAmount > 0.001) {
        samplePos = blobWarp(samplePos, time, noiseScale, noiseAmount);
    }

    if (style < 0.5) {
        return lavaField(samplePos, time, size, params, paramCount);
    } else if (style < 1.5) {
        return cardField(samplePos, time, size, anchor, bloom, params, paramCount);
    } else {
        return heroField(samplePos, time, size, bloom, params, paramCount);
    }
}
