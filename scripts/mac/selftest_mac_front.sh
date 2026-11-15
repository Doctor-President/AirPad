#!/bin/zsh
# Mac E fix-up — like selftest_mac.sh, but launched through LaunchServices (`open`), so the isolated copy comes to the
# front and is ACTIVE (AppKit drops clicks to an inactive app): for the real-click tests (MacClickSelfTest & co).
#   selftest_mac_front.sh <isolated .app> <TestName> <out_dir> [extra args…]   (waits up to $WAIT s, default 300)
set -uo pipefail
APP=${1:?app}; T=${2:?test}; OUT=${3:?out}; shift 3; mkdir -p $OUT; OUT=${OUT:A}; APP=${APP:A}
pkill -f "$APP/Contents/MacOS/AirPad" 2>/dev/null; sleep 1
BASE=(-ApplePersistenceIgnoreState YES -UITestLibrary -UITestSampleLibrary -EmbedCPUOnly)
CALLOUTS=(); for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
: > $OUT/$T.out; : > $OUT/$T.err
open -n -F -a $APP --stdout $OUT/$T.out --stderr $OUT/$T.err --args $BASE $CALLOUTS -$T "$@"
sleep 3; PID=$(pgrep -nf "$APP/Contents/MacOS/AirPad")
for i in {1..${WAIT:-300}}; do grep -q "\[$T\] \(PASS\|FAIL\)" $OUT/$T.err $OUT/$T.out 2>/dev/null && break; kill -0 $PID 2>/dev/null || break; sleep 1; done
sleep 2; kill $PID 2>/dev/null
cat $OUT/$T.err $OUT/$T.out | sed 's/^[0-9-]* [0-9:.]* AirPad\[[0-9:a-f]*\] //' | sed -n "/\[$T\] [PF]A/,\$p" | grep -v "^\[AI\]\|^\[FM\]\|^\[Embed" > $OUT/$T.txt
cat $OUT/$T.txt
