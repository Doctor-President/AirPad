#!/bin/zsh
# Mac-vs-iPhone perf parity — the iPhone-SIMULATOR half: one scripted "normal use" session (AirPadUITests/PerfParity,
# real synthesized touches) on a Release bench build with the built-in recorder on from launch, joined to the steps.
#
#   scripts/perf/ios_parity.sh <out dir> [rounds=3]
#
# Writes <out>/recording.json · steps.tsv · table.txt (steps.py's table) · table.json · explain.txt (explain.py --detail)
# · launch.txt (cold launch) · setup.txt · xcodebuild.log. iPhone Simulator on this Mac: NOT device timing.
#
# What it does: builds the bench (Release, -D PERFLOG -D PANBENCH, scheme AirPadPerfParity: the app + the UI tests) →
# makes sure the synthetic perf library exists (seeded once by a Debug build: 265 entries + 6 heavy + 2 light, ffmpeg
# videos) and a WARMED copy of it (the bench app idles on it until it's quiet: cards, vectors, the Map layout) →
# installs the app fresh and puts the warmed copy into the app's bench scratch (Caches/AirPadBenchScratch, where a
# PANBENCH Release roots with -UITestLibrary; never iCloud, never a real library) → runs the session → the test saves the recorder (Darwin
# notification com.airpad.perf.save) → copies the recording out and prints the table.
# Env: SIM_NAME ("CC perf parity"), SKIP_BUILD=1, RESEED=1 (seed the library again), REWARM=1 (warm it again),
# WARM / WARM_MAX / WARM_CPU (the warm-up's minimum, maximum and "quiet" CPU %), WARM_FROM (warm from another copy).
set -u
ROOT=${0:A:h:h:h}
OUT=${1:?usage: ios_parity.sh <out dir> [rounds]}; ROUNDS=${2:-3}
mkdir -p $OUT; OUT=${OUT:A}
B=$ROOT/build/perf-ios; DD=$B/dd; LIB=$B/library; WARMED=$B/library-warm
BID=com.doctorpresident.airpad
NAME=${SIM_NAME:-CC perf parity}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
FLAGS='$(inherited) -Xcc -DACCELERATE_NEW_LAPACK -D PERFLOG -D PANBENCH'
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
mkdir -p $B
log() { print -r -- "[ios_parity] $*" | tee -a $OUT/setup.txt; }
disk() { local f=$(df -g / | awk 'NR==2 {print $4}'); (( f >= 12 )) || { log "DISK: ${f} GB free (< 12): stopping"; exit 4 }; }
: > $OUT/setup.txt
disk

# --- the Simulator (ours alone: created if missing, never another one) ---
UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for k,v in d.items() if 'iOS-27' in k for x in v if x['name']=='$NAME'), ''))")
if [[ -z $UDID ]]; then
  RT=$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-27') and x['isAvailable']]; print(sorted(r, key=lambda x: x['version'])[-1]['identifier'])")
  UDID=$(xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max $RT)
fi
xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b > /dev/null
DEV=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(k.split('.')[-1]+' · '+x['name'] for k,v in d.items() for x in v if x['udid']=='$UDID'))")
log "simulator $UDID ($DEV) · $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet HEAD -- AirPad AirPadUITests || echo +dirty) · rounds $ROUNDS"

container() { xcrun simctl get_app_container $UDID $BID data; }
restore_scheme() { git -C $ROOT diff --quiet -- AirPad.xcodeproj/xcshareddata/xcschemes || git -C $ROOT checkout -- AirPad.xcodeproj/xcshareddata/xcschemes; }

# --- build: the bench app + the UI tests (Release) ---
if [[ -z ${SKIP_BUILD:-} ]]; then
  log "building the bench (Release, PERFLOG + PANBENCH)"
  xcodebuild build-for-testing -project $ROOT/AirPad.xcodeproj -scheme AirPadPerfParity -configuration Release \
    -destination "id=$UDID" -derivedDataPath $DD ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "OTHER_SWIFT_FLAGS=$FLAGS" > $B/build-bench.log 2>&1
  rc=$?; restore_scheme
  (( rc == 0 )) || { grep -E "error:" $B/build-bench.log | head; log "BENCH BUILD FAILED (build/perf-ios/build-bench.log)"; exit 1 }
fi
REL=$DD/Build/Products/Release-iphonesimulator/AirPad.app
XTR=$(ls -t $DD/Build/Products/AirPadPerfParity_iphonesimulator*.xctestrun 2>/dev/null | head -1)
[[ -d $REL && -n $XTR ]] || { log "no bench build in $DD"; exit 1 }

