#!/bin/zsh
# Mac batch A — stills of the ISOLATED Mac copy (Sample Library scratch), light + dark, one launch per screen. The
# window is drawn in-process (DEBUG -MacSnapshot) so it works with the screen locked.
#   shoot_mac.sh <isolated .app> <out_dir>      (WIN=1440x900 pins the window size; LOOKS="light dark")
set -uo pipefail
APP=${1:?app}; OUT=${2:?out}; S=${S:-14}; mkdir -p $OUT
SHOTS=~/Library/Containers/com.doctorpresident.airpad.macA/Data/tmp/macshots
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
BASE=(-ApplePersistenceIgnoreState YES -UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -GlassFreezeTime 5 $CALLOUTS)
RUN=$(date +%s)
WINA=(); [[ -n ${WIN:-} ]] && WINA=(-MacWindowSize $WIN)
for G in ${=LOOKS:-light dark}; do
  for V in ${=VIEWS:-dashboard map list cards entry chats settings librarian}; do
    case $V in
      dashboard) VA=(-OpenDashboard);; map) VA=(-OpenMap);; list) VA=(-OpenListView);; cards) VA=(-OpenCardView);;
      entry) VA=(-OpenFirstGradientEntry);; chats) VA=(-OpenMap -OpenChatsList);; settings) VA=(-OpenMap -OpenSettings root);; models) VA=(-OpenMap -OpenSettings models);;
      librarian) VA=(-OpenMap -OpenLibrarian);; recents) VA=();;
    esac
    $APP/Contents/MacOS/AirPad $BASE $VA $WINA -appearance.override $G -MacSnapshot $V-$G-$RUN -MacSnapshotAfter $S > $OUT/$V-$G.out 2> $OUT/$V-$G.err &
    PID=$!
    for i in {1..40}; do [[ -f $SHOTS/$V-$G-$RUN.png ]] && break; sleep 1; done
    sleep 1
    if [[ -f $SHOTS/$V-$G-$RUN.png ]]; then cp $SHOTS/$V-$G-$RUN.png $OUT/$V-$G.png; for f in $SHOTS/$V-$G-$RUN-sheet*.png(N); do cp $f $OUT/$V-$G-sheet${f##*-sheet}; done; echo "$V-$G ok"; else echo "$V-$G NO SHOT"; fi
    kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1
  done
done
