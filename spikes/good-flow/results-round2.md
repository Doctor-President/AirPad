# Good Flow spike · round 2 results (amend f)

_CC builder, 2026-11-27/28, branch `ws-good-flow-spike` (scratch, never merged). Mac = M1 Max, Release, Mac Catalyst.
The Mac screen was LOCKED for the whole round: every Mac number here is offscreen / command-buffer or a scripted run
with no presented frames, and says so. No phone was touched; phone commands are in §4. Stills: `results-round2/`._

## 5 · One picture on every chip: the pool table

**What it was.** `hash11` (`fract(sin(n·127.1)·43758.5453)`) is called three times per pool, six pools, from the entry's
seed only: the pools' centres and radii. Its argument reaches ~7 000 radians, so the last bits of the GPU's fast `sin`
(and of how the compiler forms `fi·7.3 + seed·19`) decide where every pool sits. The phone's GPU computes them differently
(round 1: 0/120 phone stills equal to the Mac's).

**What I built.** `GFUniforms.pool[6]` + `poolTable`: the shader reads the 18 values instead of calling hash11
(GoodFlow.metal, flowBody). `GFPools` (Look.swift) fills them on the CPU, once per entry, in `GFUniforms.make` (every still,
live frame and Map orb goes through it). Switch **`-Pools bench|cpu|shader`** (panel row "Pools"), default `bench`:
- `bench`: look.json `entries[].pools` = **the values T's bench itself drew** (e0–e5); the CPU's for every other entry;
- `cpu`: double-precision CPU hash for every entry (what a real build computes for a real entry; same on every device);
- `shader`: round 1's in-shader hash (with `-Hash stable|bench`).

**How the bench's own values were found.** A tiny WebGL page computing hash11 in Chrome (`tools/bench_pools.mjs`) gave
the values Metal's plain fast-maths compile gives (= round 1's `var-fast-fastfn`, 0/120): the context changes how the
argument is formed. So I instrumented **Chrome's own ANGLE translation of the whole bench shader** (`tools/angle_pools.py`:
three device-buffer writes after the three hash11 calls; app `-PoolsFromAngle <dir>`). Drawn by it, the stills still equal
T's bench (36/36 checked: the instrumentation did not change the compile) and the values are the same in every case and
theme. Pools an entry never uses (weight 0) keep the WebGL page's values; they never reach a pixel.

**Result (tools/compare.py, bar mean ≤ 1.0, p99 ≤ 8; Mac offscreen):**

| stills | vs T's bench (`build/reference`) | vs the pinned-hash bench (`reference-stable`) |
|---|---|---|
| port, `-Pools bench` (new default) | **120/120** (worst mean 0.020, p99 1) | 0/120 |
| port, `-Pools shader` (round 1 default, control) | 0/120 | 120/120 |
| port, `-Pools cpu` | 0/120 | 0/120 |
| bench, ANGLE Metal, `POOLS=table` | **120/120** | — |
| bench on **SwiftShader** (a different renderer, CPU), no table | 0/120 | — |
| bench on SwiftShader, `POOLS=table` | **120/120** | — |

- **Which reference it matches now: T's own bench draw** (`build/reference`), not the pinned-hash one. Ruling 4's
  departure ("a different draw from your bench") is gone for e0–e5.
