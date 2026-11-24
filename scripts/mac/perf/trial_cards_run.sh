#!/bin/zsh
# Sweep 2b · 2.3 renderer trial, scene 2 — one measured Cards run of one arm with the run conditions checked:
#   trial_cards_run.sh <app> <tag> <arm a|b|c|d|cdrift> [steps=2b-trial-cards.steps]   (env WIN="1703 924" WINY=40, EXTRA adds args)
# Waits until the screen is unlocked and T has been idle ≥ 120 s (polls every 60 s), holds quiet_watch.sh alongside, marks
# the run folder .keep (build1.sh prunes unkept runs), then prints BUSY seconds, steps.py's table and trial_cards.py.
# Librarian open (the Cards spike's layout). Arm B host, scale-then-settle, click opens (the spike's 2c recommendation).
ROOT=${0:A:h:h:h:h}; APP=${1:?app}; TAG=${2:?tag}; ARM=${3:?arm}; STEPS=${4:-$ROOT/scripts/mac/perf/2b-trial-cards.steps}
O=$ROOT/build/runs/$TAG; mkdir -p $O; touch $O/.keep
while true; do
  locked=$(ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked)
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  (( locked == 0 && idle >= 120 )) && break
  echo "$(date +%T) waiting: locked=$locked idle=${idle}s"; sleep 60
done
free=$(df -g / | awk 'NR==2 {print $4}'); (( free < 15 )) && { echo "DISK $free GB < 15: not running"; exit 5 }
zsh $ROOT/scripts/mac/perf/quiet_watch.sh $O/quiet.log & QW=$!
A="-MacCardsCollection B -MacCardsResize scale -MacCardsClick open -LivingTrial cards -LivingTrialArm $ARM ${EXTRA:-}"
WIN=${WIN:-1703 924} WINY=${WINY:-40} LIBRARIAN=${LIBRARIAN:-open} TAIL=0 EXTRA="$A" zsh $ROOT/scripts/mac/perf/run.sh $APP $O $STEPS > $O/run.out 2>&1
kill $QW 2>/dev/null
busy=$(grep -c BUSY $O/quiet.log)
echo "== $TAG · arm $ARM · $(date +%T) · idle-at-start ${idle}s · free ${free} GB · BUSY seconds $busy · $(head -1 $O/setup.txt)"
[[ -f $O/recording.json ]] || { echo "NO RECORDING"; exit 6 }
grep -E "^\| (view-cards|cards-)" $O/explain.txt
python3 $ROOT/scripts/perf/trial_cards.py $O/recording.json $O/rperf.txt > $O/cards.txt 2>&1; cat $O/cards.txt
