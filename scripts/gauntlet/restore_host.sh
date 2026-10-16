#!/bin/zsh
# live-18 (0a) — put T's REAL Host back after a gauntlet run (was inline in run.sh's restore_real_host), and PROVE it.
#   scripts/gauntlet/restore_host.sh <residency-before.json>      (Ollama /api/ps, recorded before T's Host was quit)
# live-17: T's Host relaunched itself mid-run and ATTACHED to the scratch Ollama ("[ollama] already serving …
# attaching"); the teardown then stopped that Ollama, `open -a` was a no-op (the Host was running), and the restore
# "succeeded" with nothing resident and no Ollama. So, in order:
#   1. the Host is running and answers /health (opened if it isn't);
#   2. T's Ollama answers. If it doesn't, the Host is attached to a dead one: quit it, relaunch it (it spawns its own);
#   3. Instruct resident + held (restore_instruct.sh, the CH Session 2 default);
#   4. every OTHER model resident before the run comes back the way it was: held → loaded through the Host (held);
#      not held → loaded straight into Ollama at its old num_ctx, for what was left of its keep-alive (at least 15 min);
#   5. re-verify all of it; any miss prints "restore: FAIL …" and exits 1.
# Every endpoint and Host-control command can be overridden for test_restore.sh (fake Host + Ollama, scratch ports).
set -uo pipefail
BEFORE=${1:?residency-before.json}
OLL=${RESTORE_OLL:-http://127.0.0.1:11434}
HOSTURL=${RESTORE_HOST_URL:-http://127.0.0.1:8787}
BIN=${RESTORE_HOST_BIN:-"/Applications/AirPad Host.app/Contents/MacOS/airpad-host"}
RESIDENCY=${RESTORE_RESIDENCY:-$HOME/.airpad-host/residency.json}
HELD_BEFORE=${RESTORE_HELD_BEFORE:-}           # the Host's residency.json as it was before the run (run.sh copies it)
RUNNING=${RESTORE_HOST_RUNNING:-'pgrep -f "/Applications/AirPad Host.app/Contents/MacOS/airpad-host"'}
OPEN=${RESTORE_HOST_OPEN:-'open -a "AirPad Host"'}
QUIT=${RESTORE_HOST_QUIT:-'osascript -e '"'"'quit app "AirPad Host"'"'"'; for i in {1..20}; do pgrep -f "AirPad Host.app/Contents" >/dev/null || break; sleep 1; done; pkill -9 -f "AirPad Host.app/Contents"'}
SETTLE=${RESTORE_SETTLE:-60}                   # seconds to wait for the Host, then its Ollama
WANT=${RESTORE_MODEL:-qwen3:4b-instruct-2507-q4_K_M}
CTX=${RESTORE_CTX:-20480}
HERE=${0:A:h}
export RESTORE_OLL=$OLL RESTORE_HOST_URL=$HOSTURL RESTORE_HOST_BIN=$BIN RESTORE_RESIDENCY=$RESIDENCY RESTORE_MODEL=$WANT

fail() { echo "restore: FAIL — $*"; exit 1; }
ollama_up() { curl -s -m 2 $OLL/api/version >/dev/null; }
host_up() { curl -s -m 2 $HOSTURL/health >/dev/null; }
host_gone() { ! eval "$RUNNING" >/dev/null 2>&1; }
within() { local n=$1; shift; for i in {1..$n}; do "$@" && return 0; sleep 1; done; return 1; }
open_host() {
  eval "$RUNNING" >/dev/null 2>&1 || { eval "$OPEN"; echo "restore: opened T's Host"; }
  within $SETTLE host_up || fail "T's Host doesn't answer /health after ${SETTLE}s"
}

# 1–2. The Host, and an Ollama that answers.
open_host
if ! within $SETTLE ollama_up; then
  echo "restore: T's Host is up but its Ollama doesn't answer (attached to the stopped scratch Ollama?) → quit + relaunch"
  eval "$QUIT" >/dev/null 2>&1
  within 20 host_gone || fail "T's Host didn't quit"
  open_host
  within $SETTLE ollama_up || fail "T's Ollama doesn't answer after relaunching the Host"
fi
echo "restore: T's Host + Ollama answer ($(curl -s -m 2 $OLL/api/version))"

# 3. Instruct, resident + held.
$HERE/restore_instruct.sh 2>&1

# 4. Everything else that was resident before the run.
TOKEN=$("$BIN" --print-token 2>/dev/null) || fail "no Host token"
OTHERS=$(python3 - "$BEFORE" "${HELD_BEFORE:-/dev/null}" "$WANT" <<'PY'
import json, sys
from datetime import datetime, timezone
before = json.load(open(sys.argv[1])).get("models", [])
try: held = set(json.load(open(sys.argv[2])).get("held", []))
except Exception: held = set()
now = datetime.now(timezone.utc)
for m in before:
    if m["name"] == sys.argv[3]: continue
    exp = datetime.fromisoformat(m["expires_at"])
    left = max(900, int((exp - now).total_seconds()))   # what it had left, at least the Host's 15-min idle default
    print(m["name"], "held" if m["name"] in held else "unheld", m.get("context_length") or 4096, left)
PY
)
EXPECT=($WANT)
while read -r name kind ctx left; do
  [[ -z ${name:-} ]] && continue
  EXPECT+=($name)
  if [[ $kind == held ]]; then
    echo "restore: load $name (held before) → $(curl -s -m 180 -X POST $HOSTURL/v1/models/load -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "{\"catalogId\":\"$name\"}" | head -c 200)"
  else
    curl -s -m 180 $OLL/api/generate -d "{\"model\":\"$name\",\"keep_alive\":\"${left}s\",\"options\":{\"num_ctx\":$ctx}}" >/dev/null
    echo "restore: load $name (resident, not held, before) at num_ctx $ctx for ${left}s"
  fi
done <<< "$OTHERS"

# 5. Re-verify.
sleep 1
VERDICT=$(PS=$(curl -s -m 5 $OLL/api/ps) python3 - "$WANT" "$CTX" "$RESIDENCY" ${EXPECT[@]} <<'PY'
import json, sys
want, ctx, res, expect = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
import os
try: ps = {m["name"]: m for m in json.loads(os.environ["PS"]).get("models", [])}
except Exception: ps = {}
try: r = json.load(open(res))
except Exception: r = {}
miss = []
i = ps.get(want)
if not i: miss.append(f"{want} not resident")
else:
    if i.get("context_length") != ctx: miss.append(f"{want} num_ctx {i.get('context_length')} ≠ {ctx}")
    if not i["expires_at"].startswith("2319"): miss.append(f"{want} not held (expires {i['expires_at'][:19]})")
if r.get("mode") != "always-on" or want not in r.get("held", []): miss.append(f"Host residency {r}")
miss += [f"{n} (resident before) not resident" for n in expect if n != want and n not in ps]
print("; ".join(miss) or "ok " + str([(n, m.get("context_length"), m["expires_at"][:4]) for n, m in ps.items()]))
PY
)
[[ $VERDICT == ok* ]] || fail "$VERDICT"
echo "restore: VERIFIED — Ollama answers; ${VERDICT#ok }"