- **Can the bench match it? Yes, and it already does on this Mac** (the values ARE the bench's). On any other renderer
  the bench drifts (SwiftShader: 0/120), and reading the same table (`reference/run.mjs POOLS=table`, a `uPool[6]`
  uniform) brings it back to 120/120. So "re-approve on the bench" is not needed; a bench on another machine needs the table.
- **Not shown here: the phone.** The Simulator draws on the Mac's GPU, so it proves nothing about the A19. Owed: the
  phone `--stills` pass (§4), compared against `build/r2/pools-bench`. Expected: the pools land where the Mac's do; any
  remaining difference is the smooth functions' last bits (should be ≤ 1 step), and if not, that is the finding.
- **For the port:** a real entry has no bench draw, so the real build uses `cpu` (one table per entry, computed once:
  18 CPU sines). Only T's six bench entries get the bench's numbers. The cost in the shader is nil (18 constants replace 18
  `sin`s).

Still: `results-round2/o5-pool-table.png` (detail-iphone e0 / e4 / e5 dark: T's bench, old port, port + table,
SwiftShader bench, SwiftShader + table). Commit: see the round-2 log at the end.

## 3 · Cards: the light-mode grid break

**Plainly: it is the still pipeline (the fill queue's bookkeeping), set off by the spike's grid.** Light had nothing to
do with it: T opened Cards in light (16:05, from Detail, already light since 16:01 by his recording's marks), and his
switch to dark refilled every still, which is why dark was whole a minute later.

**Reproduced** (scripted, screen locked, window 1728 × 1028 Mac pt = 2245 × 1336 UIKit pt since the Catalyst build
is iPad-scaled, light, A; `tools/r2_mac.sh` with `-Script "case:Cards@5,dump:a@6,…"`; dumps = what every visible cell
shows, read from the view tree):
- Detail → Cards, 1 s later: **36 of 36 visible cards show the flat fill; 10 stills kept; 252 items "in flight" for
  ever.** After scrolling: 45 of 45 flat. A theme switch: 0 flat (the cache is cleared). Launching straight into Cards: 0 flat.
- Cause, from the marks: the first `want()` ran while the flow layout still had UIKit's **default 50 × 50 item size**
  (the frame was set before the item size, and its scroll callback asks for stills): "visible 262", so all 262 were
  queued. The next `want()` (real size, 36 visible) rebuilt the queue and **dropped the queued fill jobs but left their
  items marked in flight**, so they were never queued again. Any later `want()` with fills still queued (fast scroll,
  hover churn) strands more. That is a fault a real still cache can have too: **2c's step 1 should carry the rule
  "a dropped job leaves in-flight", with a test that calls want() twice before the queue drains.**
- The collapsed cells ("E…", "1 it…"): **not reproduced by script.** The mechanism is in the code and the 50 × 50 pass
  is now shown: a cell laid out its picture and labels only in configure(), at whatever size it had then; a cell that
  lived through a 50 × 50 pass kept a thumbnail picture and cut titles until reconfigured (a theme switch does that).
  That part is the spike's grid.

**Fixed** (GFCards.swift): the queue is rebuilt in priority order and a dropped job leaves in-flight (a dropped live-end
redraw also removes its live surface); the item size is set before the frame, and no stills are asked for before it is
set; the cell lays itself out on every layout pass; stills are redrawn when the CARD's pixel size changes, not on every
window resize (a Mac card is 228 × 320 at any window size, so the full-screen animation no longer empties the grid).
After: the same script gives **0 flat, 0 in flight**, after the case switch, three scrolls, hovers, a scroll back and
a resize. Still: `results-round2/o3-cards-before-after.png`.

**Still ↔ live jump.** Off screen it is exact: the first live frame vs the still **0.0000 mean, 0 max** (in the app,
`-CheckJump`, card 3, this build), and leaving live the still is redrawn at the last live frame's time value (round
1's offscreen check, 0.0000). **On screen it is unread:** with the screen locked the live layer drew 7 frames in 1.7 s
and presented none, and a window snapshot does not capture a Metal layer. The one way it could still jump: the live
layer is inserted over the still before its first frame is presented (an empty Metal layer for one frame). Owed in the
unlocked run: a screen recording of one hover on and off (`-Script "hover:3@6,hover:off@8"` with `-Case Cards`).

## 1 · Mac detail: the Scale dial, the dark cast, the scrolled band

**Scale dial.** Panel row "Detail scale (Bench 0 → Width 1)", a slider from −0.15 to 1.15; launch argument
**`-DetailZoom <z>`** (script verbs `scale:<s>` / `zoom:<z>`). The field's half-size is `zoom` × half the band's
height: Bench = 1×, Width = band width ÷ band height (9.3× at a 2245 × 241 pt band, 11.2× at T's full-screen 2245 × 200).
The slider is log-spaced, so `s` = ln(zoom) ÷ ln(Width zoom). **On screen, bottom left:** `Scale 0.41 · zoom 2.50×
(Bench 1×, Width 9.32×) · band on · BD50`: T reads **zoom** off (it means the same at any window width; `s` does not).
The field is centred on the document column (= the window's centre here: the spike has no Librarian column). The old
"Detail fit" row stays as two presets. Cost: zoom does not change the work (same pixels), so the BD50 / A numbers of
round 1 hold at every scale.

**The dark cast: it was the deep pool's tint, cut off at the deep pool's reach.** In dark, the paper behind the field
is near-black plus a tint of the entry's hue (`deepC · .35`), and the bench sets `deepC` only inside its second pool
loop for pools with `gsA > 0`, i.e. within about seven radii of the deep pool (d² < 50 + ln w). Beyond that, the paper
drops from the tint to near-black in one pixel: a broad dull shape in the entry's hue (brown for e0's hue 77) with a
hard edge, and the fringe's three scales split that edge into a reddish outline. At the bench's own slots (phone detail,
cards, orbs) and at Width the edge lies outside the picture; at Bench on the 6.9 : 1 Mac band it falls inside it. Light
hides it (light paper is a constant; `deepC` is not used there). **Not** the BD50 route (A shows it identically), **not**
the glass or edge bend (still there with both off), **not** the grain; the fringe only colours the edge (fringe 0: the
same edge, grey). Stills: `results-round2/o1-dark-cast-bisect.png` (dark BD50, dark A, light A, the fix, fringe 0,
glass + bend off).

**Fix:** `deepC` is set from the hue before the pool loop (it never depended on the pool), so the paper carries the
same tint everywhere. Switch **`-DeepFix on|off`** (panel "Dark-cast fix"), default **on**. "Without changing the look
where it was right": with the fix, **114 of the 120 reference stills are unchanged against T's bench** (mean ≤ 0.024);
the 6 others are all `detail-mac` dark, the one reference case whose slot already contained the edge: e0 2.44, e2 4.72,
e3 1.80, e5 5.75 (over the bar: the edge is gone), e4 0.57, e1 0.00. Across the whole
dial (Scale −0.15, 0, 0.25, 0.5, 0.75, 1, 1.15; dark, BD50), the fix removes the edge at −0.15, 0 and 0.25 and changes
nothing from 0.5 up (mean luminance identical): `results-round2/o1-dark-cast-scales.png` (left fix off, right fix on).
For T's eye: with the fix, a dark band at Bench is tinted (brown for e0) wall to wall instead of a brown island on black;
that is the bench's own dark paper, but it is a different picture from what he saw.

**The scrolled band: built (cheap).** Today's AirPad Mac detail (`ws-mac`, NodeDetailView `collapsedBand`, read only):
the hero scrolls away with the page and a **pinned band** (top inset + 52 pt, full width) fades in over it, opacity =
scroll offset ÷ the hero's visible height (0…1), showing a static blurred wash of the hero. The spike does the same with
Good Flow at **Width** scale, a still (drawn once; the fade is the view's alpha, no redraw: 1 frame drawn over a scroll to
400 pt), while the hero above stays at T's dialled scale. **`-ScrolledBand on|off|only`** (panel "Scrolled band";
`only` = the narrow band alone, pinned, full opacity). Still: `results-round2/o1-scrolled-band.png`.

Conditions: every still here is drawn offscreen by the band's own uniforms and mode (script verb `still:`), Mac
Catalyst Release, screen locked; window 1728 × 1028 Mac pt (2245 × 1336 UIKit pt, the build is iPad-scaled), band
2245 × 241 pt (the title-bar inset is 41 pt windowed; T's full-screen band was 2245 × 200).

## 2 · The Map: Good Flow revealed, not everywhere

**Built.** An orb shows its Good Flow still only when its **on-screen diameter ≥ Reveal size** AND its centre is
**inside the annulus** (screen distance from the view's centre ≤ Reveal annulus); otherwise it is a **plain disc in its
region's colour**. Both gates are smooth (a blend band = `soft` × each threshold), so an orb crossing either edge fades
between the two states; an orb whose still has not landed stays plain. Computed per orb in the Map's vertex shader
(`revealOf`, GoodFlow.metal), mirrored on the CPU (`GFMapView.reveal`) to pick which stills to keep.
- **Dials / switches** (panel rows + launch arguments, values on screen bottom-left of the Map, e.g. `Reveal ON · size ≥
  80 pt · annulus 300 pt · soft 0.25 · stills 35/48 @256px (16.7 MB) · revealed now 11 · zoom 1.00`):
  **`-RevealSize <pt>`** (20–240, default 80), **`-RevealAnnulus <pt>`** (60–1400, default 300), **`-RevealSoft <k>`**
  (0.02–0.6, default 0.25), **`-Reveal on|off`** (panel "Map reveal: On / All Good Flow"; off = round 1),
  `-RevealStills near|all`, `-RevealCap`, `-RevealSlots`.
- **Regions:** six regions over the eight synthetic clusters (cluster mod 6), colours by hex `#1B59C2 #E8820A #2E9E6A
  #C2365F #7B5CC7 #00A3C4` (GFColor.regionHex); plain orbs no longer use the entry's hue.
- **Annulus source: AirPad's own lens geometry, not the spike's** (the spike's Map has no lens). Read from `ws-mac`
  `CorpusPhysicsScene.AnnulusTuning`: viewport-centred, radius in SCREEN points, 300 pt (the default here). AirPad's bloom
  envelope (on only zoomed in past camera scale 3 → 1.5) is not copied: the size gate plays that part here.
- **Fewer stills, sharper:** with the reveal on, stills are kept only for orbs near the reveal (both gates widened 15 %),
  filled on demand into a pool of 48 slots at **256 px** (round 1: all 262 at 128 px) and recycled least recently wanted
  first. `-RevealStills all` keeps round 1's 262 for comparison.

**Measured** (Mac, M1 Max, Release, screen LOCKED, so OFFSCREEN: the Map pass drawn at the window's pixel size 4490 × 2672
(1728 × 1028 Mac pt), one command buffer a frame at 120 a second from a main-thread timer, 1 440 frames; light; two
launches per arm; nothing of mine beside it, but system daemons were busy: mobileassetd 71 %, BackgroundShortcutRunner
98 % CPU at the starts). Path "orbit": the camera circles e0's cluster at zoom 1.0–1.67 (camera scale 0.6–1.0) so orbs keep crossing the annulus
(10.6 revealed on average, 22 at most); path "wide" = round 1's programmatic path (1.1 revealed on average).

| arm | frame GPU p50 / p95 (orbit) | (wide) | still textures | footprint after fill | fills while moving (orbit, 12 s) |
|---|---|---|---|---|---|
| reveal off: all Good Flow, 262 stills @128 (round 1) | 0.83–0.84 / 1.01–1.27 ms | 0.32–0.33 / 0.70–0.71 | 24.8 MB | 162–229 MB | 0 |
| **reveal on, pool 48 @256** (default) | **0.72–0.74 / 0.87–0.89** | 0.32–0.34 / 0.61–0.63 | **16.7 MB** | 122 MB (both) | 31–32 stills, 18–34 evictions |
| reveal on, pool 48 @128 | 0.74 / 0.90 | 0.34 / 0.63 | **4.6 MB** | 111 MB | 31 |
| reveal on, all 262 @128 | 0.74 / 0.89 | 0.34 / 0.63–0.64 | 24.8 MB | 224–225 MB | 0 |

- **Companion's "cheaper" holds, modestly:** a frame costs about 12 % less GPU when the reveal is busy (plain discs skip
  the texture and the grain), and the stills take a third less memory while being twice as sharp (16.7 vs 24.8 MB), or a
  fifth of it at round 1's sharpness (4.6 MB). Every arm is far under the 4.0 ms bar; the frame was never the problem.
- **What the reveal adds:** fills WHILE moving (round 1 filled once and never again): ~2.5 stills a second on the
  orbit path. Per batch (one orb) p50 0.9–1.3 ms GPU; p95 4–7 ms and max 5–12 ms, at 128 px as much as at 256 px, so the
  tails are the fill's command buffer sharing the GPU with the 120 Hz frames (its start-to-end span), not the orb. Not seen
  as a lost frame here (offscreen: no presents to lose); the real port paces fills and reads it presented, unlocked.
- Footprint after fill is one sample per launch and noisy (the "off" arm read 162 and 229 MB); the texture bytes are exact.

Still: `results-round2/o2-map-reveal.png` (reveal off vs on at zoom 1, zoomed in, zoomed out (all plain: too small),
and dark). Offscreen Map passes (`-Script still:`), Release, the same build.

## 4 · The phone's live image inside its bar: built, verified on the Mac and in a Simulator, NOT read on the phone

**Switches** (launch arguments + panel rows; every one also in the bench file name and the recording's settings):
- **`-LiveScale 2`** (panel "Live layer scale: Display / 2×"): the live layer at 2 px per pt on the 3× phone (the
  compositor scales it up). Pixel-unit uniforms (glass band, mask radius, centre offset) follow the layer's scale.
- **`-LiveZone image`** (panel "Live card zone: Whole card / Image zone"): the live card covers only its image zone (the
  top 40 % on the phone, where the colour fades out); the slot stays the whole card, so every pixel it draws is the pixel
  the whole card draws there, and pass 1 of the two-pass variants only covers what the zone's taps reach.
- **`-ScrollRedraw on|off`**, **default OFF** (panel "Scroll redraw"): a scroll MOVES the live layer (it is a subview of
  the page / the cell) and only its own 30 Hz live clock redraws it, and only while it is on screen. `on` = round 1.
- **`-Pass2Only YES`**: a timing arm for the live surfaces only (pass 1 once, then pass 2 alone each frame; the
  picture freezes). Stills never use it.

**Harness:** every recorded frame now says whether its surface was on screen (`vis`). `frames.py --design` adds an
"on screen" table per surface (frames drawn off screen counted apart, cadence only between frames with a present time,
no link-target fallback, the live surface judged against its own 33 ms period) and the page's own scroll cadence (the
host link). This is fable-read-device §1's "How to read" made mechanical.

**Verified (switches work):**
- Simulator "CC good-flow r2" (iPhone 17 Pro Max, iOS 27.0; created for this and deleted after), Release:
  - Detail BD50 @2×, scripted scroll loop, 8 s + rest: **0 frames drawn off screen, 0 input-wake frames**; the band drew
    428 live frames, only while on screen; drawable 880 × 524 (= 440 × 262 pt × 2). Same run with `-ScrollRedraw on`:
    524 input-wake frames, **306 of them drawn off screen** (round 1's harness, reproduced).
  - Cards BD50, centred card @2× over its image zone, 8 s of swipes: the live layer 348 × 213 pt, **drawable 696 × 426
    = 296 496 px (round 1: 1 044 × 1 596 = 1 666 224 px, 0.18 of it)**, 576 live frames, 0 input-wake frames, 0 off screen,
    7 stills redrawn at live-end, 0 redrawn while moving. (The Simulator draws on the Mac's GPU: its ms are not the phone's.)
- Mac (locked, scripted): hovered card over its image zone: drawable 456 × 276 (of 456 × 640), and the first live frame
  equals the still **0.0000 mean, 0 max** (A and BD50).
- **The jump 3× still → 2× live**, the one this route adds: the first 2× zone frame upscaled onto the 3× still, Simulator,
  card 0: **mean 1.32, max 49** (A; BD50 1.30). Offscreen over the six entries × two themes, BD50, 2× bilinear-upscaled vs
  3×: detail mean 1.06 (p99 ≤ 6), card 0.94 (p99 ≤ 5); without the grain 0.47 and 0.18, so half of it is the grain re-landing
  on a coarser grid. At or just over the equality bar (mean ≤ 1.0): a softening, T's eye judges it (panel row, on his phone).

**Phone readings: prepared, not run** (the orchestrator runs them with T present; "running on your device, watch for the
Allow / passcode prompt" first). One line, about 17 minutes on the cable (4 × 120 s + rests + the stills):

    tools/run_on_phone.sh <UDID> --i-warned-T --seconds 120 --cooldown 90 --stills \
      --benches "detail:light:BD50:scale2,detail:light:BD50,cards:light:BD50:scale2+zone,detail:light:BD50:scale2+pass2"

1. Detail BD50 @2×, no scroll redraw: the proposal (Fable: ≈ 2.5 ms). 2. Detail BD50 @3×, no scroll redraw: the 2× vs 3×
control under the same harness. 3. Cards: centred card BD50 @2× over its image zone. 4. Detail BD50 @2× pass 2 only: how
much of BD50's cost is pass 2. `--stills` renders the 120 stills on the phone and compares them with the Mac's pool-table
stills (`build/r2/pools-bench`) and with T's bench: the outcome 5 check on a second chip. Optional fifth bench if time
allows: `cards:light:A:scale2+zone` (A instead of BD50 on the zone card). Read each with `python3 tools/frames.py
<bench>.json --design`: the "on screen" table is the number, the bar is the live GPU p95 ≤ 5.0 ms and 30 a second.

**If a live card still cannot hold** at 2× + zone + BD50 on the phone, the next steps in order: the live layer at 30 Hz
but with pass 1 every other frame (the field drifts slowly; pass 2 still runs per frame), then 1.5×, then live only
while the finger rests (a still while swiping), which costs nothing while moving.

## Round-2 log

| outcome | commit | status |
|---|---|---|
| 5 · pool table | 640f6b50 | done (Mac); the phone check is in the phone run (`--stills`) |
| 3 · Cards break | ab1046e7 | done: cause found and fixed (still queue + 50 × 50 first layout); the collapsed cells not reproduced by script, fixed structurally; on-screen jump owed to an unlocked run |
| 1 · Mac detail | b229f3c8, e7200b7b | done: Scale dial, dark cast explained + fixed, scrolled band built |
| 2 · Map reveal | 185ec0d1 | done, measured offscreen (locked) |
| 4 · phone live layer | 1e5d7960 | built + verified (Mac, Simulator); phone readings prepared, not run |

**Launch arguments added in round 2** (all also panel rows; values shown on screen where marked):
`-Pools bench|cpu|shader` · `-DetailZoom <z>` (on screen) · `-ScrolledBand on|off|only` · `-DeepFix on|off` ·
`-Reveal on|off`, `-RevealSize <pt>`, `-RevealAnnulus <pt>`, `-RevealSoft <k>` (on screen), `-RevealStills near|all`,
`-RevealCap`, `-RevealSlots` · `-LiveScale 2`, `-LiveZone image`, `-ScrollRedraw on|off`, `-Pass2Only YES` ·
`-Override "k=v,…"` (bisecting) · `-Script "verb:arg@s,…"` (scripted runs: GFRoot.runScript lists the verbs).
Tools: `tools/r2_stills.sh`, `tools/r2_mac.sh`, `tools/r2_sim.sh`, `tools/bench_pools.mjs`, `tools/angle_pools.py`;
`reference/run.mjs POOLS=table`.

Never list kept: synthetic entries only (no Library opened); no device touched; no T machine, model or setting
contacted; AirPad `main`, `ws-mac`, `ws-1.0-widget`, `ws-2b-renderer-trial` only read (`git show` / `git grep` on
`ws-mac`); nothing merged; no TestFlight; the Simulator was CC's own and is deleted.
