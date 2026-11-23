#!/bin/zsh
# Sweep 2b · 3.2 rerun (2026-11-23 night): the reranker on the Sample Library, then the grade with in-pool counts.
#   rerun_sample.sh           the night run
#   rerun_sample.sh --check   preflight only (busy check, inputs, `verify`: no model loaded), writes nothing
# (a) scores bf16 v1 and v3 on the Sample only (bench and fixture caches are reused, never recomputed);
# (b) times pool-12 scoring per question on the Sample (every library-mode wording, warmed up, alone) and records peak
#     memory (MLX's own peak + /usr/bin/time -l max RSS and peak footprint);
# (c) re-runs the grade over bench, Sample and fixture (tokenizers A and B) with the in-pool denominator and
#     leave-one-case-out beside the in-sample fit; (d) touches DONE.
# MLX in-process: no server, no port, no network (HF offline). Refuses to start beside a build, a trace, rperf, a
# Simulator or a model run. The night's first grade is kept as grade-night1*.{md,json}.
# Estimate (from rerank.log: bf16 31.9–33.8 ms per pair on bench, 7,002 Sample pool pairs): about 4 min per variant,
# 1–2 min of timing, 1–2 min of grading → about 12–15 min (20 at most).
set -u
cd ${0:A:h:h:h:h}
REPO=$PWD; REL=scripts/librarian/relevance; OUT=$REPO/build/sweep2b/relevance; ST=$OUT/status.txt; PY=python3
SNODES=${RERUN_SAMPLE_NODES:-$OUT/lib-sample-scratch/nodes}
export RELEVANCE_OUT=$OUT PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export RELEVANCE_WORDINGS_DIR=${RELEVANCE_WORDINGS_DIR:-$REPO/scripts/librarian/suite}
LOG=$OUT/rerun-sample.log; CHECK=0; [[ ${1:-} == --check ]] && { CHECK=1; LOG=$(mktemp -t rerun-check) }
note() { if (( CHECK )); then echo "$(date '+%F %T') $*"; else echo "$(date '+%F %T') $*" | tee -a $ST $LOG; fi }
stop() { note "STOP (rerun): $*"; (( CHECK )) || touch $OUT/STOPPED; exit 1 }
free_gb() { df -g $REPO | tail -1 | awk '{print $4}' }
busy() {   # quiet_watch.sh's rule plus traces, rperf and another reranker run
  local b m
  b=$(ps -axo comm= | grep -cE "(^|/)(xcodebuild|xctrace|rperf|swift-frontend|swift-driver|clang|ld|launchd_sim|ibtoold|actool)$")
  m=$(ps -axo command= | grep -E "ollama (serve|runner)|rerank_mlx\.py|mlx_lm" | grep -v "AirPad Host.app" | grep -vc grep)
  (( b + m > 0 )) && { echo "build/trace/Simulator=$b model=$m"; return 0 }
  return 1
}
if env | grep -Eq ':(11434|1234)([^0-9]|$)'; then stop "an environment value names a port of T's"; fi
if why=$(busy); then stop "busy ($why): run alone, never beside a build, trace or model run"; fi
[[ -d $SNODES ]] || stop "no seeded Sample nodes at $SNODES (the signals used them)"
for l in bench sample fixture; do [[ -s $OUT/signals-$l.npz ]] || stop "no signals-$l (run resume_offline.sh)"; done
for l in bench fixture; do [[ -s $OUT/rerank-cache/$l.jsonl ]] || stop "no $l reranker cache to reuse"; done
(( $(free_gb) < 10 )) && stop "free disk $(free_gb) GB < 10"
(( CHECK )) || rm -f $OUT/DONE $OUT/STOPPED
note "rerun (Sample reranker + in-pool grade) · ws-mac $(git rev-parse --short HEAD) · free $(free_gb) GB"
(( CHECK )) || for f in grade.md grade.json grade-tokB.md grade-tokB.json; do
  [[ -f $OUT/$f && ! -f $OUT/${f/grade/grade-night1} ]] && cp $OUT/$f $OUT/${f/grade/grade-night1}
done

RR=(--lib sample --sample-nodes $SNODES)
# 0. no model: the Sample opened here is the signals' passage set (712 passages, same block IDs, same questions)
$PY $REL/rerank_mlx.py verify $RR >> $LOG 2>&1 || stop "verify sample: $(tail -1 $LOG | cut -c1-300)"
note "$(grep '^verify sample' $LOG | tail -1)"
if (( CHECK )); then note "check OK: ready for the night run (nothing written)"; rm -f $LOG; exit 0; fi
t0=$(date +%s)
# (a) score; a mismatch exits 2, a short cache exits 3: either stops the rerun
for v in v1 v3; do
  /usr/bin/time -l -o $OUT/rerun-time-score-$v.txt $PY $REL/rerank_mlx.py score $RR --precision bf16 --variants $v \
    >> $LOG 2>&1 || stop "score sample bf16 $v failed (exit $?): $(tail -2 $LOG | cut -c1-300)"
  note "sample bf16 $v: $(grep "^rerank sample bf16 $v" $LOG | tail -1 | cut -c1-200) · max RSS $(awk '/maximum resident/ {printf "%.0f MB", $1/1048576}' $OUT/rerun-time-score-$v.txt)"
done
note "Sample scored in $(( ($(date +%s) - t0) / 60 )) min"
# (b) pool-12 per question, alone
if why=$(busy); then note "timing SKIPPED: busy ($why) — not measured beside another job"
else
  /usr/bin/time -l -o $OUT/rerun-time-timing.txt $PY $REL/rerank_mlx.py time $RR --precision bf16 --variants v1,v3 \
    --pool 12 --questions 0 --all-wordings >> $LOG 2>&1 || note "timing failed (exit $?): $(tail -1 $LOG | cut -c1-200)"
  note "timing (rerank-timing-sample-bf16.json): $(grep -o '"v[13]_pool12": {[^}]*}' $LOG | tail -2 | tr '\n' ' ' | cut -c1-300) · max RSS $(awk '/maximum resident/ {printf "%.0f MB", $1/1048576}' $OUT/rerun-time-timing.txt) · peak footprint $(awk '/peak memory footprint/ {printf "%.0f MB", $1/1048576}' $OUT/rerun-time-timing.txt)"
fi
# (c) the grade, all three libraries
$PY $REL/grade.py --tok A >> $ST 2>&1 || stop "grade failed"
$PY $REL/grade.py --tok B >> $ST 2>&1 || note "grade tokenizer B failed"
FP=$HOME/Developer/Ops/.githooks/fpscan.py
if [[ -f $FP ]]; then
  if $PY $FP files $OUT/grade.md $OUT/grade-tokB.md > $OUT/fpscan.log 2>&1; then note "fpscan: clean"
  else note "fpscan: MATCH — do not copy the sheet to Ops (fpscan.log names the kind only)"; fi
fi
# (d)
note "DONE (rerun) · $(( ($(date +%s) - t0) / 60 )) min · free $(free_gb) GB · table: build/sweep2b/relevance/grade.md (night 1: grade-night1.md)"
touch $OUT/DONE
