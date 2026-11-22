#!/bin/zsh
# Sweep 2b · 3.3 — the Mac side of the iPhone spike: the SAME battery (Shared/) on this Mac, Apple Intelligence and
# the same Qwen3.5 4B weights through MLX, so grade.py can set phone against Mac.
#
#   spikes/iphone-2b/run_mac.sh [--dry-run] [--phases all|apple|mlx] [--repeats 6] [--mlx-repeats 3] [--no-build] [--force]
#
# Results: build/iphone-spike/results/mac/spike-results.json (dry run: results/mac-dry/), graded into answers.md.
# A real run REFUSES while the overnight proof (scripts/librarian/2b_proof.sh) runs or has not written
# build/2b-proof/DONE: model calls beside it would skew both. --dry-run calls no model and is always allowed.
set -uo pipefail
ROOT=${0:A:h:h:h}
SPIKE=$ROOT/spikes/iphone-2b
B=$ROOT/build/iphone-spike
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DRY=0; BUILD=1; FORCE=0; PASS=()
while (( $# )); do
  case $1 in
    --dry-run) DRY=1; PASS+=(--dry-run) ;;
    --no-build) BUILD=0 ;;
    --force) FORCE=1 ;;
    --phases|--repeats|--mlx-repeats) PASS+=($1 $2); shift ;;
    *) echo "unknown option $1"; exit 64 ;;
  esac
  shift
done
OUT=$B/results/$( (( DRY )) && echo mac-dry || echo mac )

if (( ! DRY )); then
  if pgrep -f "scripts/librarian/2b_proof.sh" > /dev/null; then echo "REFUSED: 2b_proof.sh is running (model calls now would skew it)"; exit 2; fi
  if [[ -d $ROOT/build/2b-proof && ! -e $ROOT/build/2b-proof/DONE ]] && (( ! FORCE )); then
    echo "REFUSED: build/2b-proof exists without DONE (the proof has not finished); --force once it is known dead"; exit 2
  fi
fi
avail_gb=$(df -g / | awk 'NR==2 {print $4}')
(( avail_gb >= 15 )) || { echo "REFUSED: only ${avail_gb} GB free"; exit 2; }

if (( BUILD )); then
  echo "building spike-mac (Release)"
  xcodebuild -project $SPIKE/Spike2b.xcodeproj -scheme spike-mac -configuration Release -destination 'platform=macOS' \
    -derivedDataPath $B/dd -clonedSourcePackagesDirPath $B/spm build > $B/build-mac.log 2>&1 \
    || { grep -E "error:" $B/build-mac.log | head -20; echo "build failed ($B/build-mac.log)"; exit 3; }
fi
BIN=$B/dd/Build/Products/Release/spike-mac
[[ -x $BIN ]] || { echo "no $BIN"; exit 3; }
cd $ROOT
caffeinate -i $BIN $PASS --out $OUT --model-dir $B/models/Qwen3.5-4B-MLX-4bit || { echo "spike-mac failed"; exit 4; }
python3 -I $SPIKE/grade.py --mac $OUT/spike-results.json --out $OUT/answers.md > /dev/null && echo "answers: $OUT/answers.md"
