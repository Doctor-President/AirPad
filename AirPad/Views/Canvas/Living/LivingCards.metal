// Sweep 2b · 2.3 — the renderer trial, scene 2: every visible card's background in ONE instanced draw, behind the Cards
// collection view (scratch branch ws-2b-renderer-trial, never merged; Mac bench only). A quad per card (expanded by the
// shadow's reach): the card's drop shadow outside its rounded rect, its field inside. The field is `cardField` and the
// fluted glass (`fieldGlass`) copied from BlobField.metal (plain functions; copied, not shared, so the shipping shader
// stays byte-identical), composited the way NodeGradientLayer does: light = parchment + the field, plus-darker;
// dark = the ground, the field over it (screen between blobs, a little bloom), the radial glow (overlay) and the
// vignette (multiply). Layouts must match LivingCards.swift (all float4).

#include <metal_stdlib>
using namespace metal;

struct LCFrame {
    float4 f0;      // view w, h (pt), time (s), content scale (px per pt)
    float4 f1;      // dark (1 / 0), blob blend (0 normal · 2 screen), bloom, glass on (1 / 0)
    float4 base;    // light: parchment rgb · dark: ground rgb; a = corner radius (pt)
    float4 shadow;  // drop shadow colour (straight)
    float4 sh2;     // shadow radius (pt, before the card's scale), shadow y (pt), vignette opacity, glow strength
    float4 glow;    // glow start, glow end (fractions of the card width), 0, 0
};
struct LCCard { float4 rect; float4 misc; float4 blob[12]; };   // rect x, y, w, h (pt, view) · misc: blob y offset, shadow scale

constant int LC_CARD_STRIDE = 16;
constant float LC_CARD_WARP_AMP   = 0.40;
constant float LC_CARD_WARP_SPEED = 0.20;
constant float LC_BLOOM_FALLOFF  = 0.70;
constant float LC_BLOOM_STRENGTH = 0.75;
constant float LC_GLASS_VOID  = 0.1433333456516266;
constant float LC_GLASS_SLIT  = 5.175555542111397;
constant float LC_GLASS_GRAIN = 0.035333333909511565;

static float lc_hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
static float lc_valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = lc_hash21(i);
    float b = lc_hash21(i + float2(1.0, 0.0));
    float c = lc_hash21(i + float2(0.0, 1.0));
    float dd = lc_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, dd, u.x), u.y);
}
static float lc_fbm2(float2 p) {
    float v = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < 2; i++) { v += amp * lc_valueNoise(p); norm += amp; p *= 2.0; amp *= 0.5; }
    return v / norm;
}
static half3 lc_blendColor(half3 b, half3 s, float m) {
    if (m < 0.5)  return s;
    if (m < 1.5)  return b + s;
    if (m < 2.5)  return b + s - b * s;
    return s;   // the grid uses normal (light) or screen (dark) only
}

// cardField, as in BlobField.metal (copied verbatim but for the names).
static half4 lc_cardField(float2 samplePos, float time, float2 size,
                          float2 anchor, float bloom, float blend, device const float *params, int paramCount) {
    float2 center = size * anchor;
    half3 accumRGB = half3(0.0);
    half  accumA   = half(0.0);
    half3 bloomRGB = half3(0.0);
    half  bloomA   = half(0.0);
    int count = paramCount / LC_CARD_STRIDE;
    for (int i = 0; i < count; i++) {
        int b = i * LC_CARD_STRIDE;
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
        float2 rel  = samplePos - float2(cx, cy);
        float2 relW = rel;
        if (undulation > 0.0) {
            float2 q    = rel / max(radius, 1.0);
            float  freq = 1.0 / max(warpScale, 0.05);
            float  ts   = time * LC_CARD_WARP_SPEED;
            float2 warp = float2(lc_fbm2(q * freq + float2(seed + ts, seed)),
                                 lc_fbm2(q * freq + float2(seed, seed - ts) + 19.3)) - 0.5;
            relW = rel + warp * (undulation * LC_CARD_WARP_AMP * radius);
        }
        float d = length(relW);
        float a = peak * (1.0 - smoothstep(radius - blurWidth, radius + blurWidth, d));
        half sa = half(a);
        if (blend < 0.5) {
            accumRGB = col * sa + accumRGB * (1.0h - sa);
        } else {
            half3 base = accumA > 1e-4h ? accumRGB / accumA : half3(0.0h);
            half3 srcEff = mix(col, lc_blendColor(base, col, blend), accumA);
            accumRGB = srcEff * sa + accumRGB * (1.0h - sa);
        }
        accumA = sa + accumA * (1.0h - sa);
        if (bloom > 0.0) {
            float glowOut = max(0.0, d - radius);
            float halo    = exp(-glowOut / max(1.0, radius * LC_BLOOM_FALLOFF));
            float bAmt    = bloom * LC_BLOOM_STRENGTH * peak * halo;
            bloomRGB += col * half(bAmt);
            bloomA   += half(bAmt);
        }
    }
    return half4(saturate(accumRGB + bloomRGB), saturate(accumA + bloomA));
}

