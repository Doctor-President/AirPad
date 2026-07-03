#include <metal_stdlib>
using namespace metal;

// BlobField — one GPU primitive, three costumes (see brief 2026-07-02).
//
// Renders N animated radial-gradient blobs analytically in the fragment
// shader: no CPU rasterization, no Canvas, no Core Animation `.blur()` pass.
// The soft falloff below IS the answer to `.blur(radius:)` — the ramp width
// is computed per-pixel on the GPU.
//
// Invoked as a SwiftUI `.colorEffect`. `position`/`color` are supplied by
// SwiftUI; every argument after that is passed by BlobFieldView, IN ORDER:
//   time         — seconds, pre-wrapped with fmod(t, 1000) on the Swift side
//   size         — view size in points (0..w, 0..h), matches `position`
//   globalOrigin — view's global origin (only used when sharedField > 0.5)
//   sharedField  — 0 = sample in local space (default); 1 = world space
//   params       — flat float buffer, BLOB_STRIDE floats per blob (see layout)
//   paramCount   — element count of `params`, auto-appended by SwiftUI for the
//                  .floatArray argument (blob count = paramCount / BLOB_STRIDE).
//                  NOTE: .floatArray always binds TWO shader params — the
//                  `device const float *` pointer AND this trailing int. It
//                  must be declared or stitching fails ("Extra function
//                  argument ... int"). This int is SwiftUI's, not one we pass.
//
// Per-blob layout in `params` (must match BlobFieldView.pack):
//   [0] ox   [1] oy   [2] r    [3] spx  [4] spy
//   [5] phase [6] peak [7] cr  [8] cg   [9] cb

constant int BLOB_STRIDE = 10;

// Piecewise opacity ramp by radius fraction f (0 = center, 1 = edge).
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

[[ stitchable ]] half4 blobField(float2 position,
                                 half4 color,
                                 float time,
                                 float2 size,
                                 float2 globalOrigin,
                                 float sharedField,
                                 device const float *params,
                                 int paramCount) {
    // sharedField switch: local space by default; offset the sample point by
    // the view's global origin when on, so sibling surfaces read different
    // slices of one continuous field. One `if`, wired but default-off.
    float2 samplePos = position + globalOrigin * step(0.5, sharedField);

    float tScaled = time * 8.0;
    float minDim  = min(size.x, size.y);

    // Additive compositing. Because each blob contributes col*op to rgb and op
    // to alpha with the same op weight, the premultiplied invariant rgb <= a
    // holds through the sum — overlaps brighten without oversaturating.
    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);

    int count = paramCount / BLOB_STRIDE;
    for (int i = 0; i < count; i++) {
        int b = i * BLOB_STRIDE;
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

    return half4(saturate(accumRGB), saturate(accumA));
}
