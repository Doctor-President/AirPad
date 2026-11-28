#!/bin/zsh
# Good Flow spike · the whole Mac real-event matrix (design §3), for when the screen is UNLOCKED and T is not using the Mac.
#   tools/mac_all.sh [--dry]      about 40 minutes; holds one stay-awake (caffeinate -di) for the whole real-event phase
# Per case × window (1728 × 1028, 1703 × 924) × 3 runs ≥ 15 s of input + the 10 s rest row; the flat control beside (a)
# and (b); the live rows; process CPU at rest over 30 s. Then tools/frames.py summarises every run (build/mac-runs/SUMMARY.md).
set -u
SPIKE=${0:A:h:h}; R=$SPIKE/tools/mac_run.sh; CPU=$SPIKE/tools/mac_restcpu.sh
DRY=(); [[ ${1:-} == --dry ]] && DRY=(--dry)
if (( ! ${#DRY} )); then caffeinate -di -w $$ & fi
STAMP=$(date +%m%d-%H%M)
for W in "1728 1028" "1703 924"; do
  WT=${W// /x}
  for n in 1 2 3; do
    for c in map detail cards; do WIN=$W zsh $R $DRY $c $STAMP-$c-$WT-r$n; done
    for c in detail cards; do WIN=$W ARGS="-Flat on" zsh $R $DRY $c $STAMP-$c-flat-$WT-r$n; done
    (( ${#DRY} )) && break
  done
  (( ${#DRY} )) && break
done
# live rows (full screen): detail at rest with live 30 / 60 / flat-live; the hovered card resting
WIN="1728 1028" zsh $R $DRY detail $STAMP-detail-live30 $SPIKE/tools/steps/rest.steps
WIN="1728 1028" ARGS="-LiveRate 60" zsh $R $DRY detail $STAMP-detail-live60 $SPIKE/tools/steps/rest.steps
WIN="1728 1028" ARGS="-Live off" zsh $R $DRY detail $STAMP-detail-liveoff $SPIKE/tools/steps/rest.steps
WIN="1728 1028" ARGS="-Flat on" zsh $R $DRY detail $STAMP-detail-flatlive $SPIKE/tools/steps/rest.steps
WIN="1728 1028" zsh $R $DRY cards $STAMP-cards-live $SPIKE/tools/steps/cards-live.steps
for v in BD50 BD75 B; do WIN="1728 1028" ARGS="-Variant $v" zsh $R $DRY detail $STAMP-detail-live30-$v $SPIKE/tools/steps/rest.steps; done
# round 2 controls (full screen): the Map with every orb Good Flow (round 1's state) beside the reveal rows above; the
# detail band at the round-1 pool route (shader hash) beside the pool-table default
for n in 1 2; do WIN="1728 1028" ARGS="-Reveal off" zsh $R $DRY map $STAMP-map-revealoff-r$n; (( ${#DRY} )) && break; done
WIN="1728 1028" ARGS="-Pools shader" zsh $R $DRY detail $STAMP-detail-poolsshader
# process CPU at rest (30 s)
if (( ! ${#DRY} )); then
  {
    zsh $CPU map map-rest
    zsh $CPU cards cards-nothing-hovered
    HOVER=400,300 zsh $CPU cards cards-hovered-live
    HOVER=400,300 ARGS="-Flat on" zsh $CPU cards cards-hovered-flatlive
    HOVER=400,300 ARGS="-Live off" zsh $CPU cards cards-hovered-still
    zsh $CPU detail detail-live30
    ARGS="-Live off" zsh $CPU detail detail-still
    ARGS="-Flat on" zsh $CPU detail detail-flatlive
    ARGS="-Variant BD50" zsh $CPU detail detail-live30-BD50
  } | tee $SPIKE/build/mac-runs/$STAMP-cpu.txt
fi
python3 $SPIKE/tools/frames.py --summary $SPIKE/build/mac-runs/$STAMP-* > $SPIKE/build/mac-runs/$STAMP-SUMMARY.md 2>&1
echo "summary: $SPIKE/build/mac-runs/$STAMP-SUMMARY.md"
