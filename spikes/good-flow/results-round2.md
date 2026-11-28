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
