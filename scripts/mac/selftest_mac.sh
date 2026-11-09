#!/bin/zsh
# Mac batch C — run one DEBUG self-test on the ISOLATED Mac copy and print its result block.
#   selftest_mac.sh <isolated .app> <TestName> <out_dir> [extra args…]   (waits up to $WAIT s, default 300)
set -uo pipefail
APP=${1:?app}; T=${2:?test}; OUT=${3:?out}; shift 3; mkdir -p $OUT
BASE=(-ApplePersistenceIgnoreState YES -UITestLibrary -UITestSampleLibrary -EmbedCPUOnly)
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
$APP/Contents/MacOS/AirPad $BASE $CALLOUTS -$T "$@" > $OUT/$T.out 2> $OUT/$T.err &
PID=$!
for i in {1..${WAIT:-300}}; do grep -q "\[$T\] \(PASS\|FAIL\)" $OUT/$T.err $OUT/$T.out 2>/dev/null && break; kill -0 $PID 2>/dev/null || break; sleep 1; done
sleep 2; kill $PID 2>/dev/null; wait $PID 2>/dev/null
cat $OUT/$T.err $OUT/$T.out | sed 's/^[0-9-]* [0-9:.]* AirPad\[[0-9:a-f]*\] //' | sed -n "/\[$T\] [PF]A/,\$p" | grep -v "^\[AI\]\|^\[FM\]\|^\[Embed" > $OUT/$T.txt
cat $OUT/$T.txt
