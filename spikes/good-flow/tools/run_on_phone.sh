#!/bin/zsh
# Good Flow spike · the iPhone half at T's touch: install the spike app, run a list of bench cases, pull the recordings.
# Modelled on sweep 2b's spikes/iphone-2b/run_on_phone.sh (ws-mac). App arguments go AFTER `--` in devicectl's launch.
#
#   tools/run_on_phone.sh <UDID> --i-warned-T [--benches LIST] [--seconds 240] [--cooldown 120] [--stills] [--no-build]
#                                            [--power] [--uninstall]
#   LIST = comma-separated <case>[:<theme>[:<variant>[:<extra>[+<extra>…]]]], e.g. "map:light:A,detail:light:BD50:scale2"
#          (extra: flat | liveoff | still | live60 | scale2 | zone | redraw | pass2; see the loop below). Default: map, cards, detail (light, A), each --seconds of programmatic
#          motion + 10 s rest; then --stills renders the 120 reference stills ON THE PHONE (phone vs Mac equality).
#   --power   also records xctrace (Power Profiler, if this Xcode has the template) over each bench (attached by pid).
#
# REFUSES unless --i-warned-T is given: the lead tells T first ("running on your phone, watch for the Allow / passcode
# prompt"). The app is the spike's own bundle (com.doctorpresident.spike.SpikeHarness, "Good Flow"), NOT AirPad: T's
# AirPad install and its library are never touched. Signing: Automatic, OFFLINE (the existing Xcode-managed profile);
# never -allowProvisioningUpdates. The app STAYS on the phone afterwards (T keeps looking) unless --uninstall.
set -uo pipefail
SPIKE=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUNDLE=com.doctorpresident.spike.SpikeHarness
APP=$SPIKE/build/dd/Build/Products/Release-iphoneos/GoodFlow.app
UDID=${1:-}; [[ -z $UDID || $UDID == --* ]] && { echo "usage: run_on_phone.sh <UDID> --i-warned-T [options]"; exit 64 }
shift
WARNED=0; BENCHES="map:light:A,cards:light:A,detail:light:A"; SECS=240; COOL=120; STILLS=0; BUILD=1; POWER=0; UNINSTALL=0
while (( $# )); do
  case $1 in
    --i-warned-T) WARNED=1 ;;
    --benches) BENCHES=$2; shift ;;
    --seconds) SECS=$2; shift ;;
    --cooldown) COOL=$2; shift ;;
    --stills) STILLS=1 ;;
    --no-build) BUILD=0 ;;
    --power) POWER=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option $1"; exit 64 ;;
  esac; shift
done
(( WARNED )) || { echo "REFUSED: pass --i-warned-T only after T has been told the phone run is starting (and how long it takes)."; exit 2 }
OUT=$SPIKE/build/phone-runs/$(date +%Y%m%d-%H%M%S); mkdir -p $OUT; TMP=$OUT/.devicectl; mkdir -p $TMP
say() { print -r -- "[run_on_phone $(date +%H:%M:%S)] $*"; }
die() { say "REFUSED: $*"; exit ${2:-2}; }
avail=$(df -g / | awk 'NR==2 {print $4}'); (( avail >= 15 )) || die "only ${avail} GB free on this Mac (need ≥ 15)"
if (( BUILD )); then
  say "building the spike (Release, generic iOS, Automatic signing offline)"
  xcodebuild -project $SPIKE/GoodFlow.xcodeproj -scheme GoodFlow -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath $SPIKE/build/dd build > $OUT/build.log 2>&1 || { grep -E " error:" $OUT/build.log | head; die "build failed ($OUT/build.log)" 3; }
