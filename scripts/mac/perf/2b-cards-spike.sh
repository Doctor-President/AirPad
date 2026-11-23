#!/bin/zsh
# Sweep 2b · 2.2 — the Cards spike's speed rows: today / arm A / arm B (re-lay out) / arm B (scale, then settle), each at
# T's two window sizes, with real events, on the realistic library (the baselines' conditions: Release bench copy, LPM
# off, on the adapter, nothing else heavy — check quiet_watch.sh first; hold caffeinate -d -u for the whole run).
#   2b-cards-spike.sh <isolated Perf .app> <out root> [arms…]      arms default: today A Brelayout Bscale
# One run.sh per arm × size → <out root>/<arm>-<width>/ (rperf.txt, recording.json, explain.txt), then a rest.sh per
# arm (its `library-cards` row is the rest = 0 frames check) → <out root>/<arm>-rest/. ~4 min per run, ~40 min in all.
set -u
ROOT=${0:A:h:h:h:h}; APP=${1:?bench app}; OUT=${2:?out root}; shift 2
ARMS=("$@"); (( ${#ARMS} )) || ARMS=(today A Brelayout Bscale)   # (${@:-a b} would be ONE word in zsh: one run, no arm flags)
mkdir -p $OUT
[[ -f ~/Library/Containers/com.doctorpresident.airpad.macA/Data/Documents/AirPad/.k3-library ]] || echo "WARNING: the realistic library is not installed (LIB=realistic run.sh install …)"
args() {
  case $1 in
    today)     print -- "-MacCardsCollection today" ;;
    A)         print -- "-MacCardsCollection A" ;;
    Brelayout) print -- "-MacCardsCollection B -MacCardsResize relayout -MacCardsClick open" ;;
    Bscale)    print -- "-MacCardsCollection B -MacCardsResize scale -MacCardsClick open" ;;
  esac
}
for arm in $ARMS; do
  for size in "1703 924" "1534 920"; do
    o=$OUT/$arm-${size%% *}
    echo "== $arm $size → $o"
    WIN="$size" WINY=40 EXTRA="$(args $arm)" TAIL=60 zsh $ROOT/scripts/mac/perf/run.sh $APP $o $ROOT/scripts/mac/perf/2b-cards-spike.steps > $o.log 2>&1
    grep -E "^\| (view-cards|cards-)" $o/explain.txt 2>/dev/null || tail -5 $o.log
  done
  EXTRA="$(args $arm)" zsh $ROOT/scripts/mac/perf/rest.sh $APP $OUT/$arm-rest > $OUT/$arm-rest.log 2>&1
  grep -E "library-cards" $OUT/$arm-rest/rest.txt 2>/dev/null
done
