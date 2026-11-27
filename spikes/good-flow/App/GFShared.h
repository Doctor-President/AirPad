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
} GFUniforms;

#endif
