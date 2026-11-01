#!/bin/zsh
# 1.1-D fix-up (D3) — the headless Librarian Gauntlet (`-LibrarianGauntlet`, fixture clone) over ONE route, against the
# Mac's Ollama (127.0.0.1:11434), sharing the model T's Host already holds. Only with T's OK.
#   gauntlet_routes.sh <host|server> <model> <sim> <AirPad.app (Debug)> <out-dir>
#   host   — a scratch Host from ~/Developer/airpad-host on :8799 (isolated state dir, Always-ready holding <model> —
#            the same keep_alive -1 + num_ctx 20,480 T's Host stamps), attached to the running Ollama (no spawn).
#   server — the user's-own-server route: -GauntletRoute endpoint -DebugEndpointURL <ollama> -DebugEndpointModel <model>.
# Records Ollama's loaded set before/after and samples /api/ps every 2 s; FAILS LOUDLY if the after set differs.
# Run dirs hold answers from T's fixture: they stay in build/ (gitignored), never in Ops.
set -u
ROUTE=$1; MODEL=$2; SIM=$3; APP=$4; OUT=$5
OLL=http://127.0.0.1:11434; BID=com.doctorpresident.airpad; PORT=8799; shift 5; EXTRA=("$@")   # extra launch args (e.g. -GauntletOnly 5)
FIXTURE=~/Developer/fixtures/tom-corpus-2026-09-21
mkdir -p $OUT; OUT=${OUT:A}
ps_now() { curl -s -m 5 $OLL/api/ps | python3 -c 'import json,sys;[print(m["name"],m.get("context_length"),m.get("expires_at","")[:4]) for m in json.load(sys.stdin)["models"]]'; }
ps_now > $OUT/before.txt; echo "BEFORE:"; cat $OUT/before.txt
( while true; do print -n "$(date +%T) "; curl -s -m 2 $OLL/api/ps | python3 -c 'import json,sys;print(",".join(m["name"]+"@"+str(m.get("context_length"))+"@"+m.get("expires_at","")[:4] for m in json.load(sys.stdin)["models"]))' 2>/dev/null || print; sleep 2; done ) > $OUT/ps.log 2>&1 &
POLL=$!
ARGS=(-CorpusFixture $FIXTURE -EmbedCPUOnly -LibrarianGauntlet -ResetLibrarianRoute YES)
HOSTPID=""
if [[ $ROUTE == host ]]; then
  SCR=$(mktemp -d); (cd ~/Developer/airpad-host && go build -o $SCR/airpad-host ./cmd/airpad-host) || exit 1
  print -r -- "{\"mode\":\"always-on\",\"held\":[\"$MODEL\"]}" > $SCR/residency.json
  SECRET=$(openssl rand -hex 32)
  HOST_SECRET=$SECRET $SCR/airpad-host --headless --observe --listen 127.0.0.1:$PORT --ollama 127.0.0.1:11434 \
    --ollama-bin /nonexistent --manifest ~/Developer/airpad-host/manifest.json --identity $SCR/identity.key --secret-file $SCR/secret > $OUT/host.log 2>&1 &
  HOSTPID=$!
  TOKEN=$(HOST_SECRET=$SECRET $SCR/airpad-host --print-token)
  for i in {1..60}; do HPK=$(curl -s -m 3 127.0.0.1:$PORT/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null); [[ -n $HPK ]] && break; sleep 1; done
  [[ -z ${HPK:-} ]] && { echo "scratch Host never became healthy"; kill $HOSTPID $POLL; exit 1; }
  echo "scratch Host $(git -C ~/Developer/airpad-host rev-parse --short HEAD) up (attached: $(grep -c 'attaching (not spawning)' $OUT/host.log))"
  ARGS+=(-DebugHostURL http://127.0.0.1:$PORT -DebugHostSecret $SECRET -DebugHostPubKey $HPK -DebugHostModel $MODEL)
else
  ARGS+=(-GauntletRoute endpoint -DebugEndpointURL $OLL -DebugEndpointModel $MODEL)
fi
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM $APP || exit 1
ARGS+=("${EXTRA[@]}")
xcrun simctl launch --console-pty --terminate-running-process $SIM $BID "${ARGS[@]}" > $OUT/app.raw 2>&1 &
L=$!; t=0
while (( t < 5400 )); do sleep 5; ((t+=5)); grep -q "\[Gauntlet\] done" $OUT/app.raw && break; done
sleep 2; kill $L 2>/dev/null; xcrun simctl terminate $SIM $BID 2>/dev/null
[[ -n $HOSTPID ]] && { kill $HOSTPID; sleep 2; }
kill $POLL 2>/dev/null
grep -E "\[Gauntlet\]|\[ServerChat\]" $OUT/app.raw > $OUT/app.txt
[[ -n $HOSTPID ]] && grep -E "chat→ollama|chat done|\[ollama\]|residency|reconcile" $OUT/host.log > $OUT/host-observe.txt
ps_now > $OUT/after.txt; echo "AFTER:"; cat $OUT/after.txt
if diff <(sort $OUT/before.txt) <(sort $OUT/after.txt) >/dev/null; then echo "OLLAMA UNCHANGED (same models, windows, keep-forever)"; else echo "OLLAMA CHANGED — restore before anything else"; fi
echo "elapsed ${t}s; window samples: $(cut -d' ' -f2- $OUT/ps.log | tr ',' '\n' | sort | uniq -c | tr '\n' ';')"
