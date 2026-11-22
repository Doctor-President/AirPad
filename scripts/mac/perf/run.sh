#!/bin/zsh
# Mac perf audit — one measured run of the isolated copy with REAL events and the built-in recorder.
#   run.sh <isolated .app> <out dir> <steps file> [rounds=1]
# The app runs on the synthetic perf library (265 entries + 6 heavy + 2 light; `install` below), at 1,350 × 840 at
# (0,160), sidebar shown, Librarian docked (LIBRARIAN=closed to close it). rperf posts the steps and times what the
# screen shows; the app's recorder (-PerfRecorder) keeps the whole session and is saved at the end:
#   <out>/rperf.txt  steps.csv  recording.json  explain.txt  app.log
# EXTRA="-Key value …" adds launch arguments (e.g. -ProUnlocked YES in a PANBENCH bench build, -MacPerfAB x).
# PROFILE=1 also records Time Profiler + Hangs (xctrace) to <out>/session.trace.
#   run.sh install <isolated DEBUG .app>   seeds the perf library (once) and installs it into the copy's Documents
#   run.sh restore                         puts the copy's own library back
set -u
ROOT=${0:A:h:h:h:h}; H=$ROOT/scripts/mac/realclick; B=$ROOT/build/mac-perf
C=~/Library/Containers/com.doctorpresident.airpad.macA/Data
SEED=$C/Library/Caches/AirPadUITestScratch
PREF=$C/Library/Preferences/com.doctorpresident.airpad.macA
for t in rclick rperf locked; do [[ $B/$t -nt $H/$t.swift ]] || swiftc -O -o $B/$t $H/$t.swift 2>/dev/null; done
R=$B/rclick

if [[ ${1:-} == restore ]]; then
  [[ -d $C/Documents/AirPad.k3-backup ]] && { rm -rf $C/Documents/AirPad; mv $C/Documents/AirPad.k3-backup $C/Documents/AirPad; echo restored; }; exit
