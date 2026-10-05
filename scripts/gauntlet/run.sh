#!/bin/zsh
# Brief CH-0 — Gauntlet v2 orchestrator. One model per invocation.
#
#   scripts/gauntlet/run.sh <run_dir> <model-tag> [--think off,on] [--runs 3] [--only 1,S1] \
#                           [--replay <chat>=<abs replay.json>]... [--expect-digest <sha prefix>] [--no-build]
#
# What it does (and what it restores):
#   1. Records T's REAL Host residency (`/api/ps`), then QUITS the AirPad Host app — its Always-ready
#      reconcile loop would otherwise fight every test load (it re-stamps its held model every 60 s).
#   2. Builds the RELEASE-CANDIDATE Host from airpad-host's current branch (a production build, no dev
#      tags) and runs it on its own port (8799) with --observe, an isolated --secret-file dir, the branch's
#      manifest.json, and the SHIPPING Ollama binary from the installed Host app (it supervises it).
#   3. Records versions (Ollama server, Host commit, app commit, Xcode) + the model's digest; polls
#      `/api/ps` every 2 s into ps.log for the digest/cold checks.
#   4. Plans rows (gauntlet.py plan) and drives the REAL Librarian UI via XCUITest (LibrarianGauntletV2).
#   5. Stops the scratch Host, relaunches T's Host app, verifies the model it held is resident again.
#   6. Grades (gauntlet.py grade) → grades.json + table.md.
set -uo pipefail

RUN_DIR=${1:?run_dir}; MODEL=${2:?model}; shift 2
THINK=off,on; RUNS=3; ONLY=""; REPLAYS=(); EXPECT_DIGEST=""; BUILD=1; EXTRA=(); TT=900; STORE_PASSES=()
while (( $# )); do
  case $1 in
    --think) THINK=$2; shift 2;;
    --runs) RUNS=$2; shift 2;;
    --only) ONLY=$2; shift 2;;
    --replay) REPLAYS+=(--replay "$2"); shift 2;;
    --expect-digest) EXPECT_DIGEST=$2; shift 2;;
    --no-build) BUILD=0; shift;;
    --turn-timeout) TT=$2; shift 2;;
    # Store-level PRE-SCREEN (no UI): `--store-pass "<label>|<abs .app>|<YES|NO think>|<case ids or empty>[|<extra launch args>]"`,
    # repeatable (the optional 5th field, space-separated, e.g. `-GauntletHostNumCtx 8192`, applies to that pass only). Each pass installs that .app, runs `-LibrarianGauntlet` headless with the render tap on, and
    # is graded by `gauntlet.py grade-store` into <run_dir>/<label>/. Passes share ONE Host session.
    --store-pass) STORE_PASSES+=("$2"); shift 2;;
    --extra-arg) EXTRA+=("$2"); shift 2;;   # appended to every launch (e.g. an A/B switch)
    *) echo "unknown arg $1"; exit 2;;
  esac
done

AIRPAD=~/Developer/AirPad
HOSTREPO=~/Developer/airpad-host
FIXTURE=~/Developer/fixtures/tom-corpus-2026-09-21
SIM=${GAUNTLET_SIM:-CC2D6B5F-A6C2-494F-AC5E-555F8FF3C73A}   # iPhone 17 Pro Max, iOS 27.0
DD=$AIRPAD/build/gauntlet-dd
SHIP_OLLAMA="/Applications/AirPad Host.app/Contents/Resources/ollama"
OLL=http://127.0.0.1:11434
PORT=8799
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd)
SCR=${GAUNTLET_SCRATCH:-${TMPDIR:-/tmp}/gauntlet-host-$$}; mkdir -p "$SCR"   # Host binary + keys: never in the run dir
log() { print -r -- "[gauntlet $(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/run.log"; }
START=$(date +%s)

