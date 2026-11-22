#!/bin/zsh
# Sweep 2b step 1 — the overnight proof of the Librarian first build, before vs after, in one detached job.
#   nohup zsh scripts/librarian/2b_proof.sh > build/2b-proof/run.log 2>&1 &
# before = build/DD-2a (the arm sweep 2a measured; app code identical to dae8396f), after = build/DD-2b (ws-mac HEAD with
# step 1). CC's OWN Ollama on 127.0.0.1:11500 (models in build/scratch-models) — never 11434, never T's Host or PC.
# One Simulator at a time (bench sim, then the web sim). Progress: build/2b-proof/status.txt (one line per finished run);
# build/2b-proof/DONE when everything ran; the server is stopped at the end. Fixture answers stay in build/ (gitignored).
set -u
cd ${0:A:h:h:h}
ROOT=build/2b-proof; mkdir -p $ROOT; ST=$ROOT/status.txt
B=scripts/librarian/benchmark
BEFORE=$PWD/build/DD-2a/Build/Products/Debug-iphonesimulator/AirPad.app
AFTER=$PWD/build/DD-2b/Build/Products/Debug-iphonesimulator/AirPad.app
export BENCH_TIMEOUT=7200; fails=0
note() { echo "$(date '+%F %T') $*" | tee -a $ST; }

if ! curl -s 127.0.0.1:11500/api/version >/dev/null; then
  OLLAMA_HOST=127.0.0.1:11500 OLLAMA_MODELS=$PWD/build/scratch-models build/scratch-ollama/ollama serve > $ROOT/ollama.log 2>&1 &
  echo $! > $ROOT/ollama.pid
  for i in {1..30}; do curl -s 127.0.0.1:11500/api/version >/dev/null && break; sleep 1; done
fi
note "start · own Ollama 11500 pid $(cat $ROOT/ollama.pid 2>/dev/null) · after=$(git rev-parse --short HEAD)"

# 1. benchmark matrix: after first, then before; 3 reps × 3 libraries × (4B, Apple, 9B)
for arm in after before; do
  APP=$([[ $arm == before ]] && echo $BEFORE || echo $AFTER)
  for rep in 1 2 3; do for set in bench sample fixture-gk; do
    first=1
    for rm in "server qwen3.5:4b" "apple -" "server qwen3.5:9b"; do
      route=${rm%% *}; model=${rm#* }; tag=${model//[:.]/}; [[ $route == apple ]] && tag=apple
      out=$ROOT/$arm/$set-$tag-r$rep; mkdir -p $ROOT/$arm
      [[ -f $out/graded.json ]] && { first=0; continue }
      fresh=(); (( rep == 1 && first == 1 )) && fresh=(--fresh); first=0
      priv=(); [[ $set == fixture-gk ]] && priv=(--private)
      BENCH_APP=$APP zsh scripts/librarian/bench.sh $route $model $B/cases-$set.json $out $fresh > $out.log 2>&1
      python3 scripts/librarian/bench.py grade $B/cases-$set.json $out/results.json --json $out/graded.json --md $out/graded.md $priv > /dev/null 2>&1
      if [[ -f $out/graded.json ]]; then note "bench $arm $set $tag r$rep ok"
      else note "bench $arm $set $tag r$rep FAILED (see $out.log)"; (( ++fails >= 3 )) && { note "STOP: 3 bench failures"; kill $(cat $ROOT/ollama.pid) 2>/dev/null; exit 1 }; fi
    done
  done; done
done
xcrun simctl shutdown $(cat build/sweep2a/sim.udid) 2>/dev/null

# 2. the gauntlet (59 cases, T's fixture clone; table by case ID only): Host and server routes, after and before
for arm in after before; do
  APP=$([[ $arm == before ]] && echo $BEFORE || echo $AFTER)
  for route in host server; do
    out=$ROOT/gauntlet-$arm-$route
    [[ -f $out.done ]] && continue
    rm -rf $out
    GAUNTLET_OLLAMA=http://127.0.0.1:11500 zsh scripts/server/gauntlet_routes.sh $route qwen3.5:4b $(cat build/sweep2a/sim.udid) $APP $out > $out.log 2>&1
    e=$?; (( e == 0 )) && touch $out.done; note "gauntlet $arm $route exit $e"
  done
done
xcrun simctl shutdown $(cat build/sweep2a/sim.udid) 2>/dev/null

# 3. web cases (27 = 9 turns × 3) on the after build: Brave and Tavily on Apple, one server run each
for prov in brave tavily; do
  for rm in "apple -" "server qwen3.5:4b"; do
    route=${rm%% *}; model=${rm#* }
    out=$ROOT/web-$prov-$route
    [[ -f $out.grade.txt ]] && continue
    BENCH_APP=$AFTER zsh scripts/librarian/web_bench.sh $prov $route $model $out > $out.log 2>&1
    python3 scripts/librarian/web_grade.py $B/cases-web.json $out > $out.grade.txt 2>&1
    note "web $prov $route $(tail -1 $out.grade.txt | cut -c1-80)"
  done
done
xcrun simctl shutdown $(cat build/sweep2a/sim-web.udid) 2>/dev/null

# 4. tables
python3 scripts/librarian/bench.py matrix $ROOT --private > $ROOT/matrix.md 2>&1
python3 scripts/librarian/coverage.py $ROOT --private > $ROOT/coverage.md 2>&1
python3 build/sweep2a/gauntlet_table.py $ROOT/gauntlet-* > $ROOT/gauntlet.md 2>&1
[[ -f $ROOT/ollama.pid ]] && kill $(cat $ROOT/ollama.pid) 2>/dev/null
note "DONE · tables: matrix.md coverage.md gauntlet.md · own Ollama stopped"
touch $ROOT/DONE
