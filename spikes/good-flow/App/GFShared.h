// Good Flow spike (throwaway, never merged) · the uniforms shared by GoodFlow.metal and Swift.
// One field per bench uniform the Flow path reads (`u` prefix dropped). simd types so C and MSL agree on layout.
#ifndef GFShared_h
#define GFShared_h

#include <simd/simd.h>

typedef struct {
    // slot geometry (pixels)
    simd_float2 res;        // uRes: the slot's size in pixels
    simd_float2 org;        // the slot's top-left corner in the render target (Metal, y down). The bench's uOrg is
                            // GL bottom-left; the port flips y inside the slot instead (see main).
    simd_float2 ctr;        // uCtr (GL convention, y up)
    simd_float2 fade;       // uFade
    simd_float2 fadeV;      // uFadeV
    simd_float2 tankH;      // uTankH
    simd_float2 grid;       // uGrid (always 1,1 here)
    simd_float3 back;       // uBack (linear)
    simd_float3 surf;       // uSurf (linear)
    float zoom, maskR, maskR2, rot;
    float glassAmt, medium, tdrift, flute, pt, fadeB, lens;
    float time, liveT;
    // entry
    float hue, mass, parts, conn, tempo, amp, patina, seed;
    // look dials the Flow path reads
    float soft, rim, fringe, spread, grain, light, power, size, lsoft, bodyl, gmix, contrast, sat;
    float stir, detail, stretch, lines, lineop, fsoft, flow;
    // ints
    int slot, mask, tank, glass, theme, shape, ground, look, fall, lblend, live, sheet;
    int grainOn;            // spike switch, not the bench's: 1 = the faithful final grain term; 0 = baked without it
    int flat;               // spike switch: 1 = the flat control (writes pow(surf, 1/2.2), no shader work)
    // Step 3B, the two-pass variants (B, BD75, BD50). Faithful A leaves these at fwScale 1, r1 unused.
    float fwScale;          // flowBody's fwidth(v) × this: 1 in A and pass 2; s in pass 1 (a pass-1 texel is 1/s slot pixels)
    simd_float4 r1;         // pass-1 picture: (x0, y1, s, 0) — its left and top edge in the slot's y-up fc pixels, and its scale
    simd_float2 r1Size;     // pass-1 picture size in texels
    // Round 2 (outcome 5): the POOL TABLE. hash11 only places and sizes the six pools, from the entry's seed; the values
    // are worked out once on the CPU (or are the bench's own, look.json "pools") and passed in, so every GPU draws the
    // same entry the same way. pool[i] = (centre-x hash, centre-y hash, radius hash, unused). poolTable 0 = hash11 here.
    simd_float4 pool[6];
    int poolTable;
    int deepAlways;         // round 2 (outcome 1, the dark cast): 1 = the deep pool's tint (deepC) is set whatever the
                            // pool's reach; 0 = the bench's (set only where gsA[0] > 0, a hard edge in dark at large scale)
} GFUniforms;

/// The Map pass (case c): one instance per orb, drawn as a quad over the orb's baked still (texture array slice).
typedef struct {
    simd_float2 center;     // world points (y up)
    float diam;             // the orb's diameter D (pt)
    float halfSize;         // the quad's half size (pt): the still covers the centre 1.25 D of the bench's 1.5 D slot
    simd_float3 flatCol;    // gamma-encoded flat disc colour (the entry's hue) until the still lands
    float patina;           // the grain's per-entry amplitude (bench: 1 + .8 patina)
    float ready;            // 1 = sample the still; 0 = the flat disc
    float slice;            // texture array slice
    float uvScale;          // the still's used part of the slice (1 = all of it)
    float pad;
    simd_float3 regionCol;  // round 2 (outcome 2): the plain orb's colour, by REGION (gamma-encoded)
} GFOrbInstance;

typedef struct {
    simd_float2 cam;        // camera centre (world pt, y up)
    float camScale;         // world pt per screen pt (larger = zoomed out)
    float pxPerPt;          // drawable pixels per point
    simd_float2 viewPt;     // view size (pt)
    simd_float3 ground;     // gamma-encoded page colour (the bench's page)
    float grain;            // the look's grain dial
    float time;             // grain clock (fixed at rest: the Map has no live clock)
    int grainOn;            // grain at screen scale (design §1 departure); 0 = none
    int flat;               // flat control: every orb a flat disc
    float pad2;
    // Round 2 (outcome 2): Good Flow REVEALED, not everywhere. An orb shows its still only when its on-screen diameter is
    // ≥ revealSize AND its centre is inside the annulus (screen distance from the view's centre ≤ revealR); otherwise a
    // plain disc in its region's colour. revealSoft = the blend band, a fraction of each threshold. revealOn 0 = all Good Flow.
    int revealOn;
    float revealSize;       // screen pt
    float revealR;          // screen pt
    float revealSoft;
} GFMapUniforms;

#endif
