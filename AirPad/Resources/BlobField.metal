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
//                  (source-over, blurred-disc, absolute-point)
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

constant int LAVA_STRIDE = 10;
constant int CARD_STRIDE = 13;

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
                       device const float *params, int paramCount) {
    float2 center = size * 0.5;

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

[[ stitchable ]] half4 blobField(float2 position,
                                 half4 color,
                                 float time,
                                 float2 size,
                                 float2 globalOrigin,
                                 float sharedField,
                                 float style,
                                 device const float *params,
                                 int paramCount) {
    // sharedField switch: local space by default; offset the sample point by
    // the view's global origin when on, so sibling surfaces read different
    // slices of one continuous field. One `if`, wired but default-off.
    float2 samplePos = position + globalOrigin * step(0.5, sharedField);

    if (style < 0.5) {
        return lavaField(samplePos, time, size, params, paramCount);
    } else {
        return cardField(samplePos, time, size, params, paramCount);
    }
}
