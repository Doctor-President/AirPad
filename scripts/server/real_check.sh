#!/bin/zsh
# 1.1-D — the app's server paths against a REAL server. ONLY with T's OK and T present (standing rule).
#   real_check.sh <ollama|lmstudio> <endpoint-file> <model-id> <sim-udid> <AirPad.app (Debug)> <out-dir> [download-id]
# The endpoint is read from a file and never printed (logs say <server>). Records the server's loaded state BEFORE,
# runs -CustomServerRealCheck in the Simulator (detect · list · pick+load · chat · one-shot · [download] · eject what it
# loaded), samples the loaded state DURING the chat, then RESTORES the loaded set (same models, same windows) and
# records AFTER. Never deletes anything. Token (LM Studio): ~/.config/airpad/lmstudio.token if present.
set -u
KIND=$1; EFILE=$2; MODEL=$3; SIM=$4; APP=$5; OUT=$6; DL=${7:-}
E=$(tr -d '[:space:]' < $EFILE); BID=com.doctorpresident.airpad
TOKFILE=~/.config/airpad/lmstudio.token
AUTH=(); [[ $KIND == lmstudio && -s $TOKFILE ]] && AUTH=(-H "Authorization: Bearer $(tr -d '[:space:]' < $TOKFILE)")
mkdir -p $OUT
loaded() {  # → one line per loaded model: id ctx [expires]
  if [[ $KIND == ollama ]]; then
    curl -s -m 5 $E/api/ps | python3 -c 'import json,sys;[print(m["name"],m.get("context_length"),m.get("expires_at","")) for m in json.load(sys.stdin)["models"]]'
  else
    curl -s -m 5 "${AUTH[@]}" $E/api/v1/models | python3 -c 'import json,sys
for m in json.load(sys.stdin)["models"]:
  for i in m.get("loaded_instances",[]): print(m["key"],i["config"].get("context_length"),i["id"])'
  fi
}
loaded > $OUT/before.txt; echo "BEFORE:"; cat $OUT/before.txt
# Sample the loaded state every second while the app runs (the window DURING the turn).
( while true; do echo "--- $(date +%T)"; loaded; sleep 1; done ) > $OUT/during.txt 2>&1 & S=$!
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP || exit 1
ARGS=(-CustomServerRealCheck -RealEndpoint $E -RealModel $MODEL -UITestLibrary -UITestLibraryFresh -EmbedCPUOnly)
[[ -n $DL ]] && ARGS+=(-RealDownload $DL)
xcrun simctl launch --console-pty --terminate-running-process $SIM $BID "${ARGS[@]}" > $OUT/app.raw 2>&1 &
L=$!; t=0
while (( t < 900 )); do sleep 2; ((t+=2)); grep -q "\[RealCheck\] DONE" $OUT/app.raw && break; done
sleep 1; kill $L $S 2>/dev/null; xcrun simctl terminate $SIM $BID 2>/dev/null
# Keep only the RealCheck lines, address-free.
grep "\[RealCheck\]" $OUT/app.raw | sed "s#$E#<server>#g" > $OUT/app.txt; rm -f $OUT/app.raw
sed -i '' "s#$E#<server>#g" $OUT/during.txt
cat $OUT/app.txt
# Restore the loaded set.
loaded > $OUT/after-run.txt
python3 - $KIND $E $OUT "${AUTH[@]}" <<'PY'
import json, sys, urllib.request
kind, e, out = sys.argv[1:4]; hdr = {"Content-Type": "application/json"}
if len(sys.argv) > 5: hdr["Authorization"] = sys.argv[5].split(": ", 1)[1]
rd = lambda f: [l.split() for l in open(f"{out}/{f}") if l.strip()]
before, now = rd("before.txt"), rd("after-run.txt")
def post(path, body):
    req = urllib.request.Request(e + path, json.dumps(body).encode(), hdr); urllib.request.urlopen(req, timeout=300).read()
b = {(r[0], r[1]) for r in before}; n = {(r[0], r[1]) for r in now}
for r in now:
    if (r[0], r[1]) not in b:
        print("restore: unload", r[0], r[1])
        post("/api/generate", {"model": r[0], "keep_alive": 0}) if kind == "ollama" else post("/api/v1/models/unload", {"instance_id": r[2]})
for r in before:
    if (r[0], r[1]) not in n:
        print("restore: reload", r[0], r[1])
        if kind == "ollama":
            ka = -1 if len(r) > 2 and r[2][:4] > "2100" else "5m"
            post("/api/generate", {"model": r[0], "keep_alive": ka, "options": {"num_ctx": int(r[1])}})
        else:
            post("/api/v1/models/load", {"model": r[0], "context_length": int(r[1])})
PY
sleep 2; loaded > $OUT/after.txt; echo "AFTER:"; cat $OUT/after.txt
if diff <(cut -d' ' -f1,2 $OUT/before.txt | sort) <(cut -d' ' -f1,2 $OUT/after.txt | sort) >/dev/null; then echo "RESTORE VERIFIED (same models, same windows)"; else echo "RESTORE MISMATCH"; fi
