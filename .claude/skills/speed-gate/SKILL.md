---
name: speed-gate
description: Run and read the standing Mac speed gate (scripts/mac/perf/gate.sh) — PASS/FAIL per action against budgets in scripts/perf/gate.py. Run every Mac round, with Low Power Mode OFF and nothing else heavy on the Mac.
---
# Speed gate

1. Preconditions: unlocked (`scripts/mac/kit/unlocked.sh`), `caffeinate -d -u` held, **Low Power Mode off**
   (`pmset -g | grep lowpowermode` → 0; don't change T's setting without saying so; record it), no other heavy
   session (builds, Simulators, another CC) — numbers would be skewed.
2. Bench app: `zsh scripts/mac/kit/build1.sh Perf <tag>` (Release + PERFLOG + PANBENCH). Never the real Library.
3. Perf library once per copy: `zsh scripts/mac/perf/run.sh install <a DEBUG isolated app>` (265 + heavy entries);
   `run.sh restore` puts the copy's own library back.
4. Optional iPhone parity table: `scripts/perf/ios_parity.sh` (Simulator).
5. `zsh scripts/mac/perf/gate.sh <bench app> <out> [iphone table.json] [rounds=5] [soak=5]` ≈ 55 min in the background.
6. Read `<out>/gate.md`: one row per action — p50/p95 visible + settled, frame rate while moving, rest CPU, appearance
   soak phases; budgets in `scripts/perf/gate.py` (switch settled ≤ 150 ms, click → visible p95 ≤ 50 ms, no hang >
   100 ms, scroll at display rate, ~0 % at rest). Report FAILs first with the number and the budget.
7. Explain a FAIL with `python3 scripts/perf/explain.py <out>/session/recording.json --from T --to T --detail`
   (see `perf-recording`).
