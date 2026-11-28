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
where it was right": with the fix, **115 of the 120 reference stills are unchanged against T's bench** (mean ≤ 0.02);
the 5 that change are `detail-mac` dark, the one reference case whose slot already contained the edge. Across the whole
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
