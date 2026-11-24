#!/bin/zsh
# Sweep 2b step 5 · by-day re-proofs on a fresh ws-mac bench copy (one job chain): reproof5.sh <app> [parts="21 41 sheet sheetctl cmdo"]
# Waits for an unlocked screen + HID idle ≥ 120 s before each run, quiet_watch beside each (BUSY > 0 = redo). 21 = 2.1 pacer
# (2b-map-proof.steps at 1703 / 1534, + -MapRate60 at 1534; read map_proof.py + scripts/perf/pacer_steps.py), 41 = run41.sh,
# sheet / sheetctl = a click inside the Settings sheet (verifier 4), cmdo = ⌘O then Space in the viewer (verifier 6).
S=${0:A:h}; M=${0:A:h:h:h:h:h}; P=$M/scripts/mac/perf; RUNS=$M/build/runs; K=$P/4x
APP=${1:?app}; PARTS=(${=2:-21 41 sheet sheetctl cmdo})
pre() { pgrep -f "AirPadMacA.app/Contents/MacOS/AirPad" >/dev/null && { echo "another AirPadMacA running; stop"; exit 4 }
  (( $(df -g / | awk 'NR==2 {print $4}') < 15 )) && { echo "DISK < 15 GB"; exit 5 }
  zsh $M/scripts/mac/kit/unlocked.sh || exit 3; i=0; while (( $(ioreg -c IOHIDSystem | awk "/HIDIdleTime/ {print int(\$NF/1000000000); exit}") < 120 )); do sleep 30; done || exit 3; }
one() {  # one(tag, steps, env...) — run.sh under quiet_watch
  tag=$1; steps=$2; shift 2; O=$RUNS/$tag; mkdir -p $O; touch $O/.keep; pre
  zsh $P/quiet_watch.sh $O/quiet.log & QW=$!
  env "$@" zsh $P/run.sh $APP $O $steps > $O/run.out 2>&1
  kill $QW 2>/dev/null; echo "== $tag · $(date +%T) · BUSY seconds $(grep -c BUSY $O/quiet.log) · $(head -1 $O/setup.txt)"; }
previewcopies() { O=$1
  if pgrep -x Preview >/dev/null; then
    osascript -e 'tell application "Preview" to get path of every document' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' \
      | awk '{print (index($0, "/Opened Copies/") > 0 ? "copy" : "other")}' | sort | uniq -c > $O/preview-docs.txt
    osascript -e 'tell application "Preview" to close (every document whose path contains "/Opened Copies/")' >/dev/null 2>&1
  else echo "Preview not running" > $O/preview-docs.txt; fi; echo "   preview: $(tr '\n' ' ' < $O/preview-docs.txt)"; }
for part in $PARTS; do case $part in
  21)
    for w in "1703 924" "1534 920"; do t=21R-${w%% *}; one $t $P/2b-map-proof.steps WIN="$w"
      python3 $M/scripts/perf/map_proof.py $RUNS/$t/recording.json $RUNS/$t/rperf.txt > $RUNS/$t/proof.txt 2>&1; done
    t=21R-60-1534; one $t $P/2b-map-proof.steps WIN="1534 920" EXTRA="-MapRate60 YES"
    python3 $M/scripts/perf/map_proof.py $RUNS/$t/recording.json $RUNS/$t/rperf.txt > $RUNS/$t/proof.txt 2>&1 ;;
  41)
    pre; O=$RUNS/2b-5-41-1703; zsh $P/4x/run41.sh $APP $O both 2>&1 | tail -30 ;;
  sheetctl)
    t=2b-5-sheetctl-1703; one $t $K/2b-5-sheetfield-ctl.steps WIN="1703 924" EXTRA="-Sweep4Log YES"
    grep -E " (ax|focus) " $RUNS/$t/rperf.txt | sed "s/ at [0-9]*//" | tee $RUNS/$t/grade.txt; grep "\[4x\] 4.1" $RUNS/$t/app.log | sed -E "s/.*\[4x\]/[4x]/" | tee -a $RUNS/$t/grade.txt ;;
  sheet)
    t=${SHEETTAG:-2b-5-sheet-1703}; one $t $K/2b-5-sheetfield.steps WIN="1703 924" EXTRA="-Sweep4Log YES"
    python3 $K/grade5.py sheet $RUNS/$t | tee $RUNS/$t/grade.txt ;;
  cmdo)
    t=2b-5-cmdo-1703; one $t $K/2b-5-cmdo-space.steps WIN="1703 924" EXTRA="-Sweep4Log YES" RPERF_CONTINUOUS=1
    previewcopies $RUNS/$t; python3 $K/grade5.py cmdo $RUNS/$t | tee $RUNS/$t/grade.txt ;;
esac; done
echo REPROOF DONE
