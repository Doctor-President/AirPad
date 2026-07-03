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
// CARD layout (stride 13) — the static NodeGradientLayer circles (Stage 2):
//   [0] baseX [1] baseY  (points, relative to view center; baseY folds in
//                         centerYOffset)
//   [2] radius (points)  [3] driftFX  [4] driftFY
//   [5] phaseX [6] phaseY (already phase*seed, precomputed in Swift)
//   [7] driftAmp (points) [8] blurWidth (points, the falloff ramp half-width)
//   [9] peak   [10] cr [11] cg [12] cb
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
constant int CARD_STRIDE = 13;
constant int HERO_STRIDE = 23;

// Fixed hero motion constants — match the CPU morphBlob literals.
constant float HERO_BREATHE_AMP    = 0.10;   // ±10% size pulse
constant float HERO_DRIFT_AMP      = 30.0;   // ±30pt sin/cos drift
constant float HERO_BUOYANCY_SWELL = 45.0;   // ±45pt slow vertical swell

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
                       float2 anchor, device const float *params, int paramCount) {
    // Rest reference for the blobs. (0.5,0.5) = card center (default);
    // (0.5,1.0) = bottom edge, so on a hero-image card the color pools at
    // the floor beneath the photo instead of bleeding up into it.
    float2 center = size * anchor;

    // Premultiplied source-over accumulator.
    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);

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

        float cx = center.x + baseX + sin(driftFX * time + phaseX) * driftAmp;
        float cy = center.y + baseY + cos(driftFY * time + phaseY) * driftAmp;

        // Blurred opaque disc: solid to (radius - blurWidth), ramp across the
        // rim, gone by (radius + blurWidth). The ramp IS the blur.
        float d = distance(samplePos, float2(cx, cy));
        float a = peak * (1.0 - smoothstep(radius - blurWidth, radius + blurWidth, d));

        // Source-over, premultiplied: this blob on top of everything so far.
        half sa = half(a);
        accumRGB = col * sa + accumRGB * (1.0h - sa);
        accumA   = sa      + accumA   * (1.0h - sa);
    }

    return half4(saturate(accumRGB), saturate(accumA));
}

// HERO — the morphing detail-hero blobs. Same source-over blurred blob as
// CARD, but the disc boundary is not a fixed radius: for each pixel we take its
// angle around the blob center and evaluate the harmonic sum to get the
// boundary radius AT THAT ANGLE, then test the pixel against it. Same math the
// CPU BlobShape used to build a 60-point outline — moved from "build the shape"
// to "test each pixel against the shape." Plus drift, buoyancy, breathing.
static half4 heroField(float2 samplePos, float time, float2 size,
                       device const float *params, int paramCount) {
    float2 center = size * 0.5;

    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);

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
    }

    return half4(saturate(accumRGB), saturate(accumA));
}

[[ stitchable ]] half4 blobField(float2 position,
                                 half4 color,
                                 float time,
                                 float2 size,
                                 float2 globalOrigin,
                                 float sharedField,
                                 float style,
                                 float2 anchor,
                                 device const float *params,
                                 int paramCount) {
    // sharedField switch: local space by default; offset the sample point by
    // the view's global origin when on, so sibling surfaces read different
    // slices of one continuous field. One `if`, wired but default-off.
    float2 samplePos = position + globalOrigin * step(0.5, sharedField);

    if (style < 0.5) {
        return lavaField(samplePos, time, size, params, paramCount);
    } else if (style < 1.5) {
        return cardField(samplePos, time, size, anchor, params, paramCount);
    } else {
        return heroField(samplePos, time, size, params, paramCount);
    }
}
