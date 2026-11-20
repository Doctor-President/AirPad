#!/bin/zsh
# Sweep 2a — run the Librarian benchmark once: one library, one route, one model. Simulator only (no clicks).
#
#   zsh scripts/librarian/bench.sh <apple|server|host> <model|-> <cases.json> <out-dir> [--fresh] [--only F1,G2] [-- extra launch args]
#
# server: CC's OWN Ollama (BENCH_OLLAMA, default http://127.0.0.1:11500 — never 11434, never T's servers).
# host:   a scratch Host already running (BENCH_HOST_URL / BENCH_HOST_SECRET / BENCH_HOST_PUBKEY), pointed at that Ollama.
# apple:  Apple Intelligence through the Simulator (the Mac's on-device model).
# Library comes from the cases file ("library": bench | sample | fixture). The scratch library is kept between runs;
# --fresh re-seeds it (the first run of a session). Env: BENCH_SIM (udid), BENCH_APP (Debug .app), BENCH_TIMEOUT (s).
set -u
cd ${0:A:h}/../..
route=$1; model=$2; cases=${3:A}; out=${4:A}; shift 4
fresh=0; only=""; extra=()
while (( $# )); do
  case $1 in
    --fresh) fresh=1 ;;
    --only) only=$2; shift ;;
    --) shift; extra=("$@"); break ;;
  esac
  shift
done
SIM=${BENCH_SIM:-$(cat build/sweep2a/sim.udid)}
APP=${BENCH_APP:-build/DD-2a/Build/Products/Debug-iphonesimulator/AirPad.app}
OLL=${BENCH_OLLAMA:-http://127.0.0.1:11500}
[[ $OLL == *:11434* || $OLL == *:1234* ]] && { echo "refusing: $OLL is T's server port"; exit 2 }
mkdir -p $out
library=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('library','bench'))" $cases)
args=(-EmbedCPUOnly -LibrarianBench $cases -LibrarianBenchOut $out -ResetLibrarianRoute YES)
case $library in
  bench)   args+=(-UITestLibrary -UITestSeedPerfLibrary -UITestSeedBenchNotes ${0:A:h}/benchmark/notes.json); (( fresh )) && args+=(-UITestLibraryFresh) ;;
  sample)  args+=(-SampleSeedDemo) ;;
  fixture) args+=(-CorpusFixture ${BENCH_FIXTURE:-$HOME/Developer/fixtures/tom-corpus-2026-09-21}); (( fresh )) && args+=(-CorpusFixtureFresh) ;;
  *) echo "unknown library $library"; exit 2 ;;
esac
case $route in
  apple)  ;;
  server) args+=(-DebugEndpointURL $OLL -DebugEndpointModel $model) ;;
  host)   args+=(-DebugHostURL $BENCH_HOST_URL -DebugHostSecret $BENCH_HOST_SECRET -DebugHostPubKey $BENCH_HOST_PUBKEY -DebugHostModel $model) ;;
  *) echo "route must be apple, server or host"; exit 2 ;;
esac
[[ -n $only ]] && args+=(-LibrarianBenchOnly $only)
args+=("${extra[@]}")
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1
xcrun simctl install $SIM $APP || exit 3
rm -f $out/results.json
log=$out/app.log
xcrun simctl launch --console-pty --terminate-running-process $SIM com.doctorpresident.airpad "${args[@]}" > $log 2>&1 &
launcher=$!
deadline=$(( $(date +%s) + ${BENCH_TIMEOUT:-3600} ))
while ! grep -q "\[LibrarianBench\] done" $log 2>/dev/null; do
  (( $(date +%s) > deadline )) && { echo "TIMEOUT"; break }
  kill -0 $launcher 2>/dev/null || { sleep 2; grep -q "\[LibrarianBench\] done" $log || echo "APP EXITED before done"; break }
  sleep 3
done
xcrun simctl terminate $SIM com.doctorpresident.airpad > /dev/null 2>&1
grep -E "\[LibrarianBench\] (index|START|RESULT|ABORT)|\[LibrarianBench\] TURN .* END" $log | sed 's/^.*\[LibrarianBench\]/[bench]/' | cut -c1-220
[[ -f $out/results.json ]] && echo "results: $out/results.json"
