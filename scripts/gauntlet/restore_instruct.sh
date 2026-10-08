#!/bin/zsh
# CH Session 2 (T, 2026-10-08) — after EVERY run, T's real Host goes back to the V1 default:
# Instruct resident + held (Always-ready), and nothing else held. Talks to T's installed Host on its
# loopback port with a bearer derived in memory from its own secret file (never printed, never written).
#   scripts/gauntlet/restore_instruct.sh            → load Instruct, eject every other resident model
set -uo pipefail
WANT=${RESTORE_MODEL:-qwen3:4b-instruct-2507-q4_K_M}
BIN="/Applications/AirPad Host.app/Contents/MacOS/airpad-host"
REAL=http://127.0.0.1:8787; OLL=http://127.0.0.1:11434
for i in {1..60}; do curl -s -m 2 $REAL/health >/dev/null && break; sleep 1; done
TOKEN=$("$BIN" --print-token 2>/dev/null) || { echo "restore: no token"; exit 1; }
post() { curl -s -m 180 -X POST "$REAL$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$2"; }
echo "restore: load $WANT → $(post /v1/models/load "{\"catalogId\":\"$WANT\"}" | head -c 200)"
for m in $(curl -s $OLL/api/ps | python3 -c "import json,sys;print(' '.join(x['name'] for x in json.load(sys.stdin).get('models',[])))"); do
  [[ $m == $WANT ]] && continue
  echo "restore: eject $m → $(post /v1/models/eject "{\"catalogId\":\"$m\"}" | head -c 200)"
done
for i in {1..30}; do
  now=$(curl -s $OLL/api/ps | python3 -c "import json,sys;print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))")
  [[ $now == $WANT ]] && break; sleep 2
done
curl -s $OLL/api/ps | python3 -c "import json,sys;print('restore: resident',[(m['name'],m.get('context_length'),m['expires_at'][:4]) for m in json.load(sys.stdin).get('models',[])])"
echo "restore: residency.json $(tr -d '\n ' < ~/.airpad-host/residency.json)"
