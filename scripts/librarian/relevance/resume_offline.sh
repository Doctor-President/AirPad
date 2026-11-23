#!/bin/zsh
# Sweep 2b · 3.2 — re-run run_night.sh's OFFLINE stages from step 5 on, reusing its question vectors
# (build/sweep2b/relevance/question-vectors.jsonl). No Simulator, no build, no server.
#   resume_offline.sh            signals + controls C-a…C-c + the cheap-arm grades
#   resume_offline.sh --rerank   then the reranker arms (MLX, GPU: run alone, never beside another model run) + final grade
# Used after the C-a fixture fix (common.load_library's room rule, 2026-11-23) so the 7-minute app launch isn't repeated.
set -u
cd ${0:A:h:h:h:h}
REPO=$PWD; REL=scripts/librarian/relevance; OUT=$REPO/build/sweep2b/relevance; ST=$OUT/status.txt
FIX=${RELEVANCE_FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}
VEC=$OUT/question-vectors.jsonl; BUDGET=${RERANK_BUDGET_MIN:-150}; PY=python3
export RELEVANCE_OUT=$OUT RELEVANCE_ALLOW_FIXTURE=1 PYTHONDONTWRITEBYTECODE=1
export RELEVANCE_WORDINGS_DIR=${RELEVANCE_WORDINGS_DIR:-$REPO/scripts/librarian/suite}
rm -f $OUT/DONE $OUT/STOPPED
note() { echo "$(date '+%F %T') $*" | tee -a $ST; }
stop() { note "STOP: $*"; touch $OUT/STOPPED; exit 1 }
free_gb() { df -g $REPO | tail -1 | awk '{print $4}' }
if env | grep -Eq ':(11434|1234)([^0-9]|$)'; then stop "an environment value names a port of T's"; fi
[[ -s $VEC ]] || stop "no question vectors (run run_night.sh)"
note "resume (offline) · ws-mac $(git rev-parse --short HEAD) · free $(free_gb) GB"

sig() { $PY $REL/signals.py --lib $1 --vectors $VEC "${@:2}" >> $ST 2>&1 }
if [[ ${1:-} != --rerank ]]; then
  sig bench || stop "signals bench"
  sig sample || { [[ -d $OUT/lib-sample-scratch/nodes ]] && sig sample --sample-nodes $OUT/lib-sample-scratch/nodes; } || stop "signals sample"
  sig fixture --fixture-nodes $FIX/nodes || stop "signals fixture"
  $PY $REL/controls.py --only a > $OUT/controls-a.log 2>&1 || {
    if [[ -d $OUT/lib-sample-scratch/nodes ]]; then
      note "C-a: retrying sample on the seeded Sample blocks"; sig sample --sample-nodes $OUT/lib-sample-scratch/nodes
      $PY $REL/controls.py --only a > $OUT/controls-a.log 2>&1
    fi
  } || stop "control C-a failed: $(tail -1 $OUT/controls-a.log | cut -c1-300)"
  note "C-a PASS: $(grep -o '"reproduced": [0-9]*' $OUT/controls-a.log | tr '\n' ' ')"
  $PY $REL/controls.py --only b > $OUT/controls-b.log 2>&1 || stop "control C-b failed: $(tail -1 $OUT/controls-b.log | cut -c1-300)"
  note "C-b PASS"
  $PY $REL/controls.py --only c > $OUT/controls-c.log 2>&1 || stop "control C-c failed: $(tail -1 $OUT/controls-c.log | cut -c1-300)"
  note "C-c PASS"
  $PY $REL/grade.py --tok A >> $ST 2>&1 || stop "grade (cheap arms) failed"
  $PY $REL/grade.py --tok B >> $ST 2>&1
  note "cheap arms graded · table: build/sweep2b/relevance/grade.md (reranker arms: resume_offline.sh --rerank)"
  exit 0
fi

(( $(free_gb) < 15 )) && stop "free disk $(free_gb) GB < 15 before the reranker"
FX=(--fixture-nodes $FIX/nodes); RR=ok
$PY $REL/rerank_mlx.py download >> $OUT/rerank.log 2>&1 || RR="download failed"
[[ $RR == ok ]] && { $PY $REL/rerank_mlx.py convert >> $OUT/rerank.log 2>&1 || RR="4-bit convert failed" }
[[ $RR == ok ]] && { $PY $REL/controls.py --only d > $OUT/controls-d.log 2>&1 || RR="control C-d failed: $(tail -1 $OUT/controls-d.log | cut -c1-200)" }
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
$PY $REL/grade.py --tok A >> $ST 2>&1 || stop "final grade failed"
$PY $REL/grade.py --tok B >> $ST 2>&1
FP=$HOME/Developer/Ops/.githooks/fpscan.py
if [[ -f $FP ]]; then
  if $PY $FP files $OUT/grade.md $OUT/grade-tokB.md $OUT/controls.json > $OUT/fpscan.log 2>&1; then note "fpscan: clean"
  else note "fpscan: MATCH — do not copy the sheet to Ops (fpscan.log names the kind only)"; fi
fi
note "DONE · free $(free_gb) GB · table: build/sweep2b/relevance/grade.md (tokenizer B: grade-tokB.md), controls.json"
touch $OUT/DONE
