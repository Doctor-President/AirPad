#!/bin/zsh
# live-36 (3) — the fixed regression set on one tier, one command:
#   scripts/live/regress.sh <apple|4b|8b|30b> [out_dir]        (env: REGRESS_XCTESTRUN, REGRESS_BUILD=1, LIVE_ONLY=ID,…)
# apple = Apple Intelligence on-device (this Mac's, in the iOS 27 Simulator); 4b / 8b / 30b = the Host's shelf models
# through a scratch Host (scripts/live/host.sh: T's Host is quit first and restored + VERIFIED after).
# Provider: Tavily (the Keychain key; never written). While it runs, `ollama ps` is sampled (the served context) and the
# Host's presence-only lines are kept (chat→ollama num_ctx, chat done prompt_eval). Then scripts/live/regress.py grades:
# retrieval (gold in what the model received, and where it was lost) and the answer (strict / relaxed), per category.
# REGRESS_SET = another set (live-37: the smoke set); REGRESS_EXTRA_ARGS = more app launch args.
# REGRESS_BUILD=1 builds the current tree for testing first (Debug, the iOS 27 Simulator); REGRESS_BUILD_DIR = where builds
# and runs go (default <repo>/build).
set -uo pipefail
TIER=${1:?apple|4b|8b|30b}; AIRPAD=${0:A:h:h:h}
BUILD=${REGRESS_BUILD_DIR:-$AIRPAD/build}
OUT=${2:-$BUILD/regress-runs/$(date +%Y%m%d-%H%M)-$TIER}
SET=${REGRESS_SET:-$AIRPAD/scripts/live/set-regression.json}
SIM=${LIVE_SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}
DD=$BUILD/dd-regress
XCTR=${REGRESS_XCTESTRUN:-$DD/Build/Products/AirPad_iphonesimulator27.0-arm64.xctestrun}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
if [[ ${REGRESS_BUILD:-0} == 1 || ! -f $XCTR ]]; then
  echo "[regress] build-for-testing → $DD"
  (cd $AIRPAD && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirPad.xcodeproj -scheme AirPad \
     -configuration Debug -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD build-for-testing > "$OUT/build.log" 2>&1) \
    || { echo "[regress] build FAILED — $OUT/build.log"; exit 1; }
  git -C $AIRPAD checkout -- AirPad.xcodeproj/xcshareddata 2>/dev/null
fi
git -C $AIRPAD rev-parse --short HEAD > "$OUT/commit.txt"
case $TIER in
  apple) LABEL="Apple Intelligence (on-device)";;
  4b)  MODEL=qwen3:4b-instruct-2507-q4_K_M;     LABEL="qwen3:4b (Host)";;
  8b)  MODEL=qwen3:8b-q4_K_M;                    LABEL="qwen3 8B (Host)";;
  30b) MODEL=qwen3:30b-a3b-instruct-2507-q4_K_M; LABEL="qwen3 30B-A3B (Host)";;
  *) echo "tier: apple|4b|8b|30b"; exit 2;;
esac
if [[ $TIER == apple ]]; then
  $AIRPAD/scripts/live/run.sh "$OUT/run" "$XCTR" "$SET" tavily -ResetLibrarianRoute YES -ClearHostPairing YES -airpadLibrarianRoute onDevice ${(z)REGRESS_EXTRA_ARGS:-} \
    > "$OUT/run.out" 2>&1
else
  # the served window while it runs (Ollama's own view: context_length per resident model)
  ( while true; do print -r -- "{\"t\":\"$(date +%H:%M:%S)\",\"ps\":$(curl -s -m 2 127.0.0.1:11434/api/ps || echo null)}" >> "$OUT/ollama-ps.jsonl"; sleep 5; done ) &
  PS_PID=$!
  $AIRPAD/scripts/live/host.sh "$OUT/host" "$XCTR" "$SET" "$MODEL" "run|tavily|${REGRESS_EXTRA_ARGS:-}" > "$OUT/host.out" 2>&1
  kill $PS_PID 2>/dev/null
  mv "$OUT/host/run" "$OUT/run" 2>/dev/null
  /usr/bin/grep -E "chat→ollama|chat done" "$OUT/host/host.log" | cut -c1-240 > "$OUT/host-presence.log"
  /usr/bin/grep -E "restore:|NOT RESTORED" "$OUT/host.out" | tail -3
  python3 - "$OUT/ollama-ps.jsonl" <<'EOF' | tee "$OUT/ctx.txt"
import json, sys
seen = {}
for l in open(sys.argv[1]):
    try: d = json.loads(l)
    except Exception: continue
    for m in ((d.get("ps") or {}).get("models") or []): seen.setdefault((m["name"], m.get("context_length")), d["t"])
print("served while running (ollama ps): " + "; ".join(f"{n} ctx={c} (first {t})" for (n, c), t in seen.items()))
EOF
fi
python3 $AIRPAD/scripts/live/regress.py "$SET" "$OUT/run/webtrace.jsonl" "$OUT" "$LABEL @ $(cat $OUT/commit.txt)" "$OUT/reviews.json"
echo "[regress] $OUT/{summary.md,table.md,grades.json}"
