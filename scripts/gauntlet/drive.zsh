# Brief CJ — drive a planned gauntlet run through the real UI on ONE Simulator (shards=1, the original path) or
# across N Simulators at once (shards>1: clones of the main Simulator, made once and kept). Sourced by run.sh and
# lab.sh. Needs: AIRPAD, DD, DEVELOPER_DIR; log() from the caller.
#   drive_ui <run_dir> <sim> <shards> <stall_age_s> <min_uptime_s>

drive_one() {   # <dir> <sim> <stall_age> <min_uptime> — watchdog + one xcodebuild, as the single-sim path always did
  local dir=$1 sim=$2 stall=$3 up0=$4
  # Never start on a Simulator another xcodebuild is still testing on: installing our runner kills its runner and
  # it kills ours on its retry (CH-B 8b-top-off shard-2: 0 tests, 5 rows never driven).
  while pgrep -f "xcodebuild.*id=$sim " > /dev/null; do
    print -r -- "[drive $(date +%H:%M:%S)] waiting: another xcodebuild is testing on $sim" >> "$dir/run.log"; sleep 10
  done
  xcrun simctl boot $sim 2>/dev/null; xcrun simctl bootstatus $sim -b >/dev/null 2>&1
  # Watchdog — a hung app (main-thread heartbeat stale, app alive) freezes the XCUITest driver too (it waits for
  # "idle" forever). Sample it as evidence, drop a hung-<epoch> marker (the driver turns that into an A8 FAIL for
  # the row), and kill THAT pid — never by bundle id (it races the next launch).
  ( while true; do
      sleep 10
      [[ -f $dir/heartbeat ]] || continue
      local APID=$(pgrep -f "Devices/$sim/.*AirPad.app/AirPad" | head -1); [[ -n $APID ]] || continue
      local up=$(ps -o etime= -p $APID | awk -F'[:-]' '{n=NF; s=$n+($(n-1))*60; if(n>2)s+=$(n-2)*3600; print s}')
      local age=$(( $(date +%s) - $(cut -d. -f1 $dir/heartbeat) ))
      if (( age > stall && up > up0 )); then
        local E=$(date +%s); sample $APID 3 -mayDie > "$dir/hung-$E.sample.txt" 2>/dev/null
        kill -9 $APID 2>/dev/null; touch "$dir/hung-$E"
        print -r -- "[drive $(date +%H:%M:%S)] WATCHDOG ($dir:t): app main thread stalled ${age}s — sampled + killed" >> "$dir/run.log"
      fi
    done ) &
  local WP=$!
  rm -rf "$dir/result.xcresult"
  # -collect-test-diagnostics never: after a PASSING run on a cloned Simulator, xcodebuild sat 600 s collecting a
  # sysdiagnose nobody reads (Brief CJ shard-2 run, 2026-10-10).
  TEST_RUNNER_GAUNTLET_CONFIG="$dir/config.json" xcodebuild -project $AIRPAD/AirPad.xcodeproj -scheme AirPad \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath $DD -resultBundlePath "$dir/result.xcresult" -collect-test-diagnostics never \
    -only-testing:AirPadUITests/LibrarianGauntletV2/testRunGauntlet test-without-building > "$dir/xcuitest.log" 2>&1
  local rc=$?
  kill $WP 2>/dev/null
  return $rc
}

shard_sims() {   # <main sim> <n> → n Simulator ids (the main one + clones named "AirPad gauntlet shard k")
  local main=$1 n=$2 k id
  print -r -- $main
  for (( k = 2; k <= n; k++ )); do
    id=$(xcrun simctl list devices -j | python3 -c "import json,sys;print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='AirPad gauntlet shard $k'),''))")
    if [[ -z $id ]]; then
      xcrun simctl shutdown $main 2>/dev/null
      id=$(xcrun simctl clone $main "AirPad gauntlet shard $k")
    fi
    print -r -- $id
  done
}

drive_ui() {
  local run_dir=$1 sim=$2 shards=$3 stall=$4 up0=$5
  if (( shards <= 1 )); then
    drive_one "$run_dir" $sim $stall $up0; return
  fi
  local names=(${(z)$(python3 $AIRPAD/scripts/gauntlet/shard.py split "$run_dir" $shards)})
  local sims=(${(f)"$(shard_sims $sim $shards)"})
  log "shards: ${names[*]} on ${#sims} Simulators"
  local k=1 pids=()
  for name in $names; do
    if [[ $name == shard-solo ]]; then
      log "  $name (alone first: cold-load rows) on ${sims[1]}"
      drive_one "$run_dir/$name" ${sims[1]} $stall $up0
      continue
    fi
    drive_one "$run_dir/$name" ${sims[$k]} $stall $up0 &
    pids+=($!); log "  $name on ${sims[$k]}"; (( k++ ))
  done
  wait $pids
  # `wait` has returned while a shard's xcodebuild was still driving (CH-B: 8B and 8b-top-on both merged when
  # shard-1 ended; 8b-top-on's shard-2 ran on 2 min, and the next run's xcodebuild on the same Simulator killed
  # both runners → rows never driven). Also wait on the xcodebuilds themselves, by result bundle.
  local w=0
  while pgrep -f "resultBundlePath $run_dir/shard-" > /dev/null; do
    (( w++ % 12 )) || log "  a shard's xcodebuild is still running after wait — waiting for it"
    sleep 5
  done
  for name in $names; do [[ -f $run_dir/$name/run.log ]] && cat "$run_dir/$name/run.log" >> "$run_dir/run.log"; done
  python3 $AIRPAD/scripts/gauntlet/shard.py merge "$run_dir" | while read -r l; do log "$l"; done
}
