#!/bin/zsh
# live-32 (3) — LIVE web passes on the HOST route (a scratch Host from airpad-host's branch, the shipping Ollama, the
# real model), run through scripts/live/run.sh. Like the gauntlet: T's Host is recorded and quit first, and restored
# and VERIFIED after (scripts/gauntlet/restore_host.sh), whatever happens.
#   scripts/live/host.sh <out_dir> <xctestrun> <set.json> <model> "<label>|<provider>|<extra app args>[|<xctestrun>]" …
# (a pass's own xctestrun runs another build — "before" and "after" in one Host session)
set -uo pipefail
OUT=${1:?out_dir}; XCTR=${2:?xctestrun}; SET=${3:?set}; MODEL=${4:?model}; shift 4
AIRPAD=${0:A:h:h:h}; HOSTREPO=${LIVE_HOSTREPO:-~/Developer/airpad-host}
SHIP_OLLAMA="/Applications/AirPad Host.app/Contents/Resources/ollama"; OLL=http://127.0.0.1:11434; PORT=8799
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); SCR=$(mktemp -d "${TMPDIR:-/tmp}/live-host.XXXX")
log() { print -r -- "[live-host $(date +%H:%M:%S)] $*" | tee -a "$OUT/host-run.log"; }
$AIRPAD/scripts/disk/disk_hygiene.sh --check ${LIVE_MIN_FREE_GB:-30} | tee -a "$OUT/host-run.log"
(( ${pipestatus[1]} == 0 )) || { log "STOP: not enough free disk"; exit 1; }
curl -s $OLL/api/ps > "$OUT/residency-before.json" 2>/dev/null || echo '{}' > "$OUT/residency-before.json"
cp ~/.airpad-host/residency.json "$OUT/held-before.json" 2>/dev/null || echo '{}' > "$OUT/held-before.json"
REAL_HOST_PID=$(pgrep -f "/Applications/AirPad Host.app/Contents/MacOS/airpad-host" || true)
log "T's Host pid=${REAL_HOST_PID:-none}; resident before: $(python3 -c "import json;print([m['name'] for m in json.load(open('$OUT/residency-before.json')).get('models',[])])")"
if [[ -n $REAL_HOST_PID ]]; then
  osascript -e 'quit app "AirPad Host"' 2>/dev/null || kill $REAL_HOST_PID
  for i in {1..20}; do pgrep -f "AirPad Host.app/Contents" >/dev/null || break; sleep 1; done
  pkill -9 -f "AirPad Host.app/Contents" 2>/dev/null || true
  log "quit T's Host (+ its bundled Ollama)"
fi
restore() {
  [[ -n ${SCRATCH_PID:-} ]] && kill $SCRATCH_PID 2>/dev/null; sleep 2
  pkill -f "$SCR/airpad-host" 2>/dev/null; pkill -f "$SHIP_OLLAMA serve" 2>/dev/null; sleep 2
  if [[ -n $REAL_HOST_PID ]]; then
    RESTORE_HELD_BEFORE="$OUT/held-before.json" $AIRPAD/scripts/gauntlet/restore_host.sh "$OUT/residency-before.json" 2>&1 | while read -r l; do log "$l"; done
    (( ${pipestatus[1]} == 0 )) || log "⚠️  T's HOST IS NOT RESTORED — fix it before anything else"
    curl -s $OLL/api/ps > "$OUT/residency-after.json"
    log "resident after restore: $(python3 -c "import json;print([(m['name'],m.get('context_length'),m['expires_at'][:4]) for m in json.load(open('$OUT/residency-after.json')).get('models',[])])")"
  fi
  rm -rf "$SCR"
}
trap restore EXIT
(cd $HOSTREPO && go build -o "$SCR/airpad-host" ./cmd/airpad-host) || { log "Host build FAILED"; exit 1; }
SECRET=$(openssl rand -hex 32)
HOST_SECRET=$SECRET "$SCR/airpad-host" --headless --observe --listen 127.0.0.1:$PORT --ollama 127.0.0.1:11434 \
  --ollama-bin "$SHIP_OLLAMA" --manifest $HOSTREPO/manifest.json \
  --identity "$SCR/identity.key" --secret-file "$SCR/secret" >> "$OUT/host.log" 2>&1 &
SCRATCH_PID=$!
TOKEN=$(HOST_SECRET=$SECRET "$SCR/airpad-host" --print-token)
for i in {1..60}; do HPK=$(curl -s -m 3 127.0.0.1:$PORT/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null); [[ -n $HPK ]] && break; sleep 1; done
[[ -z ${HPK:-} ]] && { log "scratch Host never became healthy"; exit 1; }
for i in {1..60}; do curl -s -m 2 $OLL/api/version >/dev/null && break; sleep 1; done
log "scratch Host $(git -C $HOSTREPO branch --show-current)@$(git -C $HOSTREPO rev-parse --short HEAD) pid=$SCRATCH_PID :$PORT; model $MODEL"
for P in "$@"; do
  IFS='|' read -r LABEL PROV PARGS PXCTR <<< "$P"
  log "pass $LABEL ($PROV${PARGS:+, $PARGS}) build ${PXCTR:-$XCTR}"
  $AIRPAD/scripts/live/run.sh "$OUT/$LABEL" "${PXCTR:-$XCTR}" "$SET" "$PROV" -ResetLibrarianRoute YES -DebugHostURL http://127.0.0.1:$PORT \
    -DebugHostSecret $SECRET -DebugHostPubKey $HPK -DebugHostModel $MODEL ${(z)PARGS} 2>&1 | tail -3 | while read -r l; do log "$l"; done
done
/usr/bin/grep -E "chat done" "$OUT/host.log" | cut -c1-200 > "$OUT/host-obs.log"
log "done"
