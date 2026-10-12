#!/bin/zsh
# Gauntlet LAB — replay-only experiments through the real Librarian UI with NO Host and NO model.
# Never touches T's AirPad Host / Ollama residency. The pairing points at a dead port, so the provider is
# still `.host` (same budgets/packet shape as a real run) while `-GauntletReplay` supplies every answer.
# Title generation / warm-up fail silently (dead port) — so anything that reproduces here does NOT
# depend on the model, the Host, or the generated chat title.
#
#   scripts/gauntlet/lab.sh <run_dir> --replay <variant>@<chat>[:cases]=<abs.json> ... [--extra-arg X]... [--turn-timeout N]
#                           [--only <case ids>] [--shards N]   (Brief CJ: N Simulators at once; see drive.zsh)
set -uo pipefail
RUN_DIR=${1:?run_dir}; shift
REPLAYS=(); EXTRA=(); TT=180; GROUPARGS=(); ONLY=""; SHARDS=1
while (( $# )); do
  case $1 in
    --replay) REPLAYS+=(--replay "$2"); shift 2;;
    --extra-arg) EXTRA+=("$2"); shift 2;;
    --turn-timeout) TT=$2; shift 2;;
    --group-arg) GROUPARGS+=("$2"); shift 2;;   # <group-prefix>=<launch arg>, e.g. ro-b=-GauntletKeepChat
    --only) ONLY=$2; shift 2;;
    --shards) SHARDS=$2; shift 2;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
AIRPAD=~/Developer/AirPad
FIXTURE=~/Developer/fixtures/tom-corpus-2026-09-21
SIM=${GAUNTLET_SIM:-CC2D6B5F-A6C2-494F-AC5E-555F8FF3C73A}
DD=${GAUNTLET_DD:-$AIRPAD/build/gauntlet-dd}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"; RUN_DIR=$(cd "$RUN_DIR" && pwd)
log() { print -r -- "[lab $(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/run.log"; }
echo '{"ollama":"none (lab)","host":"none (lab)"}' > "$RUN_DIR/versions.json"
DEAD_KEY=$(python3 -c "import base64;print(base64.b64encode(bytes(32)).decode())")
BASE=$(python3 -c "import json,sys;print(json.dumps(['-CorpusFixture','$FIXTURE','-EmbedCPUOnly','-DebugHostURL','http://127.0.0.1:1','-DebugHostSecret','lab','-DebugHostPubKey','$DEAD_KEY']+sys.argv[1:]))" "${EXTRA[@]}")
python3 $AIRPAD/scripts/gauntlet/gauntlet.py plan --model qwen3:4b --digest lab --think off --runs 1 --out "$RUN_DIR" \
  --turn-timeout $TT --only "$ONLY" "${REPLAYS[@]}" --base-args "$BASE" | tee -a "$RUN_DIR/run.log"
python3 - "$RUN_DIR/config.json" "${GROUPARGS[@]}" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p))
for g in c["groups"]:
    g["eject"] = False   # no model in the lab: an eject would only unload T's own Ollama model (Brief CJ)
for spec in sys.argv[2:]:
    pre,arg=spec.split("=",1)
    for g in c["groups"]:
        if g["group"].startswith(pre): g["args"]+=arg.split(" ")
json.dump(c,open(p,"w"),indent=2)
PY
source $AIRPAD/scripts/gauntlet/drive.zsh
T0=$(date +%s)
drive_ui "$RUN_DIR" $SIM $SHARDS 45 55
log "UI drive wall $(( $(date +%s) - T0 ))s (shards=$SHARDS)"
grep "GAUNTLET_V2 ROW" "$RUN_DIR/xcuitest.log" | sed 's/GAUNTLET_V2 //' | tee -a "$RUN_DIR/run.log"