# --- the perf library: seeded once by a Debug build (the seeders are #if DEBUG) ---
if [[ ! -f $LIB/perf-heavy.done || -n ${RESEED:-} ]]; then
  disk; log "seeding the perf library (Debug build)"
  xcodebuild build -project $ROOT/AirPad.xcodeproj -scheme AirPad -configuration Debug -destination "id=$UDID" \
    -derivedDataPath $DD ARCHS=arm64 ONLY_ACTIVE_ARCH=YES > $B/build-debug.log 2>&1 || { restore_scheme; log "DEBUG BUILD FAILED"; exit 1 }
  restore_scheme
  xcrun simctl install $UDID $DD/Build/Products/Debug-iphonesimulator/AirPad.app
  xcrun simctl launch $UDID $BID -UITestLibrary -UITestLibraryFresh -UITestSeedPerfLibrary > /dev/null
  S=$(container)/Library/Caches/AirPadUITestScratch
  for i in $(seq 1 300); do [[ -f $S/perf-heavy.done ]] && break; sleep 2; done; sleep 3
  xcrun simctl terminate $UDID $BID
  [[ -f $S/perf-heavy.done ]] || { log "SEEDING FAILED"; exit 1 }
  rm -rf $LIB $WARMED; ditto $S $LIB
  # The heavy entries' two videos (the seeder names them; ffmpeg draws them): 20 s, 1080p, a moving test card + tone.
  for k in 0 1; do
    [[ -f $B/perf-video-$k.mp4 ]] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=$((330 + 110 * k))" -t 20 -c:v h264_videotoolbox -b:v 8M -c:a aac -pix_fmt yuv420p $B/perf-video-$k.mp4
  done
  for n in 1 2 3 4 5 6; do cp $B/perf-video-0.mp4 $B/perf-video-1.mp4 $LIB/nodes/$(printf '9E9F1000-0000-4000-8000-%012d' $n)/items/; done
  rm -f $LIB/perf-*.done; touch $LIB/perf-heavy.done
fi

# --- a FRESH install of the bench app for every warm-up and every run (an uninstall wipes the app's container, so no
# state from an earlier run is left: preferences, caches, typed text), then the warmed state put back before its first
# launch: the library (Caches/AirPadBenchScratch), its preferences (catalog / block-index fingerprints, Map state) and
# Core ML's compiled-model cache. The warmed state is made once: the bench idles on the Map until the app is quiet.
fresh() {
  xcrun simctl terminate $UDID $BID 2>/dev/null; xcrun simctl uninstall $UDID $BID 2>/dev/null
  xcrun simctl install $UDID $REL || { log "install failed"; exit 1 }
}
lib() { print -r -- "$(container)/Library"; }
if [[ ! -f $WARMED/.warmed || -n ${REWARM:-} ]]; then
  # On the Simulator the embeddings run on the CPU (-EmbedCPUOnly: the default path returns zeros there), so the cards
  # and block vectors of the whole library take a long time: wait until the app's CPU stays under WARM_CPU % for a
  # minute (at least WARM s, at most WARM_MAX s). WARM_FROM=<dir> starts from another copy of the library (a head start).
  disk; log "warming the library from ${WARM_FROM:-$LIB} (≥ ${WARM:-180} s, until the app idles; ≤ ${WARM_MAX:-7200} s)"
  fresh
  ditto ${WARM_FROM:-$LIB} $(lib)/Caches/AirPadBenchScratch; rm -f $(lib)/Caches/AirPadBenchScratch/perf-*.done(N)
  PID=$(xcrun simctl launch $UDID $BID -UITestLibrary -EmbedCPUOnly -ProUnlocked YES -OpenMap $CALLOUTS | awk '{print $NF}')
  t=0; low=0; c=0
  while (( t < ${WARM_MAX:-7200} )); do
    sleep 10; (( t += 10 ))
    c=$(ps -o %cpu= -p $PID 2>/dev/null | tr -d ' '); [[ -z $c ]] && { log "warm-up app exited at $t s"; break }
    (( ${c%.*} < ${WARM_CPU:-25} )) && (( low += 1 )) || low=0
    (( t >= ${WARM:-180} && low >= 6 )) && break
    (( t % 600 == 0 )) && log "  … $t s: app CPU $c %, $(ls $(lib)/Caches/AirPadBenchScratch/nodes/*/blocks.json 2>/dev/null | wc -l | tr -d ' ') block files"
  done
  log "warmed $t s (app CPU $c %; $(ls $(lib)/Caches/AirPadBenchScratch/nodes/*/card.json | wc -l | tr -d ' ') cards, $(ls $(lib)/Caches/AirPadBenchScratch/nodes/*/blocks.json 2>/dev/null | wc -l | tr -d ' ') block files)"
  xcrun simctl terminate $UDID $BID; sleep 3
  rm -rf $WARMED; mkdir -p $WARMED
  ditto $(lib)/Caches/AirPadBenchScratch $WARMED/AirPadBenchScratch
  ditto $(lib)/Caches/$BID $WARMED/caches
  cp $(lib)/Preferences/$BID.plist $WARMED/prefs.plist
  touch $WARMED/.warmed
