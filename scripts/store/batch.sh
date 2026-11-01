#!/bin/zsh
# 1.1 store — every UI still on <sim>, light then dark, into <out>/<appearance>/. Needs: setup_sim.sh, the fake Ollama on
# :11435 (my-computer.local) and the article on :8765 (brewing-notes.local).
set -u
SIM=$1; OUT=$2; HERE=${0:A:h}
for ap in ${=APS:-light dark}; do
  xcrun simctl ui $SIM appearance $ap
  xcrun simctl terminate $SIM com.apple.mobilesafari 2>/dev/null; xcrun simctl terminate $SIM com.apple.DocumentsApp 2>/dev/null
  O=$OUT/$ap
  for T in ${=TESTS:-testEntry testLibrarian testPrivate testAppLock}; do $HERE/run_ui.sh $SIM $T $O | grep -E "passed|failed \(|error:" | head -3; done
  [[ ${SKIP_SERVER:-} == 1 ]] || $HERE/run_ui.sh $SIM testServer $O STORE_SERVER=http://my-computer.local:11435 | grep -E "passed|failed \(|error:" | head -3
  F=$(find ~/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Shared/AppGroup -maxdepth 2 -name "File Provider Storage" -type d | head -1)
  rm -rf "$F/AirPad notes"; mkdir -p "$F/AirPad notes"   # each appearance's export starts from an empty folder
  [[ ${SKIP_EXPORT:-} == 1 ]] || $HERE/run_ui.sh $SIM testExport $O | grep -E "passed|failed \(|error:" | head -3
  xcrun simctl terminate $SIM com.apple.mobilesafari 2>/dev/null
  xcrun simctl openurl $SIM http://brewing-notes.local:8765/slow-coffee.html; sleep 6
  [[ ${SKIP_SHARE:-} == 1 ]] || $HERE/run_ui.sh $SIM testShareFromSafari $O | grep -E "passed|failed \(|error:" | head -3
done
xcrun simctl ui $SIM appearance light
cd $OUT; for d in light dark; do (cd $d; rm -f "App UI hierarchy"* "Complete Issue"* "Screen Recording"* "Synthesized Event"* "UI Snapshot"*); done
ls $OUT/light $OUT/dark | grep -c png