fi
if [[ ${1:-} == install && ${LIB:-} == realistic ]]; then
  # Sweep 2b 0.2: the library shaped like T's (seedUITestRealisticLibrary; shape from library_shape.py, content synthetic).
  APP=${2:?debug app}; mkdir -p $B $C/Library/Caches
  cp $ROOT/scripts/mac/perf/realistic-corpus.txt $C/Library/Caches/realistic-corpus.txt
  if [[ ! -f $SEED/realistic-library.done ]]; then
    $APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -UITestLibrary -UITestLibraryFresh -UITestSeedRealisticLibrary > $B/seed-realistic.log 2>&1 & S=$!
    for i in $(seq 1 900); do [[ -f $SEED/realistic-library.done ]] && break; sleep 1; done; sleep 2; kill $S 2>/dev/null
    [[ -f $SEED/realistic-library.done ]] || { echo "seeding failed (see $B/seed-realistic.log)"; exit 1 }
    for k in 0 1; do
      [[ -f $B/perf-video-$k.mp4 ]] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=$((330 + 110 * k))" -t 20 -c:v h264_videotoolbox -b:v 8M -c:a aac -pix_fmt yuv420p $B/perf-video-$k.mp4
    done
    k=0; for v in ${(f)"$(cat $SEED/realistic-videos.txt)"}; do cp $B/perf-video-$((k % 2)).mp4 $SEED/$v; k=$((k+1)); done
  fi
  [[ -d $C/Documents/AirPad.k3-backup ]] || mv $C/Documents/AirPad $C/Documents/AirPad.k3-backup
  rm -rf $C/Documents/AirPad; ditto $SEED $C/Documents/AirPad; rm -f $C/Documents/AirPad/*.done
  echo "installed $(ls $C/Documents/AirPad/nodes | wc -l | tr -d ' ') entries (realistic); $(du -sh $C/Documents/AirPad | cut -f1)"
  REL=${3:-}; [[ -n $REL ]] && { $REL/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $B/warmup.log 2>&1 & W=$!; sleep ${WARM:-180}; kill $W; sleep 2 }
  touch $C/Documents/AirPad/.k3-installed; echo realistic > $C/Documents/AirPad/.k3-library; exit
fi
if [[ ${1:-} == install ]]; then
  APP=${2:?debug app}
  if [[ ! -f $SEED/perf-heavy.done ]]; then
    FRESH=(); [[ -f $SEED/perf-library.done ]] || FRESH=(-UITestLibraryFresh)
    $APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -UITestLibrary $FRESH -UITestSeedPerfLibrary > $B/seed.log 2>&1 & S=$!
    for i in $(seq 1 240); do [[ -f $SEED/perf-heavy.done ]] && break; sleep 1; done; sleep 2; kill $S 2>/dev/null
    [[ -f $SEED/perf-heavy.done ]] || { echo "seeding failed (see $B/seed.log)"; exit 1 }
    # The heavy entries' two videos (the seeder names them; ffmpeg draws them): 20 s, 1080p, a moving test card + tone.
    for n in 1 2 3 4 5 6; do
      d=$SEED/nodes/$(printf '9E9F1000-0000-4000-8000-%012d' $n)/items
      for k in 0 1; do
        [[ -f $B/perf-video-$k.mp4 ]] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=$((330 + 110 * k))" -t 20 -c:v h264_videotoolbox -b:v 8M -c:a aac -pix_fmt yuv420p $B/perf-video-$k.mp4
        cp $B/perf-video-$k.mp4 $d/perf-video-$k.mp4
      done
    done
  fi
  [[ -d $C/Documents/AirPad.k3-backup ]] || mv $C/Documents/AirPad $C/Documents/AirPad.k3-backup
  rm -rf $C/Documents/AirPad; ditto $SEED $C/Documents/AirPad; rm -f $C/Documents/AirPad/perf-*.done
  echo "installed $(ls $C/Documents/AirPad/nodes | wc -l | tr -d ' ') entries; warming up ${WARM:-180} s (cards, vectors, layout)"
  REL=${3:-}; [[ -n $REL ]] && { $REL/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES > $B/warmup.log 2>&1 & W=$!; sleep ${WARM:-180}; kill $W; sleep 2 }
  touch $C/Documents/AirPad/.k3-installed; exit
fi

APP=${1:?app}; OUT=${2:?out}; STEPS=${3:?steps}; ROUNDS=${4:-1}; mkdir -p $OUT; OUT=${OUT:A}
[[ -f $C/Documents/AirPad/.k3-installed ]] || { echo "perf library not installed (run.sh install <debug app> <release app>)"; exit 1 }
[[ $($B/locked) == "locked 1"* ]] && { echo "LOCKED: not running" | tee $OUT/setup.txt; exit 3 }
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
pkill -f "AirPadMacA.app/Contents/MacOS/AirPad"; sleep 1
rm -rf $C/Library/Caches/PerfRecordings
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES -PerfRecorder YES -PerfRecorderSeconds ${SECONDS_KEPT:-900} ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 8; for i in $(seq 1 30); do [[ $($R winpos $P) != *"0×0"* ]] && break; sleep 1; done
$R winmove $P 0 160 >/dev/null; $R winsize $P ${=WIN:-1350 840} >/dev/null; sleep 1
[[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }
LIB=$($R get $P toolbar.librarian AXValue)
[[ ${LIBRARIAN:-open} == open && $LIB != Open ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
[[ ${LIBRARIAN:-open} == closed && $LIB == Open ]] && { $R click $P toolbar.librarian >/dev/null; sleep 1 }
$R click $P sidebar.library >/dev/null; sleep 3
echo "nodes $(ls $C/Documents/AirPad/nodes | wc -l | tr -d ' ') · window $($R winpos $P) · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet || echo +dirty) · powermode $(pmset -g | awk '/powermode/ {print $2}') · EXTRA ${EXTRA:-}" > $OUT/setup.txt
X=
if [[ -n ${PROFILE:-} ]]; then
  xcrun xctrace record --template 'Time Profiler' --instrument 'Hangs' --time-limit ${TL:-300}s --attach $P --output $OUT/session.trace --no-prompt > $OUT/xctrace.log 2>&1 & X=$!
  ( while kill -0 $X 2>/dev/null; do (( $(df -g / | awk 'NR==2 {print $4}') < 12 )) && { echo "DISK GUARD: stopping xctrace" >> $OUT/setup.txt; kill -9 $X; pkill -9 -f DTServiceHub; }; sleep 2; done ) &
  sleep 4
fi
: > $OUT/steps-all.steps; for i in $(seq 1 $ROUNDS); do grep -v '^#' $STEPS >> $OUT/steps-all.steps; done
RPERF_CSV=$OUT/steps.csv $B/rperf $P $OUT/steps-all.steps > $OUT/rperf.txt 2>&1
sleep ${REST:-3}
ps -o %cpu= -p $P >> $OUT/setup.txt
notifyutil -p com.airpad.perf.save; sleep 3
REC=$(ls -t $C/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1)
[[ -n $REC ]] && cp $REC $OUT/recording.json || echo "NO RECORDING" >> $OUT/setup.txt
[[ -n $X ]] && wait $X 2>/dev/null
kill $P 2>/dev/null; trap - EXIT
[[ -f $OUT/recording.json ]] && python3 $ROOT/scripts/perf/steps.py $OUT/recording.json $OUT/rperf.txt --json $OUT/table.json > $OUT/explain.txt 2>&1
cat $OUT/setup.txt; tail -${TAIL:-40} $OUT/explain.txt
