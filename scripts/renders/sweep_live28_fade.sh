#!/bin/zsh
# live-28 (A1) — light fade Today vs A (band behind the dateline only) vs B (A + perceptual fade), at T's baked values,
# on the hero-fade fixtures (busy photo · landscape · gradient art · fluted): carousel, grid 2 / 3, Map. For A and B a
# sweep of the band strength × the dateline ink; each config's every text line measured (contrast_fade_live26.py).
#   scripts/renders/sweep_live28_fade.sh <out_dir>
set -uo pipefail
OUT=${1:?out}; H=${0:A:h}; mkdir -p $OUT
run() { local label=$1; shift; [[ -s $OUT/$label.md ]] && { echo "$label: done"; return; }; MODES=${MODES:-light} $H/shoot_live26_fade.sh $OUT/$label $label "$@" >/dev/null 2>&1
  python3 $H/contrast_fade_live26.py $OUT/$label $label > $OUT/$label.md 2>&1; echo "$label: $(/usr/bin/grep -c FAIL $OUT/$label.md) failing cards"; }
MODES="light dark" run today -LightFade today
# CONFIGS="style:ink:band ..." picks the cells (default: the full grid)
if [[ -n ${CONFIGS:-} ]]; then
  for c in ${=CONFIGS}; do IFS=: read st ink b <<< "$c"; run $st-ink$ink-band$b -LightFade $st -DatelineInk $ink -DatelineBand $b; done
  exit 0
fi
for style in band perceptual; do
  for ink in 0.76 0.85 1.0; do
    for b in 0 0.3 0.5 0.7 0.9; do run $style-ink$ink-band$b -LightFade $style -DatelineInk $ink -DatelineBand $b; done
  done
done