# ── 1. T's real Host: record, then quit ──────────────────────────────────────────────────────────
curl -s $OLL/api/ps > "$RUN_DIR/residency-before.json" 2>/dev/null || echo '{}' > "$RUN_DIR/residency-before.json"
REAL_HOST_PID=$(pgrep -f "/Applications/AirPad Host.app/Contents/MacOS/airpad-host" || true)
log "T's Host pid=${REAL_HOST_PID:-none}; resident before: $(python3 -c "import json;print([m['name'] for m in json.load(open('$RUN_DIR/residency-before.json')).get('models',[])])")"
if [[ -n $REAL_HOST_PID ]]; then
  osascript -e 'quit app "AirPad Host"' 2>/dev/null || kill $REAL_HOST_PID
  for i in {1..20}; do pgrep -f "AirPad Host.app/Contents" >/dev/null || break; sleep 1; done
  pkill -9 -f "AirPad Host.app/Contents" 2>/dev/null || true   # zombie-tray gotcha
  log "quit T's Host (+ its bundled Ollama)"
fi
restore_real_host() {
  [[ -n ${SCRATCH_PID:-} ]] && kill $SCRATCH_PID 2>/dev/null; sleep 2
  pkill -f "$SCR/airpad-host" 2>/dev/null; pkill -f "$SHIP_OLLAMA serve" 2>/dev/null; sleep 2
  [[ -n ${POLL_PID:-} ]] && kill $POLL_PID 2>/dev/null
  if [[ -n $REAL_HOST_PID ]]; then
    open -a "AirPad Host"; log "relaunched T's Host; waiting for its held model…"
    local want=$(python3 -c "import json;print(' '.join(m['name'] for m in json.load(open('$RUN_DIR/residency-before.json')).get('models',[])))")
    for i in {1..90}; do
      local now=$(curl -s $OLL/api/ps | python3 -c "import json,sys;print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))" 2>/dev/null)
      [[ "$now" == "$want" ]] && break; sleep 2
    done
    curl -s $OLL/api/ps > "$RUN_DIR/residency-after.json"
    log "resident after restore: $(python3 -c "import json;print([(m['name'],m.get('context_length'),m['expires_at'][:4]) for m in json.load(open('$RUN_DIR/residency-after.json')).get('models',[])])") (wanted: $want)"
  fi
}
trap restore_real_host EXIT

# ── 2. Release-candidate Host from the branch ───────────────────────────────────────────────────
HOST_SHA=$(git -C $HOSTREPO rev-parse --short HEAD); HOST_BRANCH=$(git -C $HOSTREPO branch --show-current)
HOST_DIRTY=$(git -C $HOSTREPO status --porcelain | grep -v '^??' | wc -l | tr -d ' ')
(cd $HOSTREPO && go build -o "$SCR/airpad-host" ./cmd/airpad-host) || { log "Host build FAILED"; exit 1; }
SECRET=$(openssl rand -hex 32)
HOST_SECRET=$SECRET "$SCR/airpad-host" --headless --observe --listen 127.0.0.1:$PORT --ollama 127.0.0.1:11434 \
  --ollama-bin "$SHIP_OLLAMA" --manifest $HOSTREPO/manifest.json \
  --identity "$SCR/identity.key" --secret-file "$SCR/secret" >> "$RUN_DIR/host.log" 2>&1 &
SCRATCH_PID=$!
TOKEN=$(HOST_SECRET=$SECRET "$SCR/airpad-host" --print-token)
for i in {1..60}; do HPK=$(curl -s -m 3 127.0.0.1:$PORT/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null); [[ -n $HPK ]] && break; sleep 1; done
[[ -z ${HPK:-} ]] && { log "scratch Host never became healthy"; exit 1; }
for i in {1..60}; do curl -s -m 2 $OLL/api/version >/dev/null && break; sleep 1; done
log "scratch Host $HOST_BRANCH@$HOST_SHA (dirty=$HOST_DIRTY) pid=$SCRATCH_PID on :$PORT, shipping Ollama supervised"

