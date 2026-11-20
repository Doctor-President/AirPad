#!/bin/zsh
# Sweep 2a, Phase B — the full benchmark, serially (one model at a time so timings are honest). Simulator only.
#   zsh scripts/librarian/phase_b.sh <out-root> [reps=3]
# Order: every route once (rep 1) before any repeat, so a stop leaves a usable table. Arms: "now" (ws-mac build) and
# "stopgap" (the scratch build with -StopgapBar 0.66 -StopgapNoAlwaysCite YES). Each run is graded as it lands.
set -u
cd ${0:A:h}/../..
ROOT=${1:A}; REPS=${2:-3}
B=scripts/librarian/benchmark
SG=${STOPGAP_APP:-../ws-2a-stopgap/build/DD-stopgap/Build/Products/Debug-iphonesimulator/AirPad.app}
export BENCH_TIMEOUT=7200
mkdir -p $ROOT
one() {   # arm rep set route model
  local arm=$1 rep=$2 set=$3 route=$4 model=$5
  local tag=${model//[:.]/}; [[ $route == apple ]] && tag=apple
  local out=$ROOT/$arm/$set-$tag-r$rep
  [[ -f $out/graded.json ]] && { echo "skip $out"; return }
  local priv=(); [[ $set == fixture-gk ]] && priv=(--private)
  echo "=== $(date +%T) $arm $set $route $model rep $rep"
  if [[ $arm == stopgap ]]; then
    BENCH_APP=$SG zsh scripts/librarian/bench.sh $route $model $B/cases-$set.json $out -- -StopgapBar 0.66 -StopgapNoAlwaysCite YES | grep -E "START|RESULT|TIMEOUT|EXITED|ABORT" | cut -c1-140
  else
    zsh scripts/librarian/bench.sh $route $model $B/cases-$set.json $out | grep -E "START|RESULT|TIMEOUT|EXITED|ABORT" | cut -c1-140
  fi
  [[ -f $out/results.json ]] && python3 scripts/librarian/bench.py grade $B/cases-$set.json $out/results.json --json $out/graded.json --md $out/graded.md $priv | sed -n 1p
}
for rep in $(seq 1 $REPS); do
  for arm in now stopgap; do
    for set in bench sample fixture-gk; do
      one $arm $rep $set server qwen3.5:4b
      one $arm $rep $set apple -
      one $arm $rep $set server qwen3.5:9b
    done
  done
  (( rep == 1 )) && one now 1 bench server qwen3:4b
done
echo "=== $(date +%T) phase B benchmark runs done"
