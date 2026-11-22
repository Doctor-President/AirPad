#!/bin/zsh
# Sweep 2b · 3.1 — the Librarian suite, unattended, on the step-1 build, AFTER the overnight proof. 2c's baseline.
#
#   nohup zsh scripts/librarian/suite/run_night.sh [--quick] [--wait] [--reps N] > build/sweep2b/suite/night.log 2>&1 &
#   zsh scripts/librarian/suite/run_night.sh --dry-run          preflight only (refuses until build/2b-proof/DONE exists)
#
# Tiers (estimates from the proof's own run times on this Mac: Qwen3.5 4B ~6.3 s, Apple ~11.5 s, 9B ~7.7 s per turn):
#   full (default)  Qwen3.5 4B, Apple Intelligence, Qwen3.5 9B × every wording (5) × 1 repeat     ≈ 3 h 50 min
#   --quick         Qwen3.5 4B and Apple Intelligence × every wording × 1 repeat                   ≈ 2 h 50 min
#   --reps N        repeats per wording (pass^k then spans wordings × repeats); each repeat adds about the same again
# Sets, in this order: planted (bench library + the overlay, seeded fresh), bench (re-seeded fresh, so the scratch bench
# library ends as the proof left it), sample, then T's fixture as a held-out check (original wordings, IDs and numbers
# only: graded --private, then its text is scrubbed from results.json and app.log).
#
# Never: ports 11434 / 1234, T's Host / PC / LM Studio / Ollama, a second Simulator, the real app container, writing into
# build/DD-2a, DD-2b, 2b-proof or sweep2a. CC's own Ollama on 127.0.0.1:11500, started as 2b_proof.sh starts it (its
# binary and model folder read only) and stopped at the end. Progress: <out>/status.txt, one line per run; then DONE or
# STOPPED. Resumable: a run with a graded.json is skipped (the first run executed per bench-type set re-seeds fresh).
set -u
cd ${0:A:h:h:h:h}
REPO=$PWD
S=scripts/librarian/suite
OUT=${SUITE_OUT:-$REPO/build/sweep2b/suite}; mkdir -p $OUT
ST=$OUT/status.txt
SIM=$(cat build/sweep2a/sim.udid)
APP=$REPO/build/DD-2b/Build/Products/Debug-iphonesimulator/AirPad.app
OLLAMA_BIN=$REPO/build/scratch-ollama/ollama
MODELS=$REPO/build/scratch-models
PORT=11500
PROOF_DONE=${SUITE_PROOF_DONE:-build/2b-proof/DONE}   # overridable for the preflight test only
PY=(python3 -B)
export PYTHONDONTWRITEBYTECODE=1 SUITE_SIM=$SIM SUITE_APP=$APP SUITE_OLLAMA=http://127.0.0.1:$PORT SUITE_TIMEOUT=7200
quick=0; dry=0; wait=0; reps=1
while (( $# )); do
  case $1 in
    --quick) quick=1 ;; --dry-run) dry=1 ;; --wait) wait=1 ;;
    --reps) reps=$2; shift ;;
    *:11434*|*:1234|*:1234/*) echo "refusing: an argument names T's server port"; exit 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
  shift
done
note() { echo "$(date '+%F %T') $*" | tee -a $ST }
started_ollama=0
cleanup() {
  [[ $(cat $OUT/lock/pid 2>/dev/null) == $$ ]] && rm -rf $OUT/lock
  if (( started_ollama )) && [[ -f $OUT/ollama.pid ]]; then kill $(cat $OUT/ollama.pid) 2>/dev/null; rm -f $OUT/ollama.pid; fi
}
trap cleanup EXIT
stop() { note "STOP: $*"; rm -f $OUT/DONE; touch $OUT/STOPPED; exit 1 }

# 0. T's ports: refuse any setting that names one.
if env | grep -Eq ':(11434|1234)([^0-9]|$)'; then stop "an environment value names port 11434 or 1234"; fi

# 1. disk first
free_gb() { df -g $REPO | tail -1 | awk '{print $4}' }
(( $(free_gb) < 15 )) && stop "free disk $(free_gb) GB < 15"

busy() {
  # another Simulator / build / bench / relevance job (ours excluded: this shell and its children)
  pgrep -fl 'xcodebuild|simctl|scripts/librarian/(bench|2b_proof|web_bench|phase_b)\.sh|scripts/librarian/relevance/run_night|gauntlet_routes|scripts/gauntlet/run|xctrace|scripts/mac/perf' \
    | grep -v "^$$ " | grep -v "scripts/librarian/suite/"
}
if (( wait )); then
  note "waiting for build/2b-proof/DONE and a quiet Mac (every 2 min, up to 12 h)"
  for i in {1..360}; do
    [[ -f $PROOF_DONE ]] && [[ -z "$(busy)" ]] && break
    sleep 120
  done
fi

# 2. preconditions (one suite at a time: a lock with our pid; a stale lock from a dead run is taken over)
if ! mkdir $OUT/lock 2>/dev/null; then
  holder=$(cat $OUT/lock/pid 2>/dev/null)
  [[ -n $holder ]] && kill -0 $holder 2>/dev/null && { echo "$(date '+%F %T') another suite run holds the lock (pid $holder)"; exit 1 }
fi
echo $$ > $OUT/lock/pid
rm -f $OUT/DONE $OUT/STOPPED
[[ -f $PROOF_DONE ]] || stop "$PROOF_DONE missing (the proof has not finished)"
b=$(busy); [[ -n $b ]] && stop "another job is running: $(echo $b | head -3 | cut -c1-120 | tr '\n' ';')"
booted=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | grep -v $SIM)
[[ -n $booted ]] && stop "another Simulator is booted ($booted): not starting a second"
[[ -x $APP/AirPad ]] || stop "the step-1 build is missing ($APP)"
if strings $APP/AirPad.debug.dylib 2>/dev/null | grep -qF "This answer is from the model's general knowledge, not your notes."; then
  echo "ok · the no-match line is in the after build verbatim" > $OUT/line-check.txt
else
  echo "MISSING · the no-match line is not in the after build verbatim" > $OUT/line-check.txt
  note "gate: the no-match line is NOT in the after build verbatim (counted as a guarantee break)"
fi
[[ -x $OLLAMA_BIN ]] || stop "CC's Ollama binary missing ($OLLAMA_BIN)"
for m in 4b 9b; do [[ -f $MODELS/manifests/registry.ollama.ai/library/qwen3.5/$m ]] || stop "model qwen3.5:$m missing in $MODELS"; done
listener=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1)
if [[ -n $listener ]]; then
  ps -o command= -p $listener | grep -qF $OLLAMA_BIN || stop "port $PORT is held by another process ($(ps -o comm= -p $listener)): not ours"
fi
$PY $S/suite.py check > $OUT/check.txt 2>&1 || stop "suite.py check failed (check.txt)"

routes=("server qwen3.5:4b" "apple -" "server qwen3.5:9b"); (( quick )) && routes=("server qwen3.5:4b" "apple -")
sets=(planted bench sample)
est=$($PY - $quick $reps <<'EOF'
import json, sys
sys.path.insert(0, "scripts/librarian/suite"); import suite
quick, reps = int(sys.argv[1]), int(sys.argv[2])
sec = {"4b": 6.3, "apple": 11.5, "9b": 7.7}
routes = ["4b", "apple"] if quick else ["4b", "apple", "9b"]
turns = sum(len(suite.turns_of(suite.load_json(suite.CASES[s]))) * suite.wording_count(s) for s in suite.WORDED) * reps
fixture = 19 * reps
mins = sum((turns + fixture) * sec[r] for r in routes) / 60 + 2 * 7 + 3
print(f"{turns} suite turns + {fixture} fixture turns per route, ≈ {mins / 60:.1f} h")
EOF
)
note "preflight ok · ws-mac $(git rev-parse --short HEAD) · free $(free_gb) GB · tier $( (( quick )) && echo quick || echo full) · reps $reps · $est"
(( dry )) && { note "dry run: stopping after the preflight"; exit 0 }

# 3. CC's own Ollama (as 2b_proof.sh starts it)
if [[ -z $listener ]]; then
  OLLAMA_HOST=127.0.0.1:$PORT OLLAMA_MODELS=$MODELS $OLLAMA_BIN serve > $OUT/ollama.log 2>&1 &
  echo $! > $OUT/ollama.pid; started_ollama=1
  for i in {1..30}; do curl -s 127.0.0.1:$PORT/api/version >/dev/null && break; sleep 1; done
  curl -s 127.0.0.1:$PORT/api/version >/dev/null || stop "own Ollama did not start (ollama.log)"
  note "own Ollama on $PORT pid $(cat $OUT/ollama.pid)"
else
  note "own Ollama already on $PORT (pid $listener, CC's scratch binary): using it, leaving it as found"
fi

# 4. the case files for tonight
$PY $S/suite.py expand $OUT/cases > /dev/null || stop "expand failed"
$PY $S/suite.py overlay $OUT/notes-overlay.json > /dev/null || stop "overlay failed"
export SUITE_NOTES=$OUT/notes-overlay.json
fails=0
one_run() {   # set route model casefile out fresh private
  local set=$1 route=$2 model=$3 cases=$4 out=$5 fresh=$6 priv=$7 t0=$(date +%s)
  local fr=(); (( fresh )) && fr=(--fresh)
  zsh $S/launch.sh $route $model $cases $out $fr > $out.log 2>&1
  local ok=$?
  if [[ -f $out/results.json ]]; then
    local pv=(); (( priv )) && pv=(--private)
    local line=$($PY $S/suite.py grade-run $set $out/results.json $out/graded.json --cases $cases $pv 2>&1 | tail -1)
    (( priv )) && $PY $S/suite.py scrub $out/results.json $out/app.log
    (( priv )) && : > $out.log
  fi
  local dt=$(( ($(date +%s) - t0) / 60 ))
  if (( ok == 0 )) && [[ -f $out/graded.json ]]; then note "run $set ${out:h:t} ${out:t} ok ${dt} min · ${line:-}"
  else
    rm -f $out/graded.json   # a partial run is re-run on resume
    note "run $set ${out:h:t} ${out:t} FAILED after ${dt} min (see ${out#$REPO/}.log)"
    (( ++fails >= 3 )) && { xcrun simctl shutdown $SIM 2>/dev/null; stop "3 failed runs" }
  fi
  (( $(free_gb) < 15 )) && { xcrun simctl shutdown $SIM 2>/dev/null; stop "free disk $(free_gb) GB < 15" }
}

# 5. the suite: set → route → wording → repeat
for set in $sets; do
  W=$($PY $S/suite.py wordings $set); seeded=0
  for rm in $routes; do
    route=${rm%% *}; model=${rm#* }; tag=${model//[:.]/}; [[ $route == apple ]] && tag=apple
    for w in {1..$W}; do for rep in {1..$reps}; do
      out=$OUT/runs/$set/$tag/w$w-r$rep; mkdir -p ${out:h}
      [[ -f $out/graded.json ]] && continue
      fresh=0; [[ $set == (planted|bench) ]] && (( ! seeded )) && fresh=1; seeded=1
      one_run $set $route $model $OUT/cases/$set-w$w.json $out $fresh 0
    done; done
  done
  [[ $set == planted ]] && note "planted done · the scratch bench library holds the overlay until the bench set re-seeds it"
done

# 6. T's fixture: held out, original wordings, IDs and numbers only
seeded=0
for rm in $routes; do
  route=${rm%% *}; model=${rm#* }; tag=${model//[:.]/}; [[ $route == apple ]] && tag=apple
  for rep in {1..$reps}; do
    out=$OUT/runs/fixture-gk/$tag/w1-r$rep; mkdir -p ${out:h}
    [[ -f $out/graded.json ]] && continue
    fresh=$(( ! seeded )); seeded=1
    one_run fixture-gk $route $model $REPO/scripts/librarian/benchmark/cases-fixture-gk.json $out $fresh 1
  done
done
xcrun simctl shutdown $SIM 2>/dev/null

# 7. the tables
$PY $S/suite.py report $OUT/runs --private-sets fixture-gk --ollama-log $OUT/ollama.log --line-check $OUT/line-check.txt \
  --md $OUT/suite.md --json $OUT/suite.json > /dev/null 2>&1 || note "report failed"
cleanup; started_ollama=0
note "DONE · $(head -3 $OUT/suite.md 2>/dev/null | tail -1 | cut -c1-140) · tables: suite.md suite.json · own Ollama stopped"
touch $OUT/DONE
