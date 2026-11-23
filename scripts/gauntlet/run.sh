#!/bin/zsh
# Brief CH-0 — Gauntlet v2 orchestrator. One model per invocation.
#
#   scripts/gauntlet/run.sh <run_dir> <model-tag> [--think off,on] [--runs 3] [--only 1,S1] \
#                           [--replay <chat>=<abs replay.json>]... [--expect-digest <sha prefix>] [--no-build]
#
# What it does (and what it restores):
#   1. Never touches T's Host or T's Ollama (sweep 2b amend b, the never list): no residency read, no quit, no restore.
#      Refuses (exit 2, scripts/gauntlet/safe_ollama.zsh) unless the Ollama is CC's own on a loopback scratch port
#      (default http://127.0.0.1:11500, GAUNTLET_OLLAMA overrides) and its binary is not the Host app's bundled one.
#   2. Builds the RELEASE-CANDIDATE Host from airpad-host's current branch (a production build, no dev
#      tags) and runs it on its own port (8799) with --observe, an isolated --secret-file dir, the branch's
#      manifest.json, attached to CC's own Ollama (or spawning CC's copy, build/scratch-ollama/ollama, with
#      OLLAMA_MODELS=build/scratch-models; GAUNTLET_OLLAMA_BIN / GAUNTLET_OLLAMA_MODELS override).
#   3. Records versions (Ollama server, Host commit, app commit, Xcode) + the model's digest; polls
#      `/api/ps` every 2 s into ps.log for the digest/cold checks.
#   4. Plans rows (gauntlet.py plan) and drives the REAL Librarian UI via XCUITest (LibrarianGauntletV2).
#   5. Stops the scratch Host and anything it spawned (T's Host was never stopped, so nothing to restore).
#   6. Grades (gauntlet.py grade) → grades.json + table.md.
set -uo pipefail

RUN_DIR=${1:?run_dir}; MODEL=${2:?model}; shift 2
THINK=off,on; RUNS=3; ONLY=""; REPLAYS=(); EXPECT_DIGEST=""; BUILD=1; EXTRA=(); TT=900; STORE_PASSES=(); SHARDS=1
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
    # Brief CJ — CORRECTNESS runs only: drive the rows on N Simulators at once (clones of $SIM) against one Ollama
    # started with OLLAMA_NUM_PARALLEL=N. Never for latency/perf runs (parallel requests change the timings).
    --shards) SHARDS=$2; shift 2;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done

