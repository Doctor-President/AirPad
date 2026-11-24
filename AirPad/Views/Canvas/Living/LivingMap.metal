// Sweep 2b · 2.3 — the renderer trial's Map (scratch branch ws-2b-renderer-trial, never merged; Mac bench only).
// One render pass, five draws: the ground (a full-screen triangle with the dot grid, no gravity wells), the orbs (one
// instanced quad each; the hover ring is a term of the orb's own fragment, so it cannot leave its orb), the titles (one
// instanced draw of MSDF glyph quads; zoom scale and the LOD fade in the vertex shader), and the region pills (capsules,
// then their MSDF text), all placed from ONE camera per frame. Layouts must match LivingMap.swift (all float4).

#include <metal_stdlib>
using namespace metal;

struct LMFrame {
    float4 f0;   // view w, h (pt), camera x, y (world, y up)
    float4 f1;   // camera scale (world pt per screen pt), content scale (px per pt), zoom ramp, annulus envelope
    float4 f2;   // annulus amplitude, annulus radius (pt), title LOD start (pt diameter), title LOD full
    float4 f3;   // orb opacity, hovered orb index (-1 none), bare (1 = plain discs), time (s)
    float4 ring; // hover ring colour (straight)
    float4 f5;   // ground rgb, dot opacity
    float4 f6;   // dot rgb, dot radius (pt)
    float4 f7;   // dot period, ratio, LOD levels, region pill text alpha (zoom)
    float4 f8;   // region pill material alpha (zoom), pill ink rgb
    float4 pillFill;   // straight
    float4 f10;  // atlas distance range (texels), atlas size (px per em), region pill text pt, 0
};

struct LMOrb { float4 o0; float4 fill; };          // home x, y (world), radius (pt), 0 · fill (straight, a = meta)
struct LMGlyph { float4 plane; float4 uv; float4 ink; float4 g3; };   // plane x0, y0, w, h (pt, y up) · uv · ink · (owner, pt)
struct LMLabel { float4 l0; float4 stroke; };      // anchor x, y (world), w, h (pt) · stroke (straight)

constant float2 kCorner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

static float2 toScreen(float2 world, constant LMFrame &F) {
    float2 d = (world - F.f0.zw) / F.f1.x;
    return float2(d.x + F.f0.x * 0.5, F.f0.y * 0.5 - d.y);   // screen pt, y down
}
static float4 toClip(float2 screen, constant LMFrame &F) {
    return float4(screen.x / F.f0.x * 2.0 - 1.0, 1.0 - screen.y / F.f0.y * 2.0, 0.0, 1.0);
}
/// World → screen scale of an orb (the scene's applyOrbScales: zoom ramp × the annulus bump off the orb's HOME distance
/// to the viewport centre), so the orb's on-screen radius is radius × this.
static float orbWorldToScreen(float2 home, constant LMFrame &F) {
    float screenDist = length(home - F.f0.zw) / max(F.f1.x, 0.0001);
    float t = min(screenDist / max(F.f2.y, 1.0), 1.0);
    float falloff = 1.0 - t * t * (3.0 - 2.0 * t);
    float amp = 1.0 + F.f2.x * falloff * F.f1.w;
    return F.f1.z * amp / max(F.f1.x, 0.0001);
}
static float median3(float3 m) { return max(min(m.r, m.g), min(max(m.r, m.g), m.b)); }

// MARK: ground

struct GroundOut { float4 pos [[position]]; };
vertex GroundOut lm_ground_v(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    GroundOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}
static float levelOpacity(float screenPeriod, float targetPx) {
    float t = log2(screenPeriod / targetPx);
    return clamp(1.0 - abs(t) * 0.3, 0.0, 1.0);
}
fragment float4 lm_ground_f(GroundOut in [[stage_in]], constant LMFrame &F [[buffer(0)]]) {
    // BackgroundGridNode's dot lattice (warp mode 0: the Gravity wells are not ported), three nested levels.
    float2 pt = in.pos.xy / F.f1.y;
    float2 screenOffset = float2(pt.x - F.f0.x * 0.5, F.f0.y * 0.5 - pt.y);
    float cs = F.f1.x;
    float2 worldPos = F.f0.zw + screenOffset * cs;
    float baseR = F.f6.w * cs, feather = 0.75 * cs;
    float p1 = F.f7.x, p0 = p1 / F.f7.y, p2 = p1 * F.f7.y;
    float a0 = levelOpacity(p0 / cs, 60.0), a1 = levelOpacity(p1 / cs, 60.0), a2 = levelOpacity(p2 / cs, 60.0);
    float d0 = length(worldPos - (floor(worldPos / p0) + 0.5) * p0) - baseR;
    float d1 = length(worldPos - (floor(worldPos / p1) + 0.5) * p1) - baseR;
    float d2 = length(worldPos - (floor(worldPos / p2) + 0.5) * p2) - baseR;
    float c0 = (1.0 - smoothstep(0.0, feather, d0)) * a0 * step(2.5, F.f7.z);
    float c1 = (1.0 - smoothstep(0.0, feather, d1)) * a1;
    float c2 = (1.0 - smoothstep(0.0, feather, d2)) * a2 * step(1.5, F.f7.z);
    float alpha = clamp(max(c1, max(c0, c2)) * F.f5.w, 0.0, 1.0);
    return float4(F.f5.rgb * (1.0 - alpha) + F.f6.rgb * alpha, 1.0);
}

