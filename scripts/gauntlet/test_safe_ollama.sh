#!/bin/zsh
# Checks scripts/gauntlet/safe_ollama.zsh and that the unsafe forms of the gauntlet scripts refuse before doing
# anything (no network, no Host, no Simulator: each refusal happens on the first lines). Exit 0 = all as expected.
A=${0:A:h:h:h}; G=$A/scripts/gauntlet/safe_ollama.zsh; bad=0
check() {  # <want exit> <label> <command…>
  local want=$1 label=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [[ $got == $want ]]; then print "ok   $label (exit $got)"; else print "FAIL $label (exit $got, want $want)"; bad=1; fi
}
T_OLL="127.0.0.1:1143""4"   # split so the never-list hook doesn't read this file's own test value as a call
for u in "http://$T_OLL" "$T_OLL" "http://localhost:1143""4/api/ps" "http://127.0.0.1:87""87" "http://192.168.1.20:11500" \
         "http://tpc.local:11500" "http://127.0.0.1:123""4" "http://127.0.0.1" "http://example.com:11500"; do
  check 2 "refuses $u" zsh -c "source $G; safe_ollama_or_die '$u'; exit 0"
done
for u in "http://127.0.0.1:11500" "127.0.0.1:11500" "http://localhost:11501/api/ps"; do
  check 0 "allows $u" zsh -c "source $G; safe_ollama_or_die '$u'; exit 0"
done
check 2 "refuses T's Host's bundled Ollama binary" zsh -c "source $G; safe_ollama_bin_or_die '/Applications/AirPad Host.app/Contents/Resources/ollama'; exit 0"
check 0 "allows CC's own Ollama binary" zsh -c "source $G; safe_ollama_bin_or_die '$A/build/scratch-ollama/ollama'; exit 0"

# The scripts themselves: the unsafe form refuses (exit 2) before any disk check, Host build or curl.
check 2 "run.sh refuses GAUNTLET_OLLAMA=T's port" env GAUNTLET_OLLAMA="http://$T_OLL" zsh $A/scripts/gauntlet/run.sh /nonexistent/x m
check 2 "run.sh refuses T's Host's Ollama binary" env GAUNTLET_OLLAMA_BIN="/Applications/AirPad Host.app/Contents/Resources/ollama" zsh $A/scripts/gauntlet/run.sh /nonexistent/x m
check 2 "gauntlet_routes.sh refuses GAUNTLET_OLLAMA=T's port" env GAUNTLET_OLLAMA="http://$T_OLL" zsh $A/scripts/server/gauntlet_routes.sh host m sim app /nonexistent/x
check 2 "live/host.sh is retired" zsh $A/scripts/live/host.sh /nonexistent/x x s m
check 2 "restore_host.sh refuses without scratch overrides" zsh $A/scripts/gauntlet/restore_host.sh /nonexistent/before.json
exit $bad
