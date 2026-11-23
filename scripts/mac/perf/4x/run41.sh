#!/bin/zsh
# Sweep 2b · 4.1 — Space, ⌘O, Esc with real keys on the isolated bench copy (realistic test library), BY DAY, quiet Mac:
#   zsh scripts/mac/perf/4x/run41.sh <bench app> <out dir> [tstate|plain|both]     WIN="1534 920" for T's second size
# tstate = T's focus state (2b-41-keys.steps as is: the toolbar search field holding text, the Librarian in Search);
# plain = the same steps without the "search…" lines. Graded by grade41.py; Preview's documents counted (copy / other,
# never names) and the opened copies closed after each run; a quiet_watch log beside each run (a BUSY line = redo).
set -u
ROOT=${0:A:h:h:h:h:h}; K=$ROOT/scripts/mac/kit; P=$ROOT/scripts/mac/perf
APP=${1:?bench app}; APP=${APP:A}; OUT=${2:?out}; WHAT=${3:-both}; mkdir -p $OUT; OUT=${OUT:A}
(( $(df -g / | awk 'NR==2 {print $4}') < 15 )) && { echo "free disk under 15 GB: not running"; exit 2 }
zsh $K/unlocked.sh || { echo "screen locked: not running"; exit 3 }
export WIN="${WIN:-1703 924}"
fails=0
for focus in tstate plain; do
  [[ $WHAT == both || $WHAT == $focus ]] || continue
  R=$OUT/$focus; mkdir -p $R
  if [[ $focus == tstate ]]; then cp $P/2b-41-keys.steps $R/steps; else grep -vE '^search' $P/2b-41-keys.steps > $R/steps; fi
  zsh $P/quiet_watch.sh $R/quiet.log & Q=$!
  EXTRA="-Sweep4Log YES -Open4x document -Open4xDelay 18" zsh $P/run.sh $APP $R $R/steps > $R/run.txt 2>&1
  kill $Q 2>/dev/null
  if pgrep -x Preview >/dev/null; then
    osascript -e 'tell application "Preview" to get path of every document' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' \
      | awk '{print (index($0, "/Opened Copies/") > 0 ? "copy" : "other")}' | sort | uniq -c > $R/preview-docs.txt
    osascript -e 'tell application "Preview" to close (every document whose path contains "/Opened Copies/")' >/dev/null 2>&1
  else echo "Preview not running" > $R/preview-docs.txt; fi
  echo "== $focus · window $WIN · busy lines $(wc -l < $R/quiet.log | tr -d ' ') · preview: $(tr '\n' ' ' < $R/preview-docs.txt)" | tee $R/grade.txt
  python3 $P/4x/grade41.py $R | tee -a $R/grade.txt; (( ${pipestatus[1]} )) && fails=$((fails + 1))
done
zsh $K/tools.sh >/dev/null 2>&1; echo "modifiers after: $($ROOT/build/kit/mods)" | tee -a $OUT/mods.txt
echo "run41: $fails state(s) with a FAIL · $(git -C $ROOT rev-parse --short HEAD) · window $WIN"
exit $(( fails > 0 ))
