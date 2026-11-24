#!/bin/zsh
# Sweep 2b · 2.3 renderer trial, scene 2 — the whole matrix in ONE job chain (never two chains at once):
#   trial_cards_batch.sh <app> <prefix> [arms="a b c d cdrift"] [sizes="1703x924 1534x920"]
# Each run waits for an unlocked screen + T idle ≥ 120 s (trial_cards_run.sh). Then process CPU at rest on Cards per arm
# (recorder off; trial_restcpu.sh VIEW=Cards, same idle gate). Prints one line per run; full output in build/runs/<tag>.
ROOT=${0:A:h:h:h:h}; APP=${1:?app}; PFX=${2:?prefix}
ARMS=(${=3:-a b c d cdrift}); SIZES=(${=4:-1703x924 1534x920})
gate() { while true; do
  l=$(ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked); i=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  (( l == 0 && i >= 120 )) && return; sleep 30; done }
for sz in $SIZES; do
  for arm in $ARMS; do
    tag=$PFX-$arm-${sz%%x*}
    WIN="${sz/x/ }" WINY=40 zsh $ROOT/scripts/mac/perf/trial_cards_run.sh $APP $tag $arm > $ROOT/build/runs/$tag.out 2>&1
    head -1 $ROOT/build/runs/$tag.out | grep "==" || tail -2 $ROOT/build/runs/$tag.out
  done
done
for arm in $ARMS; do
  gate
  o=$ROOT/build/runs/$PFX-restcpu; mkdir -p $o; touch $o/.keep
  zsh $ROOT/scripts/mac/perf/quiet_watch.sh $o/quiet-$arm.log & QW=$!
  VIEW=Cards WIN="1703 924" WINY=40 EXTRA="-MacCardsCollection B -MacCardsResize scale -MacCardsClick open -LivingTrial cards -LivingTrialArm $arm" \
    zsh $ROOT/scripts/mac/perf/trial_restcpu.sh $APP "arm $arm 1703" 30 30 | tee -a $o/restcpu.txt
  kill $QW; echo "  BUSY seconds $(grep -c BUSY $o/quiet-$arm.log)" | tee -a $o/restcpu.txt
done
echo BATCH DONE
