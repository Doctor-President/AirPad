#!/bin/zsh
# Good Flow spike · the rest / live / still-cache checks that are valid with the Mac's screen LOCKED (no events posted,
# no cadence read: presentedTime is 0 and nextDrawable can stall while locked). Each launch saves a recording
# (-AutoSaveAt) and quits; frames.py --design reads it. Output: build/headless/<name>.json + .txt, and SUMMARY.txt.
set -u
SPIKE=${0:A:h:h}; RC=${SPIKE:h:h}/scripts/mac/realclick; T=$SPIKE/build/tools; O=$SPIKE/build/headless; mkdir -p $O $T
APP=$SPIKE/build/dd/Build/Products/Release-maccatalyst/GoodFlow.app
C=~/Library/Containers/com.doctorpresident.spike.SpikeHarness/Data/Documents/recordings
[[ $T/rclick -nt $RC/rclick.swift ]] || swiftc -O -o $T/rclick $RC/rclick.swift 2>/dev/null
run() {   # run <name> <seconds> <args…>
  local name=$1 secs=$2; shift 2
  for p in $(pgrep -x GoodFlow); do kill $p; done; sleep 1
  rm -f $C/$name.json
  open -n -a $APP --args -ApplePersistenceIgnoreState YES -AutoSaveAt $secs -AutoSaveName $name -AutoQuit YES "$@"
  local P=; for i in $(seq 1 20); do P=$(pgrep -nx GoodFlow); [[ -n $P ]] && break; sleep 0.5; done
  sleep 2; $T/rclick winsize $P ${=WIN:-1728 1028} > /dev/null 2>&1
  for i in $(seq 1 $((secs * 2 + 30))); do [[ -f $C/$name.json ]] && break; sleep 0.5; done
  sleep 1; for p in $(pgrep -x GoodFlow); do kill $p; done
  cp $C/$name.json $O/$name.json 2>/dev/null && python3 $SPIKE/tools/frames.py $O/$name.json --design > $O/$name.txt 2>&1
  echo "=== $name ($*)"; [[ -f $O/$name.txt ]] && grep -vE "^\|---" $O/$name.txt | head -16 || echo "NO RECORDING"
}
{
run h-detail-live30 14 -Case Detail
run h-detail-live60 14 -Case Detail -LiveRate 60
run h-detail-liveoff 14 -Case Detail -Live off
run h-detail-reducemotion 14 -Case Detail -SimReduceMotion YES
run h-detail-lowpower 14 -Case Detail -SimLowPower YES
run h-detail-thermal 14 -Case Detail -SimThermal serious
run h-detail-BD50 14 -Case Detail -Variant BD50
run h-cards 15 -Case Cards
run h-cards-nobudget 15 -Case Cards -CardsBudgetMB 0
run h-cards-hover 16 -Case Cards -SimHoverItem 3 -CheckJump YES -SimHoverOffAt 9
run h-cards-hover-BD50 16 -Case Cards -SimHoverItem 3 -CheckJump YES -SimHoverOffAt 9 -Variant BD50
run h-cards-flat 15 -Case Cards -Flat on -SimHoverItem 3 -SimHoverOffAt 9
run h-map 14 -Case Map
run h-map-cap192 14 -Case Map -MapCap 192
run h-map-flat 10 -Case Map -Flat on
} 2>&1 | tee $O/SUMMARY.txt
