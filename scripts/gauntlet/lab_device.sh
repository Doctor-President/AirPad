#!/bin/zsh
# Gauntlet LAB — DEVICE mode (also runs on a Simulator to validate the device path).
# Isolated `-UITestLibrary` ONLY (never T's real Library), dead-port pairing (never T's Host), replays passed
# INLINE (`-GauntletReplayB64`), tap inside the app sandbox, in-app self-watchdog exits a hung app (20 s).
# Results = `GAUNTLET_V2 RESULT {json}` lines in xcuitest.log.
#
#   scripts/gauntlet/lab_device.sh <run_dir> <udid> sim|device <products_dd> --replay <variant>@<chat>[:cases]=<abs.json> ... [--group-arg pre=arg] [--fresh-each]
set -uo pipefail
RUN_DIR=${1:?}; UDID=${2:?}; KIND=${3:?}; DD=${4:?}; shift 4
REPLAYS=(); GROUPARGS=(); FRESH_EACH=0
while (( $# )); do
  case $1 in
    --replay) REPLAYS+=(--replay "$2"); shift 2;;
    --group-arg) GROUPARGS+=("$2"); shift 2;;
    --fresh-each) FRESH_EACH=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
AIRPAD=~/Developer/AirPad
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd)
DEAD_KEY=$(python3 -c "import base64;print(base64.b64encode(bytes(32)).decode())")
BASE=$(python3 -c "import json;print(json.dumps(['-UITestLibrary','-EmbedCPUOnly','-DebugHostURL','http://127.0.0.1:1','-DebugHostSecret','lab','-DebugHostPubKey','$DEAD_KEY','-GauntletSelfWatchdog','${WD:-30}']))")
python3 $AIRPAD/scripts/gauntlet/gauntlet.py plan --model qwen3:4b --digest lab --think off --runs 1 --out "$RUN_DIR" \
  --turn-timeout 90 "${REPLAYS[@]}" --base-args "$BASE" > "$RUN_DIR/plan.log"
python3 - "$RUN_DIR/config.json" $FRESH_EACH "${GROUPARGS[@]}" <<'PY'
import json,sys,base64
import os
p=sys.argv[1]; fresh_each=sys.argv[2]=="1"; c=json.load(open(p)); c["device"]=True; c["watchdogSec"]=float(os.environ.get("WD","30"))
for i,g in enumerate(c["groups"]):
    a=g["args"]
    if "-GauntletReplay" in a:
        k=a.index("-GauntletReplay"); a[k]="-GauntletReplayB64"; a[k+1]=base64.b64encode(open(a[k+1],"rb").read()).decode()
    if i==0 or fresh_each: a+=["-UITestLibraryFresh"]
for spec in sys.argv[3:]:
    pre,arg=spec.split("=",1)
    for g in c["groups"]:
        if g["group"].startswith(pre): g["args"]+=arg.split(" ")
json.dump(c,open(p,"w"),indent=2)
open(p+".b64","w").write(base64.b64encode(json.dumps(c).encode()).decode())
PY
if [[ $KIND == sim ]]; then DEST="platform=iOS Simulator,id=$UDID"; xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b >/dev/null 2>&1
else DEST="platform=iOS,id=$UDID"; fi
print "[lab-device $(date +%H:%M:%S)] driving $KIND $UDID ($(python3 -c "import json;print(sum(len(g['turns']) for g in json.load(open('$RUN_DIR/config.json'))['groups']))") rows)…"
TEST_RUNNER_GAUNTLET_CONFIG_B64="$(cat $RUN_DIR/config.json.b64)" xcodebuild -project $AIRPAD/AirPad.xcodeproj -scheme AirPad \
  -destination "$DEST" -derivedDataPath $DD -only-testing:AirPadUITests/LibrarianGauntletV2/testRunGauntlet \
  test-without-building > "$RUN_DIR/xcuitest.log" 2>&1
print "[lab-device] exit=$?"
grep "GAUNTLET_V2 RESULT" "$RUN_DIR/xcuitest.log" | sed 's/.*GAUNTLET_V2 RESULT //' | tee "$RUN_DIR/results.jsonl" | python3 -c "
import json,sys
for l in sys.stdin:
    r=json.loads(l); print(('FREEZE ' if 'HUNG' in r['note'] else ('ok     ' if r['ok'] else 'FAIL   '))+r['row'], r['note'][:70])"