# ── 3. Versions + digest + ps poller ────────────────────────────────────────────────────────────
DIGEST=$(curl -s $OLL/api/tags | python3 -c "import json,sys;print(next((m['digest'] for m in json.load(sys.stdin)['models'] if m['name']=='$MODEL'),''))")
[[ -z $DIGEST && $MODEL != replay ]] && { log "model $MODEL is not installed"; exit 1; }
if [[ -n $EXPECT_DIGEST && $DIGEST != $EXPECT_DIGEST* ]]; then log "DIGEST DRIFT: $MODEL is $DIGEST, expected $EXPECT_DIGEST — ABORT"; exit 1; fi
python3 - "$RUN_DIR/versions.json" <<EOF
import json,subprocess,urllib.request,sys
v=json.load(urllib.request.urlopen("$OLL/api/version"))["version"]
xc=subprocess.run(["xcodebuild","-version"],capture_output=True,text=True).stdout.split("\n")[0]
json.dump({"ollama":v,"ollamaBinary":"$SHIP_OLLAMA","host":"$HOST_BRANCH@$HOST_SHA","hostDirtyFiles":$HOST_DIRTY,
  "app":subprocess.run(["git","-C","$AIRPAD","rev-parse","--short","HEAD"],capture_output=True,text=True).stdout.strip()+"@"+subprocess.run(["git","-C","$AIRPAD","branch","--show-current"],capture_output=True,text=True).stdout.strip(),
  "appDirtyFiles":len([l for l in subprocess.run(["git","-C","$AIRPAD","status","--porcelain"],capture_output=True,text=True).stdout.splitlines() if not l.startswith("??")]),
  "xcode":xc,"model":"$MODEL","digest":"$DIGEST","sim":"$SIM"},open(sys.argv[1],"w"),indent=2)
EOF
log "versions: $(cat $RUN_DIR/versions.json | tr -d '\n ' )"
zmodload zsh/datetime
( while true; do
    print -n "${EPOCHREALTIME}\t"
    curl -s -m 2 $OLL/api/ps | python3 -c "import json,sys;print(','.join(m['name']+'@'+m['digest']+'@'+str(m.get('size_vram',0))+'@'+str(m.get('context_length',0)) for m in json.load(sys.stdin).get('models',[])))" 2>/dev/null || print
    sleep 2
  done ) >> "$RUN_DIR/ps.log" &
POLL_PID=$!