AIRPAD=${GAUNTLET_AIRPAD:-${0:A:h:h:h}}   # live-29: the checkout this script is in (a worktree builds its own source)
HOSTREPO=${GAUNTLET_HOSTREPO:-~/Developer/airpad-host}
FIXTURE=~/Developer/fixtures/tom-corpus-2026-09-21
SIM=${GAUNTLET_SIM:-CC2D6B5F-A6C2-494F-AC5E-555F8FF3C73A}   # iPhone 17 Pro Max, iOS 27.0
DD=${GAUNTLET_DD:-$AIRPAD/build/gauntlet-dd}   # override for an A/B against another build
source ${0:A:h}/safe_ollama.zsh
SHIP_OLLAMA=${GAUNTLET_OLLAMA_BIN:-$AIRPAD/build/scratch-ollama/ollama}   # CC's own copy, never the Host app's
OLL=${GAUNTLET_OLLAMA:-http://127.0.0.1:11500}
safe_ollama_or_die "$OLL"; safe_ollama_bin_or_die "$SHIP_OLLAMA"
export OLLAMA_HOST=${OLL#http://} OLLAMA_MODELS=${GAUNTLET_OLLAMA_MODELS:-$AIRPAD/build/scratch-models}
PORT=8799
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd)
SCR=${GAUNTLET_SCRATCH:-${TMPDIR:-/tmp}/gauntlet-host-$$}; mkdir -p "$SCR"   # Host binary + keys: never in the run dir
log() { print -r -- "[gauntlet $(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/run.log"; }
START=$(date +%s)

# ── 0. live-28 (2): never start a gauntlet under 30 GB free (live-27 took the Mac to 0 bytes mid-run) ───────────
$AIRPAD/scripts/disk/disk_hygiene.sh --check ${GAUNTLET_MIN_FREE_GB:-30} | tee -a "$RUN_DIR/run.log"
(( ${pipestatus[1]} == 0 )) || { log "STOP: not enough free disk for a gauntlet — run scripts/disk/disk_hygiene.sh, then report"; exit 1; }

# ── 1. T's Host and T's Ollama are never touched (sweep 2b amend b). Teardown = the scratch Host + its children ──
stop_scratch() {
  [[ -n ${POLL_PID:-} ]] && kill $POLL_PID 2>/dev/null
  [[ -n ${SCRATCH_PID:-} ]] && { pkill -P $SCRATCH_PID 2>/dev/null; kill $SCRATCH_PID 2>/dev/null; }; sleep 2
  pkill -f "$SCR/airpad-host" 2>/dev/null
}
trap stop_scratch EXIT

# ── 2. Release-candidate Host from the branch ───────────────────────────────────────────────────
HOST_SHA=$(git -C $HOSTREPO rev-parse --short HEAD); HOST_BRANCH=$(git -C $HOSTREPO branch --show-current)
HOST_DIRTY=$(git -C $HOSTREPO status --porcelain | grep -v '^??' | wc -l | tr -d ' ')
(cd $HOSTREPO && go build -o "$SCR/airpad-host" ./cmd/airpad-host) || { log "Host build FAILED"; exit 1; }
SECRET=$(openssl rand -hex 32)
# Brief CJ — the scratch Host spawns CC's Ollama copy with THIS environment (OLLAMA_HOST / OLLAMA_MODELS above), so the parallel-request setting reaches it. Checked against Ollama's own "server config" line below.
(( SHARDS > 1 )) && export OLLAMA_NUM_PARALLEL=$SHARDS
HOST_SECRET=$SECRET "$SCR/airpad-host" --headless --observe --listen 127.0.0.1:$PORT --ollama ${OLL#http://} \
  --ollama-bin "$SHIP_OLLAMA" --manifest $HOSTREPO/manifest.json \
  --identity "$SCR/identity.key" --secret-file "$SCR/secret" >> "$RUN_DIR/host.log" 2>&1 &
SCRATCH_PID=$!
TOKEN=$(HOST_SECRET=$SECRET "$SCR/airpad-host" --print-token)
for i in {1..60}; do HPK=$(curl -s -m 3 127.0.0.1:$PORT/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null); [[ -n $HPK ]] && break; sleep 1; done
[[ -z ${HPK:-} ]] && { log "scratch Host never became healthy"; exit 1; }
for i in {1..60}; do curl -s -m 2 $OLL/api/version >/dev/null && break; sleep 1; done
log "scratch Host $HOST_BRANCH@$HOST_SHA (dirty=$HOST_DIRTY) pid=$SCRATCH_PID on :$PORT, CC's Ollama at $OLL"
if (( SHARDS > 1 )); then
  for i in {1..20}; do grep -q "OLLAMA_NUM_PARALLEL:" "$RUN_DIR/host.log" && break; sleep 1; done
  NP=$(grep -o "OLLAMA_NUM_PARALLEL:[0-9]*" "$RUN_DIR/host.log" | tail -1)
  [[ $NP == "OLLAMA_NUM_PARALLEL:$SHARDS" ]] || { log "Ollama did not start with NUM_PARALLEL=$SHARDS (saw '${NP:-nothing}': an Ollama was already running?) — ABORT"; exit 1; }
  log "Ollama $NP for $SHARDS shards"
fi

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
    ARGS=("${BASEARGS[@]}" -ResetLibrarianRoute YES -LibrarianGauntlet -GauntletTapDir "$PD" -DebugHostModel "$MODEL" -GauntletThink "$THINKF")
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
  stop_scratch; trap - EXIT
  log "done (wall $(( $(date +%s) - START ))s)"
  exit 0
fi
python3 $AIRPAD/scripts/gauntlet/gauntlet.py plan --model "$MODEL" --digest "$DIGEST" --think "$THINK" --runs $RUNS \
  --out "$RUN_DIR" --only "$ONLY" --turn-timeout $TT "${REPLAYS[@]}" --base-args "$BASE" | tee -a "$RUN_DIR/run.log"
if (( BUILD )); then
  xcodebuild -project $AIRPAD/AirPad.xcodeproj -scheme AirPad -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath $DD build-for-testing > "$RUN_DIR/build.log" 2>&1 || { log "build-for-testing FAILED (see build.log)"; exit 1; }
fi
log "driving the UI… (shards=$SHARDS)"
source $AIRPAD/scripts/gauntlet/drive.zsh
T0=$(date +%s)
drive_ui "$RUN_DIR" $SIM $SHARDS 60 70
UIX=$?
log "UI drive wall $(( $(date +%s) - T0 ))s"
log "UI drive exit=$UIX ($(grep -c 'GAUNTLET_V2 ROW' $RUN_DIR/xcuitest.log) rows captured)"

# ── 5/6. Restore (trap) + grade ─────────────────────────────────────────────────────────────────
stop_scratch; trap - EXIT
python3 $AIRPAD/scripts/gauntlet/gauntlet.py grade "$RUN_DIR" > /dev/null
log "graded → $RUN_DIR/table.md  (wall $(( $(date +%s) - START ))s)"