fi
[[ -d $APP ]] || die "no app at $APP" 3
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $APP/Info.plist) == $BUNDLE ]] || die "the built app is not $BUNDLE" 3
N=$(echo $BENCHES | tr ',' '\n' | wc -l | tr -d ' ')
MIN=$(( (N * (SECS + 20 + COOL) + (STILLS ? 120 : 0)) / 60 + 1 ))
print ""
print "████████████████████████████████████████████████████████████████████████████████████████"
print "██  RUNNING ON T'S iPHONE ($UDID): watch for the Allow / passcode prompt; keep it unlocked + plugged in."
print "██  App: Good Flow ($BUNDLE, not AirPad), $(du -sm $APP | cut -f1) MB. $N case(s) × ${SECS} s + ${COOL} s cool-down ≈ ${MIN} min."
print "██  The phone runs PROGRAMMATIC motion (no hand needed); Low Power off, thermal nominal at the start."
print "████████████████████████████████████████████████████████████████████████████████████████"
xcrun devicectl list devices --json-output $TMP/devices.json > /dev/null 2>&1 || die "devicectl list devices failed"
python3 -I - "$TMP/devices.json" "$UDID" <<'PY' || die "the phone is not ready (see above)"
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
d = next((x for x in devs if x.get("hardwareProperties", {}).get("udid") == sys.argv[2] or x.get("identifier") == sys.argv[2]), None)
if d is None: sys.exit(f"  no paired device {sys.argv[2]}")
c, p = d.get("connectionProperties", {}), d.get("deviceProperties", {})
print(f"  {p.get('name','?')} · {d['hardwareProperties'].get('productType')} · iOS {p.get('osVersionNumber')} · tunnel {c.get('tunnelState')} · developer mode {p.get('developerModeStatus')}")
if c.get("tunnelState") != "connected": sys.exit("  not connected: plug in and unlock")
if p.get("developerModeStatus") != "enabled": sys.exit("  Developer Mode is not enabled")
PY
xcrun devicectl device info lockState --device $UDID --json-output $TMP/lock.json > /dev/null 2>&1 || die "could not read the lock state"
python3 -I -c "import json,sys; r=json.load(open(sys.argv[1])).get('result',{}); print('  lock state:', r); sys.exit(1 if r.get('passcodeRequired') and not r.get('unlockedSinceBoot', True) else 0)" $TMP/lock.json || die "the phone is locked"
say "installing Good Flow (replaces only an earlier Good Flow / SpikeHarness install)"
xcrun devicectl device install app --device $UDID $APP > $TMP/install.log 2>&1 || { tail -5 $TMP/install.log; die "install failed" 4; }
pull() {   # pull Documents/<src> to $OUT/<dst>
  xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE --source Documents/$1 --destination $OUT/$2 > /dev/null 2>&1
}
i=0
for b in ${(s:,:)BENCHES}; do
  i=$((i+1)); parts=(${(s.:.)b}); CASE=${parts[1]}; TH=${parts[2]:-light}; VAR=${parts[3]:-A}; EXTRA=${parts[4]:-}
  ARGS=(-Bench $CASE -Seconds $SECS -Theme $TH -Variant $VAR)
  # extras, joined by "+": flat | liveoff | live60 | scale2 (-LiveScale 2) | zone (-LiveZone image) | redraw (-ScrollRedraw on,
  # round 1's harness) | pass2 (-Pass2Only YES, a timing arm) | still (-Live off, the still arm) | dark handled by <theme>
  for x in ${(s:+:)EXTRA}; do case $x in
    flat) ARGS+=(-Flat on) ;; liveoff|still) ARGS+=(-Live off) ;; live60) ARGS+=(-LiveRate 60) ;;
    scale2) ARGS+=(-LiveScale 2) ;; zone) ARGS+=(-LiveZone image) ;; redraw) ARGS+=(-ScrollRedraw on) ;; pass2) ARGS+=(-Pass2Only YES) ;;
    "") ;; *) say "unknown extra $x"; exit 64 ;;
  esac; done
  say "bench $i/$N: ${ARGS[*]}"
  xcrun devicectl device process launch --device $UDID --terminate-existing $BUNDLE -- ${ARGS[@]} > $TMP/launch-$i.log 2>&1 || { tail -5 $TMP/launch-$i.log; die "launch failed (trusted developer? unlocked?)" 4; }
  XP=
  if (( POWER )); then
    PID=$(xcrun devicectl device info processes --device $UDID --json-output $TMP/procs.json > /dev/null 2>&1; python3 -I -c "import json,sys; ps=json.load(open(sys.argv[1]))['result']['runningProcesses']; print(next((str(p['processIdentifier']) for p in ps if 'GoodFlow.app' in p.get('executable','')), ''))" $TMP/procs.json)
    [[ -n $PID ]] && { xcrun xctrace record --device $UDID --template 'Power Profiler' --attach $PID --time-limit $((SECS + 15))s --output $OUT/bench-$i.trace --no-prompt > $OUT/xctrace-$i.log 2>&1 & XP=$! }
  fi
  deadline=$(( SECONDS + SECS + 90 )); done_=0
  while (( SECONDS < deadline )); do
    sleep 10; rm -f $OUT/progress.json; pull recordings/bench-done.json progress.json || continue
    st=$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('state'), d.get('file',''))" $OUT/progress.json 2>/dev/null)
    say "  $st"
    [[ $st == done* ]] && { done_=1; break }
  done
  [[ -n $XP ]] && wait $XP
  if (( done_ )); then
    f=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['file'])" $OUT/progress.json)
    pull recordings/$f $f && say "  pulled $f" && python3 $SPIKE/tools/frames.py $OUT/$f --design > $OUT/${f%.json}.txt 2>&1
  else say "  WARNING: bench $i did not finish"; fi
  (( i < N )) && { say "cool-down ${COOL} s"; sleep $COOL }
done
if (( STILLS )); then
  say "rendering the 120 reference stills on the phone (phone vs Mac equality)"
  xcrun devicectl device process launch --device $UDID --terminate-existing $BUNDLE -- -RenderStills phone-stills -StillsRepeat 3 > $TMP/launch-stills.log 2>&1
  for k in $(seq 1 30); do sleep 6; pull phone-stills/DONE stills-DONE && break; done
  xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE --source Documents/phone-stills --destination $OUT/phone-stills > /dev/null 2>&1
  # round 2: the Mac's stills with the pool table (tools/r2_stills.sh pools-bench); REF= to compare with another set
  python3 $SPIKE/tools/compare.py --ref ${REF:-$SPIKE/build/r2/pools-bench} --port $OUT/phone-stills > $OUT/phone-vs-mac.md 2>&1; tail -3 $OUT/phone-vs-mac.md
  python3 $SPIKE/tools/compare.py --ref $SPIKE/build/reference --port $OUT/phone-stills --title "phone vs T's bench" > $OUT/phone-vs-bench.md 2>&1; tail -2 $OUT/phone-vs-bench.md
  python3 $SPIKE/tools/timings.py $OUT/phone-stills/timings.json > $OUT/phone-still-timings.md 2>&1
fi
if (( UNINSTALL )); then xcrun devicectl device uninstall app --device $UDID $BUNDLE > $TMP/uninstall.log 2>&1 && say "uninstalled"
else say "Good Flow stays on the phone (T keeps looking); remove with: xcrun devicectl device uninstall app --device $UDID $BUNDLE"; fi
say "results: $OUT"
