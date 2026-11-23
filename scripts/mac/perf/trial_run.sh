#!/bin/zsh
# Sweep 2b · 2.3 — one measured run of the renderer trial (or the SpriteKit Map) with the run conditions checked:
#   trial_run.sh <app> <tag> <steps> [WIN="1728 1029"] [EXTRA="…"]  (env WIN / WINY / EXTRA as run.sh; RPERF_CONTINUOUS passes through)
# Waits until the screen is unlocked and T has been idle ≥ 120 s (polls every 60 s), holds quiet_watch.sh alongside,
# then prints the run's BUSY seconds and the readers (trial_frames.py, map_proof.py). A run with BUSY > 0 is thrown away.
ROOT=${0:A:h:h:h:h}; APP=${1:?app}; TAG=${2:?tag}; STEPS=${3:?steps}; O=$ROOT/build/runs/$TAG; mkdir -p $O
while true; do
  locked=$(ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked)
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  (( locked == 0 && idle >= 120 )) && break
  echo "$(date +%T) waiting: locked=$locked idle=${idle}s"; sleep 60
done
free=$(df -g / | awk 'NR==2 {print $4}'); (( free < 15 )) && { echo "DISK $free GB < 15: not running"; exit 5 }
zsh $ROOT/scripts/mac/perf/quiet_watch.sh $O/quiet.log & QW=$!
WIN=${WIN:-1728 1029} WINY=${WINY:-0} LIBRARIAN=closed TAIL=0 zsh $ROOT/scripts/mac/perf/run.sh $APP $O $STEPS > $O/run.out 2>&1
kill $QW 2>/dev/null
busy=$(grep -c BUSY $O/quiet.log)
echo "== $TAG · $(date +%T) · idle-at-start ${idle}s · free ${free} GB · BUSY seconds $busy · $(head -1 $O/setup.txt)"
[[ -f $O/recording.json ]] || { echo "NO RECORDING"; exit 6 }
python3 $ROOT/scripts/perf/trial_frames.py $O/recording.json > $O/trial.txt 2>&1; cat $O/trial.txt
python3 $ROOT/scripts/perf/map_proof.py $O/recording.json $O/rperf.txt > $O/proof.txt 2>&1
