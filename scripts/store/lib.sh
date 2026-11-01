#!/bin/zsh
# 1.1 store stills — shared helpers. Source with SIM set.
APP=${APP:-$HOME/Developer/AirPad/.claude/worktrees/ws-1.1d/build/DD-store-rel/Build/Products/Release-iphonesimulator/AirPad.app}
BID=com.doctorpresident.airpad
CALLOUTS=()
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do CALLOUTS+=(-com.airpad.callouts.$k YES); done
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -NoMapDebugHUD -ProUnlocked YES $CALLOUTS)
prep() { xcrun simctl boot $SIM >/dev/null 2>&1; xcrun simctl bootstatus $SIM -b >/dev/null
  xcrun simctl status_bar $SIM override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100; }
ground() {  # dark-json light-json → base64 Stored
  python3 -c "import json,base64,sys;print(base64.b64encode(json.dumps({'dark':json.loads(sys.argv[1]),'light':json.loads(sys.argv[2])}).encode()).decode())" "$1" "$2"; }
side() { # color [color2 angle]
  if [[ -n ${2:-} ]]; then echo "{\"custom\":true,\"color\":\"$1\",\"gradient\":true,\"color2\":\"$2\",\"angle\":${3:-90},\"dot\":\"FFFFFF\",\"dotOpacity\":0.809}"
  else echo "{\"custom\":true,\"color\":\"$1\",\"gradient\":false,\"color2\":\"$1\",\"angle\":90,\"dot\":\"FFFFFF\",\"dotOpacity\":0.809}"; fi; }
launch() { xcrun simctl launch --terminate-running-process $SIM $BID $BASE "$@" >/dev/null; }
snap() { xcrun simctl io $SIM screenshot --type=png "$1" >/dev/null 2>&1 && echo "$1"; }