# ── 4. Plan + drive the real UI ─────────────────────────────────────────────────────────────────
BASE=$(python3 -c "import json,sys;print(json.dumps(['-CorpusFixture','$FIXTURE','-EmbedCPUOnly','-DebugHostURL','http://127.0.0.1:$PORT','-DebugHostSecret','$SECRET','-DebugHostPubKey','$HPK']+sys.argv[1:]))" "${EXTRA[@]}")
if (( ${#STORE_PASSES[@]} )); then
  xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
  BASEARGS=("${(@f)$(python3 -c "import json,sys;print('\n'.join(json.loads(sys.argv[1])))" "$BASE")}")
  for P in "${STORE_PASSES[@]}"; do
    IFS='|' read -r LABEL APP THINKF ONLYC PASSARGS <<< "$P"
    PD="$RUN_DIR/$LABEL"; rm -rf "$PD"; mkdir -p "$PD"
    xcrun simctl terminate $SIM com.doctorpresident.airpad 2>/dev/null
    xcrun simctl install $SIM "$APP" || { log "install failed: $APP"; continue; }
    ARGS=("${BASEARGS[@]}" -LibrarianGauntlet -GauntletTapDir "$PD" -DebugHostModel "$MODEL" -GauntletThink "$THINKF")
    [[ -n $ONLYC ]] && ARGS+=(-GauntletOnly "$ONLYC")
    [[ -n ${PASSARGS:-} ]] && ARGS+=(${(z)PASSARGS})
    log "store pass $LABEL (think=$THINKF only=${ONLYC:-all}${PASSARGS:+ args=$PASSARGS}) …"
    HL0=$(wc -l < "$RUN_DIR/host.log"); PL0=$(wc -l < "$RUN_DIR/ps.log")
    ( xcrun simctl launch --console-pty --terminate-running-process $SIM com.doctorpresident.airpad "${ARGS[@]}" > "$PD/store.log" 2>&1 ) &
    LPID=$!
    for i in {1..720}; do grep -q "\[Gauntlet\] done" "$PD/store.log" 2>/dev/null && break; sleep 5; done
    kill $LPID 2>/dev/null; xcrun simctl terminate $SIM com.doctorpresident.airpad 2>/dev/null
    tail -n +$((HL0+1)) "$RUN_DIR/host.log" > "$PD/host.log"; cp "$RUN_DIR/versions.json" "$PD/" 2>/dev/null
    # THIS pass's /api/ps samples only — a whole-session copy made every later pass report the max resident
    # size of every earlier one (CH-A memory measurement runs several num_ctx passes in one Host session).
    tail -n +$((PL0+1)) "$RUN_DIR/ps.log" > "$PD/ps.log"
    python3 $AIRPAD/scripts/gauntlet/gauntlet.py grade-store "$PD" --model "$MODEL" --digest "$DIGEST" > /dev/null
    log "store pass $LABEL graded → $PD/table.md"
  done
  restore_real_host; trap - EXIT
  log "done (wall $(( $(date +%s) - START ))s)"
  exit 0
fi
python3 $AIRPAD/scripts/gauntlet/gauntlet.py plan --model "$MODEL" --digest "$DIGEST" --think "$THINK" --runs $RUNS \
  --out "$RUN_DIR" --only "$ONLY" --turn-timeout $TT "${REPLAYS[@]}" --base-args "$BASE" | tee -a "$RUN_DIR/run.log"
if (( BUILD )); then
  xcodebuild -project $AIRPAD/AirPad.xcodeproj -scheme AirPad -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath $DD build-for-testing > "$RUN_DIR/build.log" 2>&1 || { log "build-for-testing FAILED (see build.log)"; exit 1; }
fi
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
log "driving the UI…"
# Watchdog — a hung app (main-thread heartbeat stale > 60 s, app alive > 70 s) freezes the XCUITest driver
# too (it waits for "idle" forever). Sample it as evidence, drop a hung-<epoch> marker (the driver turns that
# into an A8 FAIL for the row), and terminate it so the run continues.
( while true; do
    sleep 10
    [[ -f $RUN_DIR/heartbeat ]] || continue
    APID=$(pgrep -f "AirPad.app/AirPad" | head -1); [[ -n $APID ]] || continue
    up=$(ps -o etime= -p $APID | awk -F'[:-]' '{n=NF; s=$n+($(n-1))*60; if(n>2)s+=$(n-2)*3600; print s}')
    age=$(( $(date +%s) - $(cut -d. -f1 $RUN_DIR/heartbeat) ))
    if (( age > 60 && up > 70 )); then
      E=$(date +%s); sample $APID 3 -mayDie > "$RUN_DIR/hung-$E.sample.txt" 2>/dev/null
      kill -9 $APID 2>/dev/null; touch "$RUN_DIR/hung-$E"   # kill THAT pid — never by bundle id (races the next launch)
      print -r -- "[gauntlet $(date +%H:%M:%S)] WATCHDOG: app main thread stalled ${age}s — sampled + terminated" >> "$RUN_DIR/run.log"
    fi
  done ) &
WATCH_PID=$!
TEST_RUNNER_GAUNTLET_CONFIG="$RUN_DIR/config.json" xcodebuild -project $AIRPAD/AirPad.xcodeproj -scheme AirPad \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD \
  -only-testing:AirPadUITests/LibrarianGauntletV2/testRunGauntlet test-without-building > "$RUN_DIR/xcuitest.log" 2>&1
UIX=$?; kill $WATCH_PID 2>/dev/null
log "UI drive exit=$UIX ($(grep -c 'GAUNTLET_V2 ROW' $RUN_DIR/xcuitest.log) rows captured)"

# ── 5/6. Restore (trap) + grade ─────────────────────────────────────────────────────────────────
restore_real_host; trap - EXIT
python3 $AIRPAD/scripts/gauntlet/gauntlet.py grade "$RUN_DIR" > /dev/null
log "graded → $RUN_DIR/table.md  (wall $(( $(date +%s) - START ))s)"
