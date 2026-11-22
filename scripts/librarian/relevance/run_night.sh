#!/bin/zsh
# Sweep 2b · 3.2 — the keyword-relevance spike, unattended, AFTER the overnight proof (build/2b-proof/DONE).
#
#   nohup zsh scripts/librarian/relevance/run_night.sh [--wait] > build/sweep2b/relevance/night.log 2>&1 &
#
# --wait   poll every 2 min (up to 12 h) for build/2b-proof/DONE and a quiet Mac, then start.
# Order (design §5): df → refuse T's ports → preconditions → copy the bench scratch out of CC's Simulator → ONE app
# launch (-EmbedDump, question vectors; the fixture's questions only through a named pipe) → signals → controls C-a…C-c
# (stop on a fail, saying which) → cheap grade → reranker: download / 4-bit convert / C-d / timings / scoring (disk
# cache) → final grade (tokenizers A and B) → fpscan on the result sheet. Progress: build/sweep2b/relevance/status.txt,
# one line per step; DONE (or STOPPED) at the end. Never: ports 11434 / 1234, T's Host / PC / LM Studio, the 11500
# Ollama, a second Simulator, the real app container. The fixture is read in memory; IDs and numbers only are written.
set -u
cd ${0:A:h:h:h:h}
REPO=$PWD
REL=scripts/librarian/relevance
OUT=$REPO/build/sweep2b/relevance; mkdir -p $OUT
ST=$OUT/status.txt
APP=$REPO/build/32-rel/dd/Build/Products/Debug-iphonesimulator/AirPad.app
SIM=$(cat build/sweep2a/sim.udid)          # "CC sweep2a": the Simulator the proof used; free once DONE
FIX=${RELEVANCE_FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}
BUDGET=${RERANK_BUDGET_MIN:-150}           # minutes of reranker scoring at most
PY=python3
RB=(); FIXN=""
export RELEVANCE_OUT=$OUT RELEVANCE_ALLOW_FIXTURE=1 PYTHONDONTWRITEBYTECODE=1
rm -f $OUT/DONE $OUT/STOPPED
note() { echo "$(date '+%F %T') $*" | tee -a $ST; }
stop() { note "STOP: $*"; touch $OUT/STOPPED; exit 1 }