// fieldGlass, as in BlobField.metal (card style only; the glass buffer is a frame constant here).
static half4 lc_fieldGlass(float2 samplePos, float2 screenPos, float time, float2 size, float2 anchor, float bloom,
                           float blend, device const float *params, int paramCount, constant float *glass, float strength) {
    float W          = max(glass[1], 1.0);
    float2 tilt      = float2(glass[2], glass[3]) * W * strength;
    float ribs       = max(glass[4], 1.0);
    float voidAmt    = LC_GLASS_VOID * strength;
    float refraction = glass[5] * strength;
    float grain      = LC_GLASS_GRAIN * strength;
    float x  = screenPos.x / W;
    float t  = fract(x * ribs);
    float u  = t - 0.5;
    float lens = u / sqrt(1.0 - 3.6 * u * u) * 0.32;
    float o    = lens * refraction / ribs * 3.0 * W;
    float edge     = abs(2.0 * u);
    float transmit = mix(1.0, pow(edge, LC_GLASS_SLIT), voidAmt);
    half4 cG = lc_cardField(samplePos + float2(o, 0.0) + tilt, time, size, anchor, bloom, blend, params, paramCount);
    float3 c = float3(cG.rgb) * transmit;
    float  a = float(cG.a) * transmit;
    float n = lc_hash21(floor(screenPos * 3.0)) - 0.5;
    c = max(c + n * grain, 0.0);
    c = saturate(c);
    a = saturate(max(a, max(c.r, max(c.g, c.b))));
    return half4(half3(c), half(a));
}

/// blobFieldGlass's dispatch for a card (glass mode 1 = ribbed; ribs ride with the card; the fade down the card).
static half4 lc_field(float2 position, float2 samplePos, float time, float2 size, float bloom, float blend, bool glassOn,
                      device const float *params, constant float *glass) {
    float2 anchor = float2(0.5, 0.5);
    if (glassOn && glass[0] > 0.5 && glass[0] < 1.5) {
        float2 ribPos = glass[6] > 0.5 ? position : position;   // the grid's ribs ride with the card (no global origin)
        float fy = glass[9] > 0.5 ? position.x / max(size.x, 1.0) : position.y / max(size.y, 1.0);
        float k  = glass[7] < 0.999 ? smoothstep(glass[7], max(glass[8], glass[7] + 0.001), fy) : 0.0;
        if (k >= 1.0) return lc_cardField(samplePos, time, size, anchor, bloom, blend, params, 48);
        return lc_fieldGlass(samplePos, ribPos, time, size, anchor, bloom, blend, params, 48, glass, 1.0 - k);
    }
    return lc_cardField(samplePos, time, size, anchor, bloom, blend, params, 48);
}

struct LCOut {
    float4 position [[position]];
    float2 local;               // pt, card-local (0,0 = the card's top-left)
    uint iid [[flat]];
};

constant float2 lcCorner[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

vertex LCOut lc_card_v(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant LCFrame &F [[buffer(0)]], device const LCCard *C [[buffer(1)]]) {
    LCCard c = C[iid];
    float sc = c.misc.y;
    float m = F.sh2.x * sc * 2.0 + abs(F.sh2.y * sc) + 1.0;
    float2 local = mix(float2(-m), c.rect.zw + m, lcCorner[vid]);
    float2 screen = c.rect.xy + local;
    LCOut o;
    o.position = float4(screen.x / F.f0.x * 2.0 - 1.0, 1.0 - screen.y / F.f0.y * 2.0, 0.0, 1.0);
    o.local = local;
    o.iid = iid;
    return o;
}

static float lc_roundedBox(float2 p, float2 size, float r) {
    float2 q = abs(p - size * 0.5) - (size * 0.5 - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment half4 lc_card_f(LCOut in [[stage_in]], constant LCFrame &F [[buffer(0)]],
                         device const LCCard *C [[buffer(1)]], constant float *glass [[buffer(2)]]) {
    device const LCCard &c = C[in.iid];
    float2 size = c.rect.zw;
    float2 p = in.local;
    float r = F.base.a;
    float px = F.f0.w;
    float sd = lc_roundedBox(p, size, r);
    float cover = saturate(0.5 - sd * px);

    // Drop shadow (the cell's SwiftUI `.shadow`): the rounded rect moved down by y, softened over the radius.
    float sc = c.misc.y;
    float sr = max(F.sh2.x * sc, 0.5);
    float sds = lc_roundedBox(p - float2(0.0, F.sh2.y * sc), size, r);
    float shA = F.shadow.a * (1.0 - smoothstep(-sr, sr * 1.5, sds));
    half4 shadow = half4(half3(F.shadow.rgb) * half(shA), half(shA));
    if (cover <= 0.0) return shadow;

    // The field, card-local; the blob y offset (the tile's centerYOffset) moves the sample point instead of the blobs.
    float2 samplePos = p - float2(0.0, c.misc.x);
    device const float *params = (device const float *)&c.blob[0];
    bool dark = F.f1.x > 0.5;
    half4 fld = lc_field(p, samplePos, F.f0.z, size, F.f1.z, F.f1.y, F.f1.w > 0.5, params, glass);

    float3 outc;
    if (!dark) {
        // pigmentOnParchment: parchment, then the field at strength 1 with plus-darker: R = max(0, D − Sa + S).
        float3 D = F.base.rgb;
        outc = max(float3(0.0), D - float(fld.a) + float3(fld.rgb));
    } else {
        float3 B = F.base.rgb * (1.0 - float(fld.a)) + float3(fld.rgb);
        // radial glow: black → white 0.85 from width × start to width × end, overlay, × strength
        float dist = length(p - size * 0.5);
        float gt = saturate((dist - size.x * F.glow.x) / max(size.x * (F.glow.y - F.glow.x), 0.001));
        float3 gs = float3(gt);
        float ga = mix(1.0, 0.85, gt) * F.sh2.w;
        float3 ov = select(1.0 - 2.0 * (1.0 - B) * (1.0 - gs), 2.0 * B * gs, B < 0.5);
        B = mix(B, ov, ga);
        // vignette: clear → black × opacity from 0.20 w to 0.70 w, multiply
        float vt = saturate((dist - size.x * 0.20) / max(size.x * 0.50, 0.001));
        B = B * (1.0 - vt * F.sh2.z);
        outc = B;
    }
    half4 card = half4(half3(outc) * half(cover), half(cover));
    return card + shadow * (1.0h - half(cover));
}
