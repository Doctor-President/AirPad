# Good Flow spike · step 3B results (Mac, screen locked)

_CC (Opus builder), 2026-11-27 02:00–02:40, branch `ws-good-flow-spike`. Everything below is offscreen or
command-buffer work, valid with the Mac's screen locked: GPU ms per command buffer, fill times, texture bytes,
phys_footprint, pixels read back from textures, link-driven rest/live counts. **No cadence and no presentation numbers
here**: with the screen locked `presentedTime` is 0 and `nextDrawable` stalls (it is split out of main-thread time
below). Synthetic entries only (look.json e0–e5 + 256 generated, `GFLibrary`). M1 Max, on the adapter, Release build.
Nothing else heavy ran during the measured passes (the reference harness and the builds ran between them, not
beside them)._

## 0. Headlines

1. **The faithful port is 6–7× cheaper than part A measured.** Part A's build compiled the shader with
   `MTL_FAST_MATH = NO`, which also makes every `pow` / `exp` / `sin` the *precise* library version. Safe maths with the
   fast fp32 functions (`-fmetal-math-mode=safe -fmetal-math-fp32-functions=fast`, which is also what Chrome ran the
   bench with) gives the same picture and: detail-mac 23.0 → **3.7 ms**, card-iphone 21.4 → **3.6**, detail-iphone
   13.2 → **2.3**, card-mac 4.5 → **0.8**, orbs 1.0–4.3 → **0.2–0.7** (GPU ms per still, sustained clock).
2. **Equality (the stable hash): port = bench, 120/120 stills, worst mean 0.029, worst p99 1.0** (8-bit steps).
   The stable hash is hash11's argument snapped to 1/1024 **and** `metal::fast::sin` (the sin the bench actually ran
   on). Controls: stable bench vs a second run of itself 120/120 at 0.000; vs the stable bench with fringe 0: fails
   110/120 (passes 10, the same weak spot part A found: where the fringe only touches the image zone).
3. **Every cheaper variant is "near" A** (B 120/120, BD75 120/120, BD50 118/120; worst mean 1.5, worst p99 22 on two
   60 pt orb stills at 2×). The edge bend works in pass 2 unchanged (§2).
4. **Live at 30/s, paced like a live surface (GPU clocks low):** card-mac A 1.6 / 2.5 ms p50 / p95 (passes 4.0);
   the Mac's full-width detail image A 6.0 / 8.8 ms (fails), **BD50 2.2 / 2.3 ms (passes)**.
5. **Map: cap 128 is the only cap whose 262 mipmapped stills fit both memory bars** (24.8 MB of textures, footprint
   +32 MB). Apple's GPU pads a mipmapped slice of 129–192 px to 258 KB and 193–256 px to 354 KB, so 160 and 192 cost
   what 256 costs (§5). Fill: visible orbs in 39–93 ms, all 262 in 0.19–0.27 s.
6. **Still ↔ live: 0.0000 mean difference**, entering and leaving live, every variant, three surfaces; and in the app
   itself (hovered card 3: first live frame vs its still, 0.0000).
7. **Process CPU with one live surface at 30/s reads +5.4 points above the still (locked screen), and the FLAT live
   arm reads +4.1:** the cost is the loop, not the look. Over the design's ≤ 3-point bar; re-read on the unlocked Mac
   before anyone believes it (a locked screen makes `nextDrawable` time out; §7).

## 1. Equality: the stable-hash port against the stable-hash bench

