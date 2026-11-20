#!/bin/zsh
# Sweep 2a — a scratch AirPad Host built from ~/Developer/airpad-host source, attached to CC's OWN Ollama (never T's
# installed Host, never port 11434). Prints the three BENCH_HOST_* lines for bench.sh and stays up until killed.
#   zsh scripts/librarian/scratch_host.sh <model> <state-dir> [port]      (then: source <state-dir>/env)
set -u
MODEL=$1; SCR=${2:A}; PORT=${3:-8799}
OLL=${BENCH_OLLAMA:-http://127.0.0.1:11500}
[[ $OLL == *:11434* || $OLL == *:1234* ]] && { echo "refusing: $OLL is T's server port"; exit 2 }
mkdir -p $SCR
(cd ~/Developer/airpad-host && go build -o $SCR/airpad-host ./cmd/airpad-host) || exit 1
print -r -- "{\"mode\":\"always-on\",\"held\":[\"$MODEL\"]}" > $SCR/residency.json
SECRET=$(openssl rand -hex 32)
HOST_SECRET=$SECRET $SCR/airpad-host --headless --observe --listen 127.0.0.1:$PORT --ollama ${OLL#http://} \
  --ollama-bin /nonexistent --manifest ~/Developer/airpad-host/manifest.json --identity $SCR/identity.key --secret-file $SCR/secret > $SCR/host.log 2>&1 &
HOSTPID=$!
TOKEN=$(HOST_SECRET=$SECRET $SCR/airpad-host --print-token)
HPK=""
for i in {1..60}; do
  HPK=$(curl -s -m 3 127.0.0.1:$PORT/health -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('hostPublicKey',''))" 2>/dev/null)
  [[ -n $HPK ]] && break; sleep 1
done
[[ -z $HPK ]] && { echo "scratch Host never became healthy (see $SCR/host.log)"; kill $HOSTPID; exit 1 }
print -r -- "export BENCH_HOST_URL=http://127.0.0.1:$PORT BENCH_HOST_SECRET=$SECRET BENCH_HOST_PUBKEY=$HPK BENCH_HOST_PID=$HOSTPID" > $SCR/env
echo "scratch Host $(git -C ~/Developer/airpad-host rev-parse --short HEAD) up on :$PORT → $OLL (pid $HOSTPID); source $SCR/env"
wait $HOSTPID