# 0. T's ports: nothing here talks to a server; refuse any setting that names one.
if env | grep -Eq ':(11434|1234)([^0-9]|$)'; then stop "an environment value names port 11434 or 1234"; fi
for a in "$@"; do [[ $a == *:11434* || $a == *:1234 || $a == *:1234/* ]] && stop "argument names port 11434 / 1234"; done

free_gb() { df -g $REPO | tail -1 | awk '{print $4}' }
busy() {
  # another Simulator / build / bench job (ours excluded)
  pgrep -fl 'xcodebuild|simctl|scripts/librarian/(bench|2b_proof|web_bench|phase_b)\.sh|gauntlet_routes|xctrace|scripts/mac/perf' \
    | grep -v "^$$ " | grep -v run_night.sh
}
if [[ ${1:-} == --wait ]]; then
  note "waiting for build/2b-proof/DONE and a quiet Mac (every 2 min, up to 12 h)"
  for i in {1..360}; do
    [[ -f build/2b-proof/DONE ]] && [[ -z "$(busy)" ]] && break
    sleep 120
  done
fi

# 1. disk first
(( $(free_gb) < 15 )) && stop "free disk $(free_gb) GB < 15"
note "start · ws-mac $(git rev-parse --short HEAD) · free $(free_gb) GB"

# 2. preconditions
[[ -f build/2b-proof/DONE ]] || stop "build/2b-proof/DONE missing (the proof has not finished)"
b=$(busy); [[ -n $b ]] && stop "another job is running: $(echo $b | head -3 | cut -c1-120 | tr '\n' ';')"
booted=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | grep -v $SIM)
[[ -n $booted ]] && stop "another Simulator is booted ($booted): not starting a second"
[[ -d $FIX/nodes ]] || stop "fixture nodes folder missing (RELEVANCE_FIXTURE)"
if [[ ! -x $APP/AirPad ]] || ! strings $APP/AirPad.debug.dylib 2>/dev/null | grep -q EmbedDump; then
  note "building the Simulator Debug app (build/32-rel/dd)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirPad.xcodeproj -scheme AirPad \
    -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/32-rel/dd build > $OUT/build.log 2>&1 || stop "Simulator build failed (build.log)"
  git checkout -- AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null
fi

# 3. the bench library out of CC's Simulator (read only), before the app runs again
$PY $REL/export.py copy-sim --udid $SIM >> $ST 2>&1 || stop "copy-sim failed"
[[ -d $OUT/lib-bench/nodes ]] || stop "no bench scratch library in the Simulator"
WORD=$($PY $REL/questions.py summary --libs bench,sample,fixture --fixture-nodes $FIX/nodes 2>/dev/null \
  | $PY -c "import json,sys;d=json.load(sys.stdin);print(' / '.join(f'{k}: {v[\"wordings\"]}' for k,v in d.items()))") \
  || stop "questions summary failed"
note "questions: $WORD"

# 4. ONE app launch: the question vectors (fixture questions only through the named pipe)
FIFO=$OUT/embed-in.fifo; VEC=$OUT/question-vectors.jsonl
rm -f $FIFO $VEC; mkfifo $FIFO
$PY $REL/questions.py emit --fifo --out $FIFO --libs bench,sample,fixture --fixture-nodes $FIX/nodes > $OUT/emit.log 2>&1 &
writer=$!
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1
xcrun simctl install $SIM $APP || stop "install failed"
xcrun simctl launch --console-pty --terminate-running-process $SIM com.doctorpresident.airpad \
  -SampleSeedDemo -EmbedCPUOnly -EmbedDump $FIFO $VEC > $OUT/embed-app.log 2>&1 &
launcher=$!
deadline=$(( $(date +%s) + 1800 ))
while ! grep -q "\[EmbedDump\] done" $OUT/embed-app.log 2>/dev/null; do
  (( $(date +%s) > deadline )) && { note "EmbedDump TIMEOUT"; break }
  kill -0 $launcher 2>/dev/null || { sleep 2; break }
  sleep 3
done
xcrun simctl terminate $SIM com.doctorpresident.airpad > /dev/null 2>&1
kill $writer 2>/dev/null; rm -f $FIFO
xcrun simctl shutdown $SIM > /dev/null 2>&1
n_in=$(grep -Eo '[0-9]+ lines' $OUT/emit.log | grep -Eo '[0-9]+'); n_out=$(wc -l < $VEC 2>/dev/null | tr -d ' ')
note "EmbedDump: $(grep -E '\[EmbedDump\] (wrote|ABORT)' $OUT/embed-app.log | sed 's/.*\[EmbedDump\] //' | cut -c1-60) · lines in ${n_in:-?} out ${n_out:-0}"
[[ -n ${n_out:-} && ${n_out:-0} -gt 0 && ${n_out} == ${n_in:-x} ]] || stop "EmbedDump did not return every vector"

# 5. signals + controls C-a … C-c
sig() { $PY $REL/signals.py --lib $1 --vectors $VEC "${@:2}" >> $ST 2>&1 }
sig bench || stop "signals bench"; sig sample || stop "signals sample"
sig fixture --fixture-nodes $FIX/nodes || stop "signals fixture"
$PY $REL/controls.py --only a > $OUT/controls-a.log 2>&1
if [[ $? != 0 ]]; then
  ca() { $PY -c "import json;d=json.load(open('$OUT/controls.json'))['C-a'];print(int(d.get('$1',{}).get('pass',False)))" }
  if [[ $(ca sample) == 0 && -d $OUT/lib-sample-scratch/nodes ]]; then
    note "C-a sample failed on the repo blocks → trying the seeded Sample blocks copied from the Simulator"
    sig sample --sample-nodes $OUT/lib-sample-scratch/nodes
  fi
  if [[ $(ca fixture) == 0 ]]; then
    CL=$($PY -c "import sys;sys.path.insert(0,'$REL');import export;c=export.app_data_container('$SIM');print(c/'Library/Caches/AirPadCorpusFixtureScratch/nodes' if c else '')")
    if [[ -n $CL && -d $CL ]]; then
      note "C-a fixture failed on the source fixture → trying the Simulator's fixture clone, in place, in memory"
      sig fixture --fixture-nodes $CL && FIXN=$CL
    fi
  fi
  if [[ $(ca bench) == 0 ]]; then
    note "C-a bench failed → re-recording the bench retrieval once (Apple stub route, minutes)"
    BENCH_APP=$APP BENCH_SIM=$SIM zsh scripts/librarian/bench.sh apple - scripts/librarian/benchmark/cases-bench.json \
      $OUT/rerec-bench -- -StubOnDeviceModel YES > $OUT/rerec-bench.log 2>&1
    xcrun simctl shutdown $SIM > /dev/null 2>&1
    $PY $REL/export.py copy-sim --udid $SIM >> $ST 2>&1
    sig bench --results $OUT/rerec-bench/results.json
    RB=(--results-bench $OUT/rerec-bench/results.json)
  fi
  $PY $REL/controls.py --only a ${RB[@]} > $OUT/controls-a.log 2>&1 || stop "control C-a failed: $(tail -1 $OUT/controls-a.log | cut -c1-300)"
fi
note "C-a PASS: $(grep -o '"reproduced": [0-9]*' $OUT/controls-a.log | tr '\n' ' ')"
$PY $REL/controls.py --only b ${RB[@]} > $OUT/controls-b.log 2>&1 || stop "control C-b failed: $(tail -1 $OUT/controls-b.log | cut -c1-300)"
note "C-b PASS"
$PY $REL/controls.py --only c > $OUT/controls-c.log 2>&1 || stop "control C-c failed: $(tail -1 $OUT/controls-c.log | cut -c1-300)"
note "C-c PASS"

# 6. the cheap arms (a table exists even if the reranker part fails)
$PY $REL/grade.py --tok A >> $ST 2>&1 || stop "grade (cheap arms) failed"
$PY $REL/grade.py --tok B >> $ST 2>&1

# 7. the reranker
(( $(free_gb) < 15 )) && stop "free disk $(free_gb) GB < 15 before the reranker"
FX=(--fixture-nodes ${FIXN:-$FIX/nodes})
RR=ok
$PY $REL/rerank_mlx.py download >> $OUT/rerank.log 2>&1 || RR="download failed"
[[ $RR == ok ]] && { $PY $REL/rerank_mlx.py convert >> $OUT/rerank.log 2>&1 || RR="4-bit convert failed" }
if [[ $RR == ok ]]; then
  $PY $REL/controls.py --only d > $OUT/controls-d.log 2>&1 || RR="control C-d failed: $(tail -1 $OUT/controls-d.log | cut -c1-200)"
fi
if [[ $RR == ok ]]; then
  note "C-d PASS"
  for prec in bf16 q4; do $PY $REL/rerank_mlx.py time --precision $prec >> $OUT/rerank.log 2>&1; done
  t0=$(date +%s)
  for prec in bf16 q4; do
    for v in v0 v1 v2 v3; do
      left=$(( BUDGET - ($(date +%s) - t0) / 60 ))
      (( left <= 0 )) && { note "reranker budget ($BUDGET min) used: $prec $v not scored"; continue }
      for lib in bench sample fixture; do
        $PY $REL/rerank_mlx.py score --lib $lib --precision $prec --variants $v --budget-min $left ${FX[@]} \
          >> $OUT/rerank.log 2>&1 || note "rerank $lib $prec $v failed"
      done
      note "reranker $prec $v scored ($(( ($(date +%s) - t0) / 60 )) min so far)"
    done
  done
else
  note "reranker arms NOT run: $RR (the cheap table stands)"
fi

# 8. the final grade, both tokenizers
$PY $REL/grade.py --tok A >> $ST 2>&1 || stop "final grade failed"
$PY $REL/grade.py --tok B >> $ST 2>&1
FP=$HOME/Developer/Ops/.githooks/fpscan.py
if [[ -f $FP ]]; then
  if $PY $FP files $OUT/grade.md $OUT/grade-tokB.md $OUT/controls.json > $OUT/fpscan.log 2>&1; then note "fpscan: clean"
  else note "fpscan: MATCH — do not copy the sheet to Ops (fpscan.log names the kind only)"; fi
fi
note "DONE · free $(free_gb) GB · table: build/sweep2b/relevance/grade.md (tokenizer B: grade-tokB.md), controls.json"
touch $OUT/DONE
