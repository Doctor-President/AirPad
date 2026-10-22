#!/bin/zsh
# live-37 (4) — the SMOKE SET (scripts/live/set-smoke.json, 15 questions) on one tier, one command:
#   scripts/live/smoke.sh <apple|4b|8b|30b> [--retrieval] [--off query,selection,boilerplate,title] [out_dir]
# --retrieval: no UI, no answers — the app runs each turn's query, fetch and selection (`-WebRetrievalRun`) and the
#   grader checks "is the gold fact in the evidence the model would get?". Minutes, no Host, no model.
# without it: the answer run through the real UI (scripts/live/regress.sh with the smoke set; the Host tiers quit T's
#   Host and restore + VERIFY it).
# --off: the live-37 fixes to leave out (DEBUG `-Live37Off`): the before / step-by-step measurements on one build.
# env: REGRESS_BUILD=1 builds first; REGRESS_BUILD_DIR as regress.sh.
set -uo pipefail
TIER=${1:?apple|4b|8b|30b}; shift
RETR=0; OFF=""; OUTARG=""
while (( $# )); do case $1 in --retrieval) RETR=1;; --off) OFF=$2; shift;; *) OUTARG=$1;; esac; shift; done
AIRPAD=${0:A:h:h:h}; BUILD=${REGRESS_BUILD_DIR:-$AIRPAD/build}
SET=$AIRPAD/scripts/live/set-smoke.json
if (( ! RETR )); then
  REGRESS_SET=$SET REGRESS_EXTRA_ARGS="${OFF:+-Live37Off $OFF}" exec $AIRPAD/scripts/live/regress.sh $TIER ${OUTARG:-$BUILD/smoke-runs/$(date +%Y%m%d-%H%M%S)-$TIER${OFF:+-off-$OFF}}
fi
OUT=${OUTARG:-$BUILD/smoke-runs/$(date +%Y%m%d-%H%M%S)-retrieval-$TIER${OFF:+-off-$OFF}}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
SIM=${LIVE_SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; BUNDLE=com.doctorpresident.airpad
APP=$BUILD/dd-regress/Build/Products/Debug-iphonesimulator/AirPad.app
if [[ ${REGRESS_BUILD:-0} == 1 || ! -d $APP ]]; then
  (cd $AIRPAD && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirPad.xcodeproj -scheme AirPad \
     -configuration Debug -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $BUILD/dd-regress build-for-testing > "$OUT/build.log" 2>&1) \
    || { echo "[smoke] build FAILED — $OUT/build.log"; exit 1; }
  git -C $AIRPAD checkout -- AirPad.xcodeproj/xcshareddata 2>/dev/null
fi
git -C $AIRPAD rev-parse --short HEAD > "$OUT/commit.txt"
KEY=$(security find-generic-password -s airpad-live-tavily -w 2>/dev/null)
[[ -z $KEY ]] && { echo "[smoke] can't read the Keychain item airpad-live-tavily"; exit 1; }
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
xcrun simctl install $SIM "$APP" || exit 1
DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data)
mkdir -p "$DATA/tmp"; rm -f "$DATA/tmp/webtrace.jsonl"; cp "$SET" "$DATA/tmp/set-smoke.json"
T0=$(date +%s)
xcrun simctl launch --console $SIM $BUNDLE -UITestLibrary -UITestLibraryFresh -EmbedCPUOnly -WebTrace YES -webSearchEnabled YES \
  -WikipediaLive YES -webSearchProvider tavily -TavilyTestKey "$KEY" -WebRetrievalRun "$DATA/tmp/set-smoke.json" -RetrievalTier $TIER \
  ${OFF:+-Live37Off} ${OFF:+$OFF} > "$OUT/app.log" 2>&1 &
LPID=$!
KEY=""; unset KEY
for i in {1..600}; do /usr/bin/grep -q "\[WebRetrievalRun\]" "$OUT/app.log" 2>/dev/null && break; sleep 1; done
xcrun simctl terminate $SIM $BUNDLE 2>/dev/null; kill $LPID 2>/dev/null
/usr/bin/grep -h "\[WebRetrievalRun\]" "$OUT/app.log" | sed 's/.*\[WebRetrievalRun\]/[WebRetrievalRun]/' | tee "$OUT/run.txt"
echo "wall $(( $(date +%s) - T0 )) s" | tee -a "$OUT/run.txt"
cp "$DATA/tmp/webtrace.jsonl" "$OUT/webtrace.jsonl"
rm -f "$OUT/app.log"   # its launch line can't carry the key, but nothing else is needed from it
LABEL="retrieval-only · $TIER${OFF:+ · off: $OFF}"
RETRIEVAL_ONLY=1 python3 $AIRPAD/scripts/live/regress.py "$SET" "$OUT/webtrace.jsonl" "$OUT" "$LABEL @ $(cat $OUT/commit.txt)"
echo "[smoke] $OUT/{summary.md,table.md,grades.json}"
