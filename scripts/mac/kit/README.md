# Mac kit — the one place for building, launching and driving the isolated Mac copy (mac-sweep-1, 2026-11-19)

Everything writes under `build/` (git-ignored): compiled tools in `build/kit/`, every run in `build/runs/<tag>/`.
`build/runs/` keeps the newest **12** runs; a run with a `.keep` file is never pruned. Ops evidence (small: stills,
tables, the T-check) goes to `Ops/design-refs/<round>/`, never raw logs or videos over a few MB.

| script | what |
|---|---|
| `tools.sh` | compile `scripts/mac/realclick/*.swift` (rclick, rscroll, rperf, locked, mods, rrec …) into `build/kit/` when stale |
| `build1.sh <Debug\|Release\|Perf> <tag>` | Catalyst build → isolated copy `build/runs/<tag>/AirPadMacA.app` (Perf = Release + `-D PERFLOG -D PANBENCH`, the bench app the gate needs). Restores the scheme Xcode rewrites. |
| `buildios.sh <Debug\|Release> <tag>` | iPhone Simulator build (Release = bench: + PERFLOG/PANBENCH) |
| `launch.sh <app> <out> [open-entry]` | quit any isolated copy, launch this one at (0,60) 1100×840, print its pid. `EXTRA="-Key v …"` must be EXPORTED. |
| `selftests.sh <Debug app> <out>` | every Mac launch-arg self-test; `ONLY="A B"` to pick; summary in `<out>/summary.txt` |
| `unlocked.sh` | exit 0 when the screen is unlocked AND this shell may post events; prints the state either way |
| `prune.sh` | keep the newest 12 runs (called by build1.sh) |

Before any real-event step: `scripts/mac/kit/unlocked.sh` and hold `caffeinate -d -u` for the whole phase (the Mac
locks on display sleep). One agent owns the mouse at a time. Never run on the real Library: the isolated copy has its
own bundle ID (`com.doctorpresident.airpad.macA`) and sandbox container.
