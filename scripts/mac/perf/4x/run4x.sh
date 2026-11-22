#!/bin/zsh
# Sweep 2b · 4.2–4.6 — the real-event proof, BY DAY, on the isolated bench copy (com.doctorpresident.airpad.macA, the
# realistic test library already installed by run.sh install LIB=realistic), nothing else heavy running.
#
#   zsh scripts/mac/kit/build1.sh Perf 2b-4x                       # the bench app (Release + PERFLOG + PANBENCH, DEVSWITCHES)
#   zsh scripts/mac/perf/4x/run4x.sh build/runs/2b-4x/AirPadMacA.app build/runs/2b-4x/proof all
#   (or one of: photos · document · thumbs · keeper)   WIN="1534 920" for T's second window size (default 1703 924).
#
# What each part does (every row graded by grade4x.py from app.log's "[4x]" lines; rperf.txt has the screen timings):
#   photos / document — 2b-4x-<kind>.steps twice: "tstate" = T's focus state (toolbar search field holding text, the
#     Librarian in Search; keyboard focus may still be in the field — Space there types, which is 4.1's question, so a
#     red Space row in tstate goes to 4.1, not here) and "plain" (the same steps without the search lines). Rows:
#     highlight on hover · ␣ hint after a rest · Space opens Quick Look · → / ← step (photos) · Space closes · click =
#     Quick Look · Esc closes · ⌘O opens a copy in Preview (never the stored file; Preview's documents are counted as
#     copy / other in preview-docs.txt and the copies closed). Zoom: z1 double-click = a visible change in rperf.txt;
#     pinch-zoom on a real trackpad = the touch / T.
#   thumbs (4.5) — A: the disk cache emptied, the Cards / List / biggest gallery walk; then a REBUILD of the bench app and
#     B: the same walk on a cold launch. Pass = B shows disk hits and 0 original decodes; the folder stays under 512 MB.
#   keeper (4.6) — the bench library is local (not iCloud), so `-KeeperFakeEvicted YES` marks every 3rd file evicted and
#     sends no request: proves the sweep runs at launch, batches of ≤ 16, off the main thread. Then `-mac.keepDownloaded
#     NO`: no sweep. Real eviction (T's iCloud library) is T's check: Mac feel (testing) shows the last sweep's numbers.
set -u
ROOT=${0:A:h:h:h:h:h}; K=$ROOT/scripts/mac/kit; P=$ROOT/scripts/mac/perf; G=$P/4x/grade4x.py
APP=${1:?bench app}; APP=${APP:A}; OUT=${2:?out}; WHAT=${3:-all}; mkdir -p $OUT; OUT=${OUT:A}
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data; PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
(( $(df -g / | awk 'NR==2 {print $4}') < 15 )) && { echo "free disk under 15 GB: not running"; exit 2 }
zsh $K/unlocked.sh || { echo "screen locked: not running"; exit 3 }
busy=$(pgrep -fl 'xcodebuild|simctl|scripts/librarian/|scripts/gauntlet/|xctrace' | grep -v $$)
[[ -n $busy ]] && { echo "something heavy is running (numbers would be thrown away): $busy"; exit 4 }
caffeinate -d -u -w $$ &
export WIN="${WIN:-1703 924}"
fails=0

preview() {   # counts only (never names): Preview documents that are AirPad's opened copies vs anything else; closes the copies
  pgrep -x Preview >/dev/null || { echo "Preview not running (no ⌘O copy opened)" | tee $1/preview-docs.txt; return }
  osascript -e 'tell application "Preview" to get path of every document' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' \
    | awk '{print (index($0, "/Opened Copies/") > 0 ? "copy" : "other")}' | sort | uniq -c > $1/preview-docs.txt
  osascript -e 'tell application "Preview" to close (every document whose path contains "/Opened Copies/")' >/dev/null 2>&1
  echo "preview: $(tr '\n' ' ' < $1/preview-docs.txt)"
}
grade() { python3 $G "$@" | tee $1/grade.txt; (( ${pipestatus[1]} )) && fails=$((fails + 1)) }

for kind in photos document; do
  [[ $WHAT == all || $WHAT == $kind ]] || continue
  entry=$([[ $kind == photos ]] && echo gallery || echo document)
  for focus in tstate plain; do
    R=$OUT/$kind-$focus; mkdir -p $R
    if [[ $focus == tstate ]]; then cp $P/2b-4x-$kind.steps $R/steps; else grep -vE '^search' $P/2b-4x-$kind.steps > $R/steps; fi
    defaults delete $PREF mac.spaceHint.uses >/dev/null 2>&1   # the ␣ hint shows again
    EXTRA="-Sweep4Log YES -Open4x $entry -Open4xDelay 18" zsh $P/run.sh $APP $R $R/steps > $R/run.txt 2>&1
    preview $R; grade $R $kind
  done
done

if [[ $WHAT == all || $WHAT == thumbs ]]; then
  rm -rf $C/Library/Caches/DisplayImages
  EXTRA="-Sweep4Log YES -Open4x gallery -Open4xDelay 40" zsh $P/run.sh $APP $OUT/thumbs-A $P/2b-4x-thumbs.steps > $OUT/thumbs-A.txt 2>&1
  zsh $K/build1.sh Perf ${TAG_B:-2b-4x-b} | tee $OUT/thumbs-build.txt   # "a cold launch straight after a build"
  APPB=$ROOT/build/runs/${TAG_B:-2b-4x-b}/AirPadMacA.app
  EXTRA="-Sweep4Log YES -Open4x gallery -Open4xDelay 40" zsh $P/run.sh $APPB $OUT/thumbs-B $P/2b-4x-thumbs.steps > $OUT/thumbs-B.txt 2>&1
  grade $OUT/thumbs-B thumbs $OUT/thumbs-A
  echo "disk cache: $(du -sh $C/Library/Caches/DisplayImages | cut -f1) in $(ls $C/Library/Caches/DisplayImages/v1 | wc -l | tr -d ' ') files" | tee -a $OUT/thumbs-B/grade.txt
fi

if [[ $WHAT == all || $WHAT == keeper ]]; then
  EXTRA="-Sweep4Log YES -KeeperFakeEvicted YES" zsh $P/run.sh $APP $OUT/keeper $P/2b-4x-keeper.steps > $OUT/keeper.txt 2>&1
  grade $OUT/keeper keeper
  EXTRA="-Sweep4Log YES -mac.keepDownloaded NO" zsh $P/run.sh $APP $OUT/keeper-off $P/2b-4x-keeper.steps > $OUT/keeper-off.txt 2>&1
  grade $OUT/keeper-off keeper-off
fi
echo "run4x: $fails graded part(s) with a FAIL · $(git -C $ROOT rev-parse --short HEAD) · window $WIN"
exit $(( fails > 0 ))