Reference: `reference/run.mjs` with `HASH=stable` (new env switch: hash11's argument through `roundEven(n·1024)/1024`,
the GLSL twin of Metal's `rint`), headless Chrome, ANGLE on Metal (M1 Max), `build/reference-stable/`.
Port: `-RenderStills` (A, stable hash, the app's default), read back from the texture, `build/port-A-stable/`.

| case | theme | n | mean (avg) | mean (worst) | p99 (worst) | max | pass |
|---|---|---|---|---|---|---|---|
| card-iphone | light / dark | 6 / 6 | 0.000 | 0.000 | 0.0 | 1 | 12/12 |
| card-mac | light / dark | 6 / 6 | 0.000 | 0.000 | 0.0 | 1 | 12/12 |
| detail-iphone | light / dark | 6 / 6 | 0.000 | 0.001 | 0.0 | 1 | 12/12 |
| detail-mac | light / dark | 6 / 6 | 0.000 | 0.000 | 0.0 | 149 | 12/12 |
| orbs (6 sizes) | light / dark | 72 | ≤ 0.029 | 0.029 | 1.0 | 8 | 72/72 |

**120/120 pass** (bar mean ≤ 1.0, p99 ≤ 8); uniforms: 120 stills checked against the reference manifest, 0
differences. Full table: `build/port-A-stable-vs-reference-stable.md`; diff sheet `build/compare-sheet-stable.png`.

What made it pass (each tried, numbers in the run log):
- part A's port with the snap but precise maths: 0/120 against Chrome (Chrome is fast-maths: its `sin` differs at
  hash11's large arguments by enough to move pools);
- the snap + `fast::sin` + safe maths elsewhere: 120/120 (above). The app's default is now exactly this.
- the unsnapped sin hash in any of our compiles: 0–2/120 against the original bench reference (FMA contraction moves
  the argument). The **bench hash** switch keeps that hash: it does NOT reproduce the arrangement Chrome draws.

## 2. The cheaper routes (design §2 B + D as one knob)

`GFDraw.encode` is the one draw path for every still and every live frame (so a still and its live surface share the
variant and hash by construction). Variants:
- **A**: the faithful one pass (body three times per pixel).
- **B**: pass 1 (`gf_body`) draws the composed body once per texel into an offscreen picture, linear, `rgba16Float`
  (colour + coverage) + `r16Float` (rim glow), covering every point the three taps can reach (the slot scaled by
  1 ± fr about the field's centre, + 2 texels); pass 2 (`gf_fringe`) at full size takes R / G / B with bilinear taps at
  p·(1−fr), p, p·(1+fr), composes over the ground (exactly as A: per-channel `compose`, glow × the cell fade), then
  A's own `finish()` (gamma, fades, glass, lens rim light, grain, mask). At s = 1 the picture's texel centres sit on
  slot pixel centres, so the G channel is exact.
- **BD75 / BD50**: the same with pass 1 at 0.75 / 0.5 × the slot's pixels; `fwidth` in pass 1 is scaled by s so the
  contour lines keep their screen-pixel width.
- **Edge bend:** yes, in pass 2. The bend only moves p before the body is looked up; the body is a function of p
  (plus the edge stipple), so pass 2 moves p exactly as A does and samples pass 1 there. The bend pulls p inward, so
  the lookup never leaves the picture. (The glass flutes, `glass 2`, also move p; covered by an extra margin; not a
  spike switch.) Departure that remains: the edge stipple (`gNz`) is per pass-1 texel, so R and B get the stipple of a
  neighbouring texel (the faint colour speckle design §2 predicted) and at BD it is coarser.

### Equality of each variant against A (stable hash)

| variant | worst case | mean (avg) | mean (worst) | p99 (worst) | near (mean ≤ 2.0, p99 ≤ 16) |
|---|---|---|---|---|---|
| B | detail-mac | 0.189 | 1.111 | 8.0 | **120/120** (passes even A's own bar) |
| BD75 | detail-mac | 0.284 | 1.376 | 13.0 | **120/120** |
| BD50 | orb-60-@2 | 0.405 | 1.505 | 22.0 | **118/120** (two 60 pt orbs at 2×, p99 22) |

Per case: `build/results-3b-tables.md`.

### GPU ms per frame, per case, per variant

**Sustained clock** (10 draws committed back to back, span / 10; the GPU at speed, as while panning):

| case | px | A | B | BD75 | BD50 |
|---|---|---|---|---|---|
| detail-iphone | 1320×786 | 2.19 | 1.07 | 0.76 | 0.61 |
| detail-mac | 3456×504 | 3.65 | 1.85 | 1.26 | 0.86 |
| card-iphone | 1044×1596 | 3.49 | 1.75 | 1.20 | 0.83 |
| card-mac | 456×640 | 0.68 | 0.38 | 0.27 | 0.22 |
| orbs | 180²–540² | 0.17–0.65 | 0.11–0.34 | 0.16–0.46 | 0.18–0.31 |

**Sequential** (one command buffer, waited, 10 frames × 6 entries × 2 themes; p50 / p95):

| case | A | B | BD75 | BD50 |
|---|---|---|---|---|
| detail-iphone | 2.27 / 4.17 | 1.09 / 1.62 | 0.77 / 0.96 | 0.66 / 1.06 |
| detail-mac | 3.69 / 5.69 | 1.73 / 2.38 | 1.23 / 3.24 | 0.94 / 1.68 |
| card-iphone | 3.62 / 5.59 | 1.70 / 3.90 | 1.21 / 3.15 | 0.86 / 0.98 |
| card-mac | 0.79 / 0.99 | 0.40 / 0.42 | 0.28 / 0.31 | 0.24 / 0.28 |
| orbs | 0.23–0.73 / ≤ 0.98 | 0.15–0.36 / ≤ 0.45 | 0.17–0.46 / ≤ 0.76 | 0.16–0.32 / ≤ 1.21 |

**Paced like a live surface** (one frame every 1/30 s for 3 s, not waited; the GPU clocks down between frames, so each
frame takes longer: these are the live rows' conditions; p50 / p95, light):

| case | A @30 | B @30 | BD75 @30 | BD50 @30 | A @60 | BD50 @60 |
|---|---|---|---|---|---|---|
| detail-iphone | 5.21 / 10.08 | 2.29 / 3.62 | 2.51 / 2.53 | 1.27 / 1.87 | 6.28 / 12.79 | 1.70 / 3.43 |
| detail-mac | 7.46 / 10.39 | 5.01 / 5.44 | 5.50 / 8.67 | 2.20 / 3.08 | 9.00 / 15.28 | 2.57 / 5.07 |
| card-iphone | 8.75 / 10.58 | 2.86 / 5.60 | 2.40 / 3.93 | 2.68 / 9.09 | 7.04 / 8.36 | 2.22 / 3.72 |
| card-mac | 1.55 / 2.54 | 0.79 / 1.30 | 0.79 / 0.92 | 0.45 / 0.75 | 1.54 / 2.56 | 1.91 / 6.86 |

(Dark: same order; all rows in `build/m3b/measure.json` → `paced`. The paced p95 is noisy at these low loads: DVFS.)

**In the app's own live surfaces** (recorder, GPU per drawn frame, live 30, the window at its default size, locked):

| surface | variant | GPU p50 / p95 ms | bar (Mac) |
|---|---|---|---|
| detail band (window width × 252) | A | 6.03 / 8.83 | 4.0 — **fails** |
| detail band | BD50 | 2.23 / 2.28 | passes |
| detail band | A @60 | 6.08 / 8.40 | fails |
| hovered card 228 × 320 | A | 2.40 / 2.91 | passes |
| hovered card | BD50 | 0.73 / 2.32 | passes |
| hovered card, flat control | — | 0.08 / 0.09 | — |

Reading: on the Mac the hovered card passes the live GPU bar as dialled (A). The detail image at the Mac's full width
needs BD50 (or B at 30, borderline). The iPhone's numbers will differ (a 17 Pro Max GPU at 3×); the phone runs measure it.

### One still (fill cost; light, e0–e5)

| case | A GPU p50 / max | B | BD75 | BD50 | encode (CPU) |
|---|---|---|---|---|---|
| detail-iphone | 3.04 / 7.26 | 1.39 | 1.62 | 0.90 | 0.04–0.13 ms |
| detail-mac | 4.53 / 7.63 | 1.70 | 1.24 | 0.83 | |
| card-iphone | 3.65 / 5.62 | 1.67 | 1.23 | 0.82 | |
| card-mac | 0.76 / 0.79 | 0.39 | 0.28 | 0.24 | |
| orb at its master | 0.37–0.50 per orb in the fill | | | | |

Design bars (Mac): orb ≤ 1.0 ms — passes; card or detail ≤ 4.0 — passes except detail-mac A at 4.5 (one still, drawn
once). Main thread per still ≤ 0.5 ms: the card cache encodes on its fill queue (0.16 ms p50 there) and the main
thread only assigns the IOSurface to the layer.

### The switches' cost (GPU ms per frame p50, e0–e2, light, sequential)

| variant | case | glass + bend (bench defaults) | glass off | bend off | both off |
|---|---|---|---|---|---|
| A | detail-iphone | 2.13 | 2.02 | 2.07 | 2.00 |
| A | detail-mac | 3.38 | 3.26 | 3.49 | 3.23 |
| A | card-iphone | 3.32 | 3.21 | 3.32 | 3.16 |
| A | card-mac | 0.74 | 0.72 | 0.72 | 0.70 |
| BD50 | detail-iphone | 0.54 | 0.48 | 0.52 | 0.45 |
| BD50 | detail-mac | 0.81 | 0.70 | 0.78 | 0.78 |

The glass and the edge bend together cost about 3–6 % of a frame (0.04–0.15 ms); within the noise of one run.

## 3. Case (a), the detail image

Built: `GFDetail.swift`. iPhone band = width × (200 + safe-area top), Mac = window width × (200 + top inset); square
corners, foot fade (uFadeB 0.24) into the page; synthetic placeholder paragraphs; the band scrolls with the page;
scrolling is an input wake (the band draws at the display's rate while the page moves, its live clock running); at
rest only the live clock draws; off screen the clock stops. Mac switch **Detail fit: Bench (short side) | Width**
(sheet option 2). The bench fit is centred on the band, which in this spike is the document column (no Librarian
column); amend b's side fades are the field's own (it ends inside the band at the bench's scale), no extra fade term.

## 4. Case (b), cards

Built: `GFCards.swift`. Real `UICollectionView`. Mac grid 228 × 320 pt, spacing 10, corners 14, image zone 43 %,
synthetic titles below; iPhone carousel 0.79 × width (348 × 532 at 440), corners 30, zone 40 %, snapping one card.
Stills: drawn by GFDraw into an **IOSurface the cell's layer shows directly** (no copy, no CGImage), visible first
(nearest the centre), then one screen each way, the rest evicted; flat hue fill until the still lands. The **hovered
card (Mac) / centred card (iPhone)** gets its own card-sized LiveSurfaceView over the still, from the still's time;
leaving, the surface stays on screen until the still redrawn at the last live frame's time lands, then goes.

| row | number | bar |
|---|---|---|
| visible cards filled (default window, 30 cards) | 30–43 ms | — |
| card still GPU in the fill | 1.19 p50, 3.14 max ms | ≤ 4.0 |
| first live frame vs still (in-app, hovered card 3, A and BD50) | **0.0000** mean, max 0 | ≤ 1/255 |
| bytes per card still | Mac 1.17 MB (456 × 640); iPhone 6.44 MB (1044 × 1596) | — |
| kept, visible + one screen each way, 1728 × 1028 (7 columns) | 77 cards = **90 MB** | ≤ 40 — **fails** |
| same, 1703 × 924 (6 columns) | 60 cards = 70 MB | fails |
| iPhone carousel | 5 cards = 32 MB | passes |
| what the 40 MB budget keeps at 1728 × 1028 | the visible cards only (35 = 41 MB; the budget never drops a visible card) | |

So the Mac grid's still memory misses the bar at full screen even with nothing ahead: full-resolution card stills are
1.17 MB each and 35 are on screen. Options for 2c: keep only the image zone (top 43 % + the fade: ~0.5 MB each, the
card's text area is flat card colour apart from glass / bend / grain), a 16-bit still format, or a looser bar.
`-CardsBudgetMB N` (0 = none) is the knob; default 40.

## 5. Case (c), the Map

Built: `GFMap.swift`. 262 synthetic orbs (60 pt + 8 per further item, 120 max: 125 at 60 pt, a tail of 120 pt;
8 loose clusters, no overlap, gap 0.15 × the larger D + 6 pt; e0–e5 among them). One CAMetalLayer view on the trial's
pattern (two-finger scroll pans ×1.5, a drag pans 1:1, magnify / pinch zooms about the pointer, coast after scroll end,
pending input applied only in the tick; at rest 0 ticks). Each orb is a still of the bench's orb (uTheme 0, 1.5 D slot,
mass 1, zoom = fit) **baked without the final grain**, cropped to the centre 1.25 D, master = min(1.25 D × scale, cap)
in 16 px steps, mipmapped, one texture array per size; drawn as instanced quads; **grain added in the Map pass per
screen pixel** with the bench's own formula. **Compositing:** the still is opaque (the orb on the page colour); its
quad is laid over the ground with alpha 1 out to 0.52 D (the disc, its soft edge and nearly all the rim glow) falling
to 0 by 0.62 D, so neighbours' padding never covers an orb; the glow's last faint tail beyond 0.52 D is dropped
(the rim dial is 0.06: about 1–2 % of the ground's value).

### Memory and fill per cap (A, stable hash, light; texture bytes = Metal `allocatedSize`; footprint = phys_footprint Δ)

| scale | cap | texture MB | footprint Δ MB | buckets (master px × orbs) | visible orbs | visible filled | all filled | batch GPU ms p50 / p95 / max |
|---|---|---|---|---|---|---|---|---|
| Mac 2× | **128** | **24.8** | 32.0 | 128 × 262 | 55 | 63 ms | 253 ms | 1.80 / 6.88 / 10.4 |
| Mac 2× | 160 | 66.2 | 68.8 | 160 × 262 | 55 | 79 ms | 264 ms | 1.76 / 7.29 / 16.4 |
| Mac 2× | 192 | 66.2 | 76.5 | 160 × 125, 176 × 44, 192 × 93 | 55 | 75 ms | 193 ms | 1.66 / 7.22 / 20.5 |
| Mac 2× | 256 | 72.9 | 78.7 | 160…256 (6 buckets) | 55 | 87 ms | 231 ms | 1.73 / 7.10 / 18.1 |
| iPhone 3× | **128** | **24.8** | 31.5 | 128 × 262 | 34 | 39 ms | 258 ms | 1.72 / 7.22 / 9.8 |
| iPhone 3× | 160 | 66.2 | 72.8 | 160 × 262 | 34 | 58 ms | 257 ms | |
| iPhone 3× | 192 | 66.2 | 85.1 | 192 × 262 | 34 | 50 ms | 197 ms | |
| iPhone 3× | 256 | 90.8 | 100.9 | 240 × 125, 256 × 137 | 34 | 70 ms | 202 ms | |
| Mac 2× | none | 82.6 | — | 160…304 (8 buckets) | — | — | 169 ms | |

(iPhone rows are the phone's sizes measured on the Mac's GPU; the phone's own footprint comes from the phone run.)

**Why 160 and 192 cost what 256 costs:** Metal on this GPU allocates a mipmapped 2D / array slice at 96 KB for
≤ 128 px, **258 KB for 129–192 px** and 354 KB for 193–256 px (measured directly: `allocatedSize` per slice; a single
2D texture is the same; without mips 129–192 px is 146 KB). So the memory steps are power-of-two-ish, not by area.

**Cap chosen: 128** (the app's default; the panel's "Map master" switch and `-MapCap 256` show 256). It is the only
cap that meets ≤ 64 MB (Mac) and ≤ 48 MB (iPhone). Next options, priced not built: 192 without mips (146 KB × 262 =
37 MB) plus a small mipmapped 96 px copy for zoomed-out views (~48 KB each, ~13 MB) ≈ 50 MB on the Mac.

**Sharpness at zoom 1, by eye** (`build/map-sharpness-<theme>.png`, 100 % crops of the same orbs, 2×: full | 256 |
192 | 128): 256 and 192 are indistinguishable from full at 100 %; at 128 the contour lines and the edge stipple are
slightly softer on the 90–120 pt orbs (a 128 px master shown over up to 300 px); colour, shape and fringe unchanged.

**First fill (bars: visible ≤ 0.5 s Mac / ≤ 1.0 s iPhone; all ≤ 1.5 s / ≤ 3 s):** passes with a wide margin at every
cap. Fill runs on its own queue, visible orbs first (nearest the centre), each orb a flat disc in its hue until its
still lands; each batch (targeted at ~2 ms of GPU) is followed by one Map frame. **The batch GPU p95 is 6.6–7.3 ms and
the max 10–20 ms, over the design's "≤ 2.0 ms a frame" refill budget**: the batching guesses from the previous batch's
per-orb time and the first batches carry pipeline warm-up. Whether a batch costs a vsync is a cadence question (the
unlocked run reads it: `stills while moving · fill`, and the Map frames' gaps during the first second).

In-app (Map case, locked, cap 128): visible 52 orbs filled in 86–91 ms, all 262 in 188–195 ms; after the fill **0
ticks, 0 frames, CPU 0.02–0.07 %**.

## 6. Rest and live behaviour (in the app, locked screen; recordings in `build/headless/`, `build/bench-mac/`)

| check | result |
|---|---|
| Detail, live 30, no input, 14 s | 423 live frames = **30.0 a second**; main p95 0.61 ms |
| Detail, live 60 | 59.9 a second |
| Detail, live off | **1 frame** (the still), then 0 ticks; CPU 0.06 % |
| Reduce Motion (simulated `-SimReduceMotion`) | 1 frame, 0 live; `liveBlockedBy reduceMotion(sim)` |
| Low Power Mode (simulated `-SimLowPower`) | 1 frame, 0 live |
| Thermal serious (simulated `-SimThermal serious`) | 1 frame, 0 live |
| Cards, nothing hovered | 0 frames; CPU 0.07 % |
| Cards, hovered card 3 for 7 s, then the pointer leaves | live 30.0 a second, then live ended at t = 19.1 (12 + 7.1 s) and the still redrawn at that time; 0 frames after |
| Map after the fill | 0 ticks, 0 frames |
| Bench mode on the Mac (programmatic, 8 s, then 10 s rest) | Map: rest 0 ticks; Cards: rest 0 ticks (the simulated pointer leaves); Detail: rest = live 30 only (291 frames in 10 s) |
| Stills redrawn while moving (bench runs) | **0** (Cards: 63 fill + 15 live-ended redraws while scrolling, as designed) |
| Main thread per frame while moving (bench runs) | p95 6.6–6.9 ms **of which the drawable wait is 6.4–6.7** (a locked-screen stall); without it: Map 0.35, Detail 0.43, hovered card 0.50 ms (bar 2.0) |
| Process CPU, one live surface at 30/s (locked) | detail A 5.5 %, detail BD50 5.9 %, live 60 9.4 %, hovered card 4.2 %, **flat-live card 4.2 %** vs still 0.06 % |

Only simulated: Reduce Motion, Low Power and thermal (the real APIs are read too: `UIAccessibility`, `ProcessInfo`;
on the Mac, Low Power Mode is a real switch T can flip; Reduce Motion is in Accessibility settings; thermal can only
be simulated here). "App inactive / window hidden / view off screen" stop the clock by the notifications part A wired
and the visibility check (seen in the detail bench: the band scrolled off screen, its clock stopped).

## 7. Prepared, not yet measured (the commands)

**Mac, screen unlocked, T away from the Mac (about 40 minutes; holds `caffeinate -di` for its run):**
```
cd ~/Developer/AirPad/.claude/worktrees/ws-good-flow/spikes/good-flow
zsh tools/mac_all.sh            # map / detail / cards × 1728×1028 and 1703×924 × 3 runs (≥ 15 s real trackpad input
                                # each + the 10 s rest row), flat arms beside (a) and (b), live rows (30, 60, off, flat,
                                # BD50/BD75/B), process CPU at rest over 30 s → build/mac-runs/<stamp>-SUMMARY.md
zsh tools/mac_run.sh <case> <tag>   # one run (WIN="1703 924", ARGS="-Variant BD50 -Flat on …")
```
Dry-checked: `mac_run.sh --dry map dry-map` launched the Release app through LaunchServices, saved the recording via
`notifyutil -p com.goodflow.save`, read it back; the real mode was started and confirmed waiting ("locked 1") without
posting anything. Steps files: `tools/steps/{map,detail,cards,cards-live,rest}.steps` (rperf verbs: trackpad with
phases and momentum, pinch, flick, scroll, hover moves). `rperf`/`rclick`/`locked` are compiled from the trial's
`scripts/mac/realclick/`.
Also owed on the Mac: one Metal System Trace per case (design §3 cross-check), and T's own recording (⌃⌥⌘P).

**iPhone (the lead warns T first; refuses otherwise):**
```
zsh tools/run_on_phone.sh <UDID> --i-warned-T --benches "map:light:A,cards:light:A,detail:light:A,detail:light:BD50,map:dark:A" \
    --seconds 240 --cooldown 120 --stills            # + --power for xctrace Power Profiler
```
It builds (Automatic, offline, the existing SpikeHarness profile; no `-allowProvisioningUpdates`), installs Good Flow
(not AirPad), runs each bench (`-Bench <case> -Seconds N -Variant … -Theme …`, programmatic motion labelled as such,
10 s rest, a 1 Hz thermal / footprint / CPU trace), pulls each recording with `devicectl device copy from
--domain-type appDataContainer`, renders the 120 stills on the phone and compares them with the Mac's, and leaves the
app installed. "Record" in the panel records T's own hand.

## 8. App size
Release iOS `GoodFlow.app` on disk: **964 KB** (signed: Apple Development, profile "iOS Team Provisioning Profile:
com.doctorpresident.spike.SpikeHarness", team 8XM4B5F42Y). Mac Catalyst Release builds and runs.

## 9. Departures from the bench, as T would see them
- **Pool arrangement per entry (stable hash).** For the same entry the pools sit where the bench-with-stable-hash
  puts them, not where Chrome's own sin hash put them on T's bench (sheets: column 1 vs 2–3). e0, the entry T
  approved, looks rearranged (same colours, same character, different layout). The "Hash: Bench" switch does not
  bring Chrome's arrangement back either. Fix if wanted: the same snap in the bench artifact makes bench = app exactly.
- **Orb grain** is per screen pixel (static while panning, does not scale with zoom); the bench's is per orb pixel.
- **Orb masters at 128 px** (cap): slightly softer contour lines on the larger orbs at zoom 1; softer still when
  zoomed in past 1 (no refill at a new size in the spike).
- **Variants B / BD:** the edge stipple gets a faint colour speckle; BD50 softens fine contour lines slightly
  (worst mean 1.5 steps, p99 22 on small orbs). Shown beside A on the panel ("Variant").
- **Mac detail band:** bench fit = a small field in the middle of a wide band (sheet option 1); "Width" scales the
  field to the band (option 2). Option 3 not built.
- **Housing dials are the bench defaults** (Clear glass 0.6, edge bend 0.5): said on screen.

## Files
Sheets: `build/side-by-side-light.png`, `build/side-by-side-dark.png` (bench sin hash | bench stable | port A |
BD50, e0–e5, detail-iphone / card-iphone / orb-90@2); `build/map-sharpness-{light,dark}.png`. Data:
`build/m3b/measure.json`, `build/results-3b-tables.md`, `build/headless/`, `build/bench-mac/`.
