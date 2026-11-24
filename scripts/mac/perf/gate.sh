#!/bin/zsh
# The standing speed gate (Mac perf audit P4): one command, PASS / FAIL per action against the budgets in
# scripts/perf/gate.py.   gate.sh <isolated bench .app> <out dir> [iphone table.json] [rounds=5] [soak cycles=5]
# Needs the perf library installed in the isolated copy (run.sh install …), the screen unlocked, `caffeinate -d` held,
# and nothing else busy on the Mac. About 55 minutes: the session ×5, each screen at rest, the appearance cycles
# (≈ 6.5 min each; 5 ≈ the 30-minute soak). The iPhone table comes from scripts/perf/ios_parity.sh (Simulator).
# A bench app = Release + PERFLOG + PANBENCH (build/mac-perf/buildperf.sh); the gate never runs on the real Library.
# On the realistic library (run.sh install with LIB=realistic): SESSION_STEPS=…/p1-session-realistic.steps and
# HEAVY / LIGHT (rest.sh) set to its entries; WIN / WINY size every launch (default 1350 840 as before).
set -u
ROOT=${0:A:h:h:h:h}; APP=${1:?app}; OUT=${2:?out}; IOS=${3:-}; ROUNDS=${4:-5}; CYCLES=${5:-5}; mkdir -p $OUT; OUT=${OUT:A}
SESSION_STEPS=${SESSION_STEPS:-$ROOT/scripts/mac/perf/p1-session.steps}
EXTRA="-ProUnlocked YES ${EXTRA:-}" TAIL=1 zsh $ROOT/scripts/mac/perf/run.sh $APP $OUT/session $SESSION_STEPS $ROUNDS > $OUT/session.out 2>&1 || { cat $OUT/session.out; exit 3 }
EXTRA="-ProUnlocked YES ${EXTRA:-}" TAIL=1 zsh $ROOT/scripts/mac/perf/run.sh $APP $OUT/resize $ROOT/scripts/mac/perf/p0-resize.steps 3 > $OUT/resize.out 2>&1
zsh $ROOT/scripts/mac/perf/rest.sh $APP $OUT/rest > $OUT/rest.out 2>&1
zsh $ROOT/scripts/mac/perf/p0-appearance.sh $APP $OUT/appearance $CYCLES > $OUT/appearance.out 2>&1
python3 $ROOT/scripts/perf/gate.py --mac $OUT/session/table.json $OUT/resize/table.json ${IOS:+--iphone $IOS} --rest $OUT/rest/rest.json --phases $OUT/appearance/phases.json --out $OUT/gate.md
