# Sweep 2b amend b (2026-11-22): CC's gauntlet scripts reach CC's own Ollama only (127.0.0.1:11500, or another
# loopback scratch port) and CC's own scratch Host (127.0.0.1:8799). T's Ollama (11434), T's Host (8787, its app,
# its bundled Ollama), LM Studio (1234) and anything off this Mac are refused: exit 2, before anything starts.
# Sourced by scripts/gauntlet/run.sh, scripts/server/gauntlet_routes.sh; checked by scripts/gauntlet/test_safe_ollama.sh.

safe_ollama_or_die() {  # $1 = http://host:port[/…] or host:port
  local u=${1#http://}; u=${u#https://}; u=${u%%/*}
  local h=${u%:*} p=${u##*:}
  if [[ $u != *:* || $h != (127.0.0.1|localhost) || $p != <-> || $p == (11434|8787|1234) ]]; then
    print -u2 "REFUSED (never list): '$1' is not CC's own Ollama on a loopback scratch port. Use http://127.0.0.1:11500."
    exit 2
  fi
}

safe_ollama_bin_or_die() {  # $1 = the Ollama binary a scratch Host may spawn
  if [[ $1 == *"AirPad Host.app"* ]]; then
    print -u2 "REFUSED (never list): '$1' is T's Host's bundled Ollama. Use build/scratch-ollama/ollama."
    exit 2
  fi
}