fi
fresh
mkdir -p $(lib)/Caches $(lib)/Preferences
ditto $WARMED/AirPadBenchScratch $(lib)/Caches/AirPadBenchScratch
ditto $WARMED/caches $(lib)/Caches/$BID
cp $WARMED/prefs.plist $(lib)/Preferences/$BID.plist
log "library: $(ls $(lib)/Caches/AirPadBenchScratch/nodes | wc -l | tr -d ' ') entries (the warmed copy, fresh install)"

# --- the session ---
disk
: > $OUT/steps.tsv; rm -rf $OUT/shots $OUT/result.xcresult $OUT/launch.tsv
SECS=$(( ROUNDS * 1000 + 300 )); (( SECS < 900 )) && SECS=900
log "session: $ROUNDS rounds, recorder window $SECS s"
TEST_RUNNER_PERF_STEPS=$OUT/steps.tsv TEST_RUNNER_PERF_ROUNDS=$ROUNDS TEST_RUNNER_PERF_SECONDS=$SECS TEST_RUNNER_PERF_OUT=$OUT \
  TEST_RUNNER_PERF_APPDATA=$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Data/Application \
  xcodebuild test-without-building -xctestrun $XTR -destination "id=$UDID" -only-testing:AirPadUITests/PerfParity/testSession \
  -collect-test-diagnostics never -resultBundlePath $OUT/result.xcresult > $OUT/xcodebuild.log 2>&1
rc=$?
grep -E "error:|failed|Test Case .* (passed|failed)|SKIPPED|\*\* TEST" $OUT/xcodebuild.log | grep -v "^\s*$" | tail -40 | tee -a $OUT/setup.txt
# The test saves the recording itself before it ends; if the app is still up, ask once more.
REC=$(ls -t $(container)/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1)
if [[ -z $REC ]]; then xcrun simctl spawn $UDID notifyutil -p com.airpad.perf.save; sleep 8; REC=$(ls -t $(container)/Library/Caches/PerfRecordings/*.json 2>/dev/null | head -1); fi
xcrun simctl terminate $UDID $BID 2>/dev/null
[[ -n $REC ]] || { log "NO RECORDING (test exit $rc)"; exit 2 }
cp $REC $OUT/recording.json
log "test exit $rc · $(grep -c . $OUT/steps.tsv) steps · recording $(du -h $OUT/recording.json | cut -f1)"

# --- the numbers ---
python3 $ROOT/scripts/perf/steps.py $OUT/recording.json $OUT/steps.tsv --json $OUT/table.json > $OUT/table.txt 2>&1
python3 $ROOT/scripts/perf/explain.py $OUT/recording.json --detail > $OUT/explain.txt 2>&1
python3 - $OUT/recording.json $OUT/launch.tsv > $OUT/launch.txt <<'EOF'
import json, sys, os
d = json.load(open(sys.argv[1])); off = d["wallOffset"]; ps = d["processStart"]
fr, sp = d["frames"], d["spans"]
ready = None
if os.path.exists(sys.argv[2]):
    for l in open(sys.argv[2]):
        p = l.rstrip("\n").split("\t")
        if p[0] == "launch-ready": ready = float(p[2]) / 1000
first = fr[0][0] if fr else None
screen = next((m for m in d["marks"] if str(m[1]).startswith("screen: ") and m[1] != "screen: launch"), None)
# Quiet: the first moment after the first frame from which the main thread has no busy stretch >= 50 ms for 1 s.
big = sorted(s for s in sp if s[1] >= 50)
quiet = None
if first is not None:
    for c in [first] + [s[0] + s[1] / 1000 for s in big if s[0] + s[1] / 1000 >= first]:
        if not any(c <= s[0] < c + 1.0 for s in big): quiet = c; break
pre = [s for s in big if first is not None and quiet is not None and s[0] < quiet]
f = lambda t: "-" if t is None else f"{(t + off - ps) * 1000:.0f} ms"
print("Cold launch (iPhone Simulator on this Mac: not device timing). From the process start (kernel) to:")
print(f"  first frame drawn                               {f(first)}")
print(f"  first screen named by the app                   {f(screen[0] if screen else None)}  ({screen[1] if screen else '-'})")
print(f"  main thread quiet (no stretch >= 50 ms for 1 s) {f(quiet)}  ({len(pre)} stretches >= 50 ms before it, longest {max([s[1] for s in pre], default=0):.0f} ms)")
print(f"  UI test saw the first screen                    {'-' if ready is None else f'{(ready - ps) * 1000:.0f} ms'}  (XCUITest's view; includes its polling)")
EOF
{ print "iPhone Simulator on this Mac: not device timing · $DEV"; cat $OUT/launch.txt; print; sed -n '1,/^$/p' $OUT/table.txt; grep '^|' $OUT/table.txt; } | tee $OUT/summary.txt
exit $rc
