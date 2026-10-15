#!/bin/zsh
# live-18 (0a) — restore_host.sh against a FAKE Host + Ollama (restore_fake.py) on scratch ports. Never touches T's
# Host (:8787), T's Ollama (:11434) or ~/.airpad-host.
#   scripts/gauntlet/test_restore.sh            → one line per check, then "test_restore: N/M PASS"
# Scenarios:
#   attached   live-17's case: T's Host relaunched itself mid-run and ATTACHED to the scratch Ollama; the run's
#              teardown then stopped that Ollama, so the Host is up with no Ollama and `open` is a no-op.
#   quit       the normal case: the run quit T's Host (and its Ollama); the restore relaunches it.
#   no-ollama  an Ollama that never comes up: the restore must FAIL loudly (non-zero), never report a restore.
# Every scenario had Instruct held (always-on) and Qwen3 8B resident (not held, 10 min left) before the run.
set -uo pipefail
HERE=${0:A:h}
HP=18787; OP=18434
FAKE=$HERE/restore_fake.py
PASS=0; TOTAL=0
check() { (( TOTAL++ )); if eval "$2"; then (( PASS++ )); echo "  PASS  $1"; else echo "  FAIL  $1"; fi }
ps_has() { curl -s -m 2 http://127.0.0.1:$OP/api/ps | python3 -c "
import json,sys; m={x['name']:x for x in json.load(sys.stdin).get('models',[])}; n='$1'
sys.exit(0 if n in m and ('$2'=='' or m[n]['expires_at'].startswith('$2')) and ('$3'=='' or m[n]['context_length']==int('$3')) else 1)" 2>/dev/null; }
cleanup() { pkill -f "restore_fake.py (host|ollama) ($HP|$OP) " 2>/dev/null; sleep 0.5; }

scenario() {
  local name=$1; cleanup
  local D=$(mktemp -d "${TMPDIR:-/tmp}/restore-test-$name.XXXX")
  python3 - "$D/before.json" <<'PY'
import json,sys
from datetime import datetime,timedelta,timezone
soon=(datetime.now(timezone.utc)+timedelta(minutes=10)).isoformat()
json.dump({"models":[{"name":"qwen3:4b-instruct-2507-q4_K_M","context_length":20480,"expires_at":"2319-01-24T16:50:39Z"},
                     {"name":"qwen3:8b-q4_K_M","context_length":20480,"expires_at":soon}]},open(sys.argv[1],"w"))
PY
  echo '{"mode":"always-on","held":["qwen3:4b-instruct-2507-q4_K_M"]}' > "$D/held-before.json"
  cp "$D/held-before.json" "$D/residency.json"
  print -r -- '#!/bin/sh
echo fake-token' > "$D/bin"; chmod +x "$D/bin"
  case $name in
    attached)
      python3 $FAKE ollama $OP "$D" & local SCRATCH=$!          # the run's scratch Ollama
      for i in {1..50}; do curl -s -m 1 http://127.0.0.1:$OP/api/version >/dev/null && break; sleep 0.1; done
      python3 $FAKE ctl open "$D" $HP $OP                         # T's Host relaunches itself → attaches
      sleep 1; kill $SCRATCH; sleep 0.5;;                         # teardown stops the scratch Ollama
    quit|no-ollama) ;;                                            # T's Host and its Ollama were quit
  esac
  [[ $name == no-ollama ]] && export FAKE_HOST_NO_SPAWN=1 || unset FAKE_HOST_NO_SPAWN
  echo "── $name"
  local T0=$(date +%s)
  RESTORE_OLL=http://127.0.0.1:$OP RESTORE_HOST_URL=http://127.0.0.1:$HP RESTORE_HOST_BIN=$D/bin \
  RESTORE_RESIDENCY=$D/residency.json RESTORE_HELD_BEFORE=$D/held-before.json RESTORE_WAIT=5 RESTORE_SETTLE=10 \
  RESTORE_HOST_RUNNING="python3 $FAKE ctl running $D $HP $OP" \
  RESTORE_HOST_OPEN="python3 $FAKE ctl open $D $HP $OP" \
  RESTORE_HOST_QUIT="python3 $FAKE ctl quit $D $HP $OP" \
    $HERE/restore_host.sh "$D/before.json" > "$D/restore.log" 2>&1
  local RC=$?
  /usr/bin/grep -v '^ \|^Traceback\|Error' "$D/restore.log" | sed 's/^/        | /' | tail -14
  echo "        (restore exit=$RC, $(( $(date +%s) - T0 ))s)"
  if [[ $name == no-ollama ]]; then
    check "$name: restore exits non-zero"                       "(( RC != 0 ))"
    check "$name: restore says FAIL"                            "/usr/bin/grep -q 'restore: FAIL' $D/restore.log"
  else
    check "$name: restore exits 0"                              "(( RC == 0 ))"
    check "$name: T's Ollama answers"                           "curl -s -m 2 http://127.0.0.1:$OP/api/version >/dev/null"
    check "$name: Instruct resident, held (2319), num_ctx 20480" "ps_has qwen3:4b-instruct-2507-q4_K_M 2319 20480"
    check "$name: Instruct in the Host's held set"              "/usr/bin/grep -q 'qwen3:4b-instruct-2507-q4_K_M' $D/residency.json"
    check "$name: Qwen3 8B resident again (was resident before)" "ps_has qwen3:8b-q4_K_M '' 20480"
    check "$name: Qwen3 8B NOT held (it wasn't before)"         "! /usr/bin/grep -q 'qwen3:8b' $D/residency.json"
  fi
  python3 $FAKE ctl quit "$D" $HP $OP; cleanup
}

for s in attached quit no-ollama; do scenario $s; done
unset FAKE_HOST_NO_SPAWN
echo "test_restore: $PASS/$TOTAL PASS"
(( PASS == TOTAL ))