// MARK: orbs (+ the hover ring)

struct OrbOut {
    float4 pos [[position]];
    float2 lp;      // pt from the orb's centre
    float r;           // on-screen radius (pt)
    float4 fill;
    float hovered;
};
vertex OrbOut lm_orb_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant LMFrame &F [[buffer(0)]],
                       const device LMOrb *orbs [[buffer(1)]]) {
    LMOrb o = orbs[iid];
    float w2s = orbWorldToScreen(o.o0.xy, F);
    float r = o.o0.z * w2s;
    float ext = r + (F.f3.z > 0.5 ? 1.0 : 8.0);
    float2 c = toScreen(o.o0.xy, F);
    float2 lp = kCorner[vid] * ext;
    OrbOut out;
    out.pos = toClip(c + lp, F);
    out.lp = lp; out.r = r; out.fill = o.fill;
    out.hovered = (int(F.f3.y) == int(iid)) ? 1.0 : 0.0;
    return out;
}
fragment float4 lm_orb_f(OrbOut in [[stage_in]], constant LMFrame &F [[buffer(0)]]) {
    float d = length(in.lp);
    float aa = 1.0 / F.f1.y;                       // one pixel, in pt
    float disc = 1.0 - smoothstep(in.r - aa, in.r, d);
    float a = disc * in.fill.a * F.f3.x;
    float4 c = float4(in.fill.rgb * a, a);         // premultiplied
    if (in.hovered > 0.5) {                        // the scene's hover ring: radius + 4 pt, 2 pt wide
        float rr = in.r + 4.0;
        float ring = smoothstep(rr - 1.0 - aa, rr - 1.0, d) - smoothstep(rr + 1.0, rr + 1.0 + aa, d);
        float ra = clamp(ring, 0.0, 1.0) * F.ring.a;
        c = float4(F.ring.rgb * ra, ra) + c * (1.0 - ra);
    }
    return c;
}

// MARK: titles (MSDF glyphs, one instanced draw)

struct GlyphOut {
    float4 pos [[position]];
    float2 uv;
    float4 ink;
    float pxRange;
    float alpha;
};
vertex GlyphOut lm_title_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant LMFrame &F [[buffer(0)]],
                           const device LMOrb *orbs [[buffer(1)]], const device LMGlyph *glyphs [[buffer(2)]]) {
    LMGlyph g = glyphs[iid];
    LMOrb o = orbs[int(g.g3.x)];
    float w2s = orbWorldToScreen(o.o0.xy, F);
    float onScreen = o.o0.z * 2.0 * w2s;
    float lodFade = smoothstep(F.f2.z, F.f2.w, onScreen);
    float2 corner = (kCorner[vid] + 1.0) * 0.5;    // 0…1
    float2 p = g.plane.xy + corner * g.plane.zw;   // pt, y up, at scale 1
    float2 c = toScreen(o.o0.xy, F);
    GlyphOut out;
    out.pos = lodFade > 0.0 ? toClip(c + float2(p.x, -p.y) * w2s, F) : float4(-2.0, -2.0, 0.0, 1.0);
    out.uv = g.uv.xy + float2(corner.x, 1.0 - corner.y) * g.uv.zw;
    out.ink = g.ink;
    out.pxRange = max(1.0, F.f10.x * g.g3.y * w2s * F.f1.y / F.f10.y);
    out.alpha = lodFade;
    return out;
}
fragment float4 lm_glyph_f(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float sd = median3(atlas.sample(s, in.uv).rgb);
    float opacity = clamp(in.pxRange * (sd - 0.5) + 0.5, 0.0, 1.0);
    float a = in.ink.a * opacity * in.alpha;
    return float4(in.ink.rgb * a, a);
}

// MARK: region pills (flat tinted capsules: the blur is cut for today) and their text

