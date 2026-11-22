#!/bin/zsh
# Sweep 2b · 3.1 — one suite run: one cases file, one route, one model, on the Simulator. bench.sh's launch (read, not
# edited: the proof reads that file tonight), plus the library "planted" = the bench library seeded with the suite's
# notes overlay (SUITE_NOTES, written by `suite.py overlay`) instead of benchmark/notes.json.
#
#   zsh scripts/librarian/suite/launch.sh <apple|server> <model|-> <cases.json> <out-dir> [--fresh]
#
# Env: SUITE_SIM (udid), SUITE_APP (the after build, read only), SUITE_OLLAMA (CC's own, default 127.0.0.1:11500),
# SUITE_NOTES (overlay), SUITE_FIXTURE, SUITE_TIMEOUT (s). Never 11434 / 1234.
set -u
cd ${0:A:h:h:h:h}
route=$1; model=$2; cases=${3:A}; out=${4:A}; fresh=0
[[ ${5:-} == --fresh ]] && fresh=1
SIM=${SUITE_SIM:-$(cat build/sweep2a/sim.udid)}
APP=${SUITE_APP:-$PWD/build/DD-2b/Build/Products/Debug-iphonesimulator/AirPad.app}
OLL=${SUITE_OLLAMA:-http://127.0.0.1:11500}
[[ $OLL == *:11434* || $OLL == *:1234 || $OLL == *:1234/* ]] && { echo "refusing: $OLL is T's server port"; exit 2 }
mkdir -p $out
library=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('library','bench'))" $cases)
args=(-EmbedCPUOnly -LibrarianBench $cases -LibrarianBenchOut $out -ResetLibrarianRoute YES)
case $library in
  bench)   args+=(-UITestLibrary -UITestSeedPerfLibrary -UITestSeedBenchNotes ${0:A:h:h}/benchmark/notes.json) ;;
  planted) [[ -f ${SUITE_NOTES:-} ]] || { echo "SUITE_NOTES (the overlay) missing"; exit 2 }
           args+=(-UITestLibrary -UITestSeedPerfLibrary -UITestSeedBenchNotes ${SUITE_NOTES:A}) ;;
  sample)  args+=(-SampleSeedDemo) ;;
  fixture) args+=(-CorpusFixture ${SUITE_FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}); (( fresh )) && args+=(-CorpusFixtureFresh) ;;
  *) echo "unknown library $library"; exit 2 ;;
esac
[[ $library == (bench|planted) ]] && (( fresh )) && args+=(-UITestLibraryFresh)
case $route in
  apple)  ;;
  server) args+=(-DebugEndpointURL $OLL -DebugEndpointModel $model) ;;
  *) echo "route must be apple or server"; exit 2 ;;
esac
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1
xcrun simctl install $SIM $APP || exit 3
rm -f $out/results.json
log=$out/app.log
xcrun simctl launch --console-pty --terminate-running-process $SIM com.doctorpresident.airpad "${args[@]}" > $log 2>&1 &
launcher=$!
deadline=$(( $(date +%s) + ${SUITE_TIMEOUT:-7200} ))
while ! grep -q "\[LibrarianBench\] done" $log 2>/dev/null; do
  (( $(date +%s) > deadline )) && { echo "TIMEOUT"; break }
  kill -0 $launcher 2>/dev/null || { sleep 2; grep -q "\[LibrarianBench\] done" $log || echo "APP EXITED before done"; break }
  sleep 3
done
xcrun simctl terminate $SIM com.doctorpresident.airpad > /dev/null 2>&1
kill $launcher 2>/dev/null
grep -E "\[LibrarianBench\] (index|START|RESULT|ABORT)" $log | sed 's/^.*\[LibrarianBench\]/[suite]/' | cut -c1-160
[[ -f $out/results.json ]] && grep -q "\[LibrarianBench\] done" $log
