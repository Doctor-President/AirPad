#!/bin/zsh
# Good Flow spike · ONE measured Mac run with REAL trackpad events (the 2b trial's tooling: scripts/mac/realclick/rperf).
#   tools/mac_run.sh <case: detail|cards|map> <tag> [steps file]      env: WIN="1728 1028" (or "1703 924"), ARGS="-Variant BD50 …"
#   tools/mac_run.sh --dry <case> <tag>     everything except posting events (works with the screen locked: a dry check)
# Conditions it checks (design §3, lesson 12): Release build launched through LaunchServices (as from the Finder, not
# Xcode), screen unlocked, ≥ 15 GB free, nothing heavy beside it (quiet_watch: a run with BUSY seconds is thrown away),
# window at (0,0) sized WIN. It waits for the screen to be unlocked and the Mac idle ≥ 60 s (IDLE=…) unless --dry.
# Output: build/mac-runs/<tag>/ rperf.txt steps.csv recording.json frames.txt setup.txt quiet.log
set -u
SPIKE=${0:A:h:h}; ROOT=${SPIKE:h:h}; RC=$ROOT/scripts/mac/realclick; T=$SPIKE/build/tools
APP=${APP:-$SPIKE/build/dd/Build/Products/Release-maccatalyst/GoodFlow.app}
C=~/Library/Containers/com.doctorpresident.spike.SpikeHarness/Data/Documents/recordings
DRY=0; [[ ${1:-} == --dry ]] && { DRY=1; shift }
CASE=${1:?case}; TAG=${2:?tag}; STEPS=${3:-$SPIKE/tools/steps/$CASE.steps}
O=$SPIKE/build/mac-runs/$TAG; mkdir -p $O $T
for t in rclick rperf locked; do [[ $T/$t -nt $RC/$t.swift ]] || swiftc -O -o $T/$t $RC/$t.swift 2>/dev/null || { echo "could not build $t"; exit 2 }; done
[[ -d $APP ]] || { echo "no app at $APP (build Release for Mac Catalyst first)"; exit 2 }
free=$(df -g / | awk 'NR==2 {print $4}'); (( free < 15 )) && { echo "DISK $free GB < 15: not running"; exit 5 }
if (( ! DRY )); then
  while true; do
    st=$($T/locked); idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    [[ $st == "locked 0"* ]] && (( idle >= ${IDLE:-60} )) && break
    echo "$(date +%T) waiting: $st idle=${idle}s"; sleep 30
  done
  [[ $st == *"post 1"* ]] || { echo "this shell may not post events ($st): grant Accessibility to the terminal"; exit 3 }
fi
# one app at a time: quit any earlier spike instance by PID
for p in $(pgrep -x GoodFlow); do kill $p; done; sleep 1
mkdir -p $C; rm -f $C/scripted-*.json(N)
zsh $ROOT/scripts/mac/perf/quiet_watch.sh $O/quiet.log & QW=$!
trap "kill $QW 2>/dev/null" EXIT
open -n -a $APP --args -Case $CASE -ApplePersistenceIgnoreState YES ${=ARGS:-}
P=; for i in $(seq 1 20); do P=$(pgrep -nx GoodFlow); [[ -n $P ]] && break; sleep 0.5; done
[[ -z $P ]] && { echo "the app did not start"; exit 4 }
sleep 4
$T/rclick winmove $P 0 0 > /dev/null; $T/rclick winsize $P ${=WIN:-1728 1028} > $O/window.txt
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true" > /dev/null 2>&1; sleep 1
FRONT=$(osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true' 2>/dev/null)
echo "case $CASE · tag $TAG · window $(cat $O/window.txt) · front $FRONT (app $P) · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet -- spikes/good-flow || echo +dirty) · powermode $(pmset -g | awk '/lowpowermode|powermode/ {print $2; exit}') · $(pmset -g batt | head -1 | tr -d "'") · ARGS ${ARGS:-} · dry $DRY" > $O/setup.txt
if (( DRY )); then
  sleep 3; echo "DRY: no events posted" > $O/rperf.txt
else
  [[ $FRONT != $P ]] && { echo "NOT FRONTMOST: not running" | tee -a $O/setup.txt; kill $P; exit 4 }
  sleep 2
  RPERF_CSV=$O/steps.csv $T/rperf $P $STEPS > $O/rperf.txt 2>&1
fi
notifyutil -p com.goodflow.save; sleep 3
REC=$(ls -t $C/scripted-*.json 2>/dev/null | head -1)
[[ -n $REC ]] && cp $REC $O/recording.json || echo "NO RECORDING" >> $O/setup.txt
kill $P 2>/dev/null
busy=$(grep -c BUSY $O/quiet.log); echo "BUSY seconds $busy" >> $O/setup.txt
cat $O/setup.txt
[[ -f $O/recording.json ]] && python3 $SPIKE/tools/frames.py $O/recording.json --design > $O/frames.txt 2>&1 && head -40 $O/frames.txt