struct PillOut {
    float4 pos [[position]];
    float2 lp;
    float2 hs;
    float4 stroke;
    float alpha;
};
vertex PillOut lm_pill_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant LMFrame &F [[buffer(0)]],
                         const device LMLabel *labels [[buffer(1)]], const device float *declutter [[buffer(2)]]) {
    LMLabel l = labels[iid];
    float2 c = toScreen(l.l0.xy, F);
    float2 hs = l.l0.zw * 0.5;
    float2 lp = kCorner[vid] * (hs + 2.0);
    PillOut out;
    float a = declutter[iid] * F.f8.x;
    out.pos = a > 0.001 ? toClip(c + lp, F) : float4(-2.0, -2.0, 0.0, 1.0);
    out.lp = lp; out.hs = hs; out.stroke = l.stroke; out.alpha = a;
    return out;
}
fragment float4 lm_pill_f(PillOut in [[stage_in]], constant LMFrame &F [[buffer(0)]]) {
    float r = in.hs.y;
    float2 q = abs(in.lp) - in.hs + r;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;   // capsule distance (pt)
    float aa = 1.0 / F.f1.y;
    float inside = 1.0 - smoothstep(-aa, 0.0, d);
    float strokeK = clamp(1.0 - smoothstep(0.0, aa, abs(d + 0.75) - 0.75), 0.0, 1.0);   // 1.5 pt, inside the edge
    float fa = inside * F.pillFill.a;
    float4 c = float4(F.pillFill.rgb * fa, fa);
    float sa = strokeK * in.stroke.a;
    c = float4(in.stroke.rgb * sa, sa) + c * (1.0 - sa);
    return c * in.alpha;
}
vertex GlyphOut lm_pilltext_v(uint vid [[vertex_id]], uint iid [[instance_id]], constant LMFrame &F [[buffer(0)]],
                              const device LMLabel *labels [[buffer(1)]], const device float *declutter [[buffer(2)]],
                              const device LMGlyph *glyphs [[buffer(3)]]) {
    LMGlyph g = glyphs[iid];
    int li = int(g.g3.x);
    float a = declutter[li] * F.f7.w;
    float2 c = toScreen(labels[li].l0.xy, F);
    float2 corner = (kCorner[vid] + 1.0) * 0.5;
    float2 p = g.plane.xy + corner * g.plane.zw;
    GlyphOut out;
    out.pos = a > 0.001 ? toClip(c + float2(p.x, -p.y), F) : float4(-2.0, -2.0, 0.0, 1.0);
    out.uv = g.uv.xy + float2(corner.x, 1.0 - corner.y) * g.uv.zw;
    out.ink = float4(F.f8.yzw, 1.0);
    out.pxRange = max(1.0, F.f10.x * g.g3.y * F.f1.y / F.f10.y);
    out.alpha = a;
    return out;
}

// MARK: the pill blur (leftover a): dual Kawase on a half-resolution (quarter-area) copy of the pass, sampled by the pills

struct BlurOut { float4 pos [[position]]; float2 uv; };
vertex BlurOut lm_blur_v(uint vid [[vertex_id]]) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    BlurOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o;
}
fragment float4 lm_kawase_down_f(BlurOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2 &h [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float4 c = src.sample(s, uv) * 4.0;
    c += src.sample(s, uv - h); c += src.sample(s, uv + h);
    c += src.sample(s, uv + float2(h.x, -h.y)); c += src.sample(s, uv - float2(h.x, -h.y));
    return c / 8.0;
}
fragment float4 lm_kawase_up_f(BlurOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2 &h [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float4 c = src.sample(s, uv + float2(-h.x * 2.0, 0.0));
    c += src.sample(s, uv + float2(-h.x, h.y)) * 2.0;
    c += src.sample(s, uv + float2(0.0, h.y * 2.0));
    c += src.sample(s, uv + float2(h.x, h.y)) * 2.0;
    c += src.sample(s, uv + float2(h.x * 2.0, 0.0));
    c += src.sample(s, uv + float2(h.x, -h.y)) * 2.0;
    c += src.sample(s, uv + float2(0.0, -h.y * 2.0));
    c += src.sample(s, uv + float2(-h.x, -h.y)) * 2.0;
    return c / 12.0;
}
/// The capsule over the blurred copy: blur, then the tint (the flat pill's fill at 0.55 of its alpha), then the stroke.
fragment float4 lm_pillblur_f(PillOut in [[stage_in]], constant LMFrame &F [[buffer(0)]], texture2d<float> blur [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float r = in.hs.y;
    float2 q = abs(in.lp) - in.hs + r;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    float aa = 1.0 / F.f1.y;
    float inside = 1.0 - smoothstep(-aa, 0.0, d);
    float strokeK = clamp(1.0 - smoothstep(0.0, aa, abs(d + 0.75) - 0.75), 0.0, 1.0);
    float2 uv = in.pos.xy / (F.f0.xy * F.f1.y);
    float3 b = blur.sample(s, uv).rgb;
    float t = F.pillFill.a * 0.55;
    float3 fill = b * (1.0 - t) + F.pillFill.rgb * t;
    float4 c = float4(fill * inside, inside);
    float sa = strokeK * in.stroke.a;
    c = float4(in.stroke.rgb * sa, sa) + c * (1.0 - sa);
    return c * in.alpha;
}
