#!/bin/zsh
# Sweep 2b · 3.3 — the whole iPhone spike at one touch: T plugs in and unlocks the phone, CC runs this.
#
#   spikes/iphone-2b/run_on_phone.sh <UDID> [--keep] [--phases all|apple|mlx] [--dry-run] [--no-build]
#                                          [--bundle-id ID] [--timeout-min 25] [--repeats 6] [--mlx-repeats 3]
#
#   1. builds the spike app (Release, generic iOS; no device needed)            ~1 min if cached
#   2. warns loudly, then preflights: device connected + paired + Developer Mode, unlocked; refuses otherwise
#   3. installs the app, asks it for the phone's free space (≥ 6 GB or it stops) ~10 s
#   4. copies the Qwen3.5 4B weights (3.06 GB) into the app's container by USB  ~1–2 min
#   5. launches the battery and polls Documents/spike-progress.json every 10 s  ~9–10 min
#   6. copies results to build/iphone-spike/results/<timestamp>/, grades them (grade.py → answers.md)
#   7. uninstalls the app (its container and the weights go with it) and confirms it is gone; --keep skips this
#
# It never touches AirPad (a different bundle id) or T's library; every passage in the battery is invented.
set -uo pipefail
ROOT=${0:A:h:h:h}
SPIKE=$ROOT/spikes/iphone-2b
B=$ROOT/build/iphone-spike
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
MODEL_NAME=Qwen3.5-4B-MLX-4bit
MODEL_DIR=$B/models/$MODEL_NAME
APP=$B/dd/Build/Products/Release-iphoneos/Spike2b.app

UDID=${1:-}
[[ -z $UDID || $UDID == --* ]] && { echo "usage: run_on_phone.sh <UDID> [--keep] [--phases all|apple|mlx] [--dry-run] [--no-build] [--bundle-id ID] [--timeout-min N]"; exit 64; }
shift
KEEP=0; PHASES=all; DRY=0; BUILD=1; BUNDLE=com.doctorpresident.spike.SpikeHarness; TIMEOUT_MIN=25; REPEATS=6; MLX_REPEATS=3
while (( $# )); do
  case $1 in
    --keep) KEEP=1 ;;
    --phases) PHASES=$2; shift ;;
    --dry-run) DRY=1 ;;
    --no-build) BUILD=0 ;;
    --bundle-id) BUNDLE=$2; shift ;;
    --timeout-min) TIMEOUT_MIN=$2; shift ;;
    --repeats) REPEATS=$2; shift ;;
    --mlx-repeats) MLX_REPEATS=$2; shift ;;
    *) echo "unknown option $1"; exit 64 ;;
  esac
  shift
done
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$B/results/$STAMP
mkdir -p $OUT
TMP=$OUT/.devicectl; mkdir -p $TMP
say() { print -r -- "[run_on_phone $(date +%H:%M:%S)] $*"; }
die() { say "REFUSED: $*"; exit ${2:-2}; }

# ── Mac side first (nothing on the phone yet) ──────────────────────────────────────────────────────────────────────
avail_gb=$(df -g / | awk 'NR==2 {print $4}')
(( avail_gb >= 15 )) || die "only ${avail_gb} GB free on this Mac (need ≥ 15)"
if [[ $PHASES == all || $PHASES == *mlx* ]] && (( ! DRY )); then
  python3 -I - "$MODEL_DIR" <<'PY' || die "weights missing or wrong size: run spikes/iphone-2b/fetch_weights.sh"
import json, os, sys
d = sys.argv[1]
tree = {f["path"]: f["size"] for f in json.load(open(d + ".hf-tree.json")) if f["type"] == "file"}
names = [n for n in os.listdir(d) if not n.startswith(".")]
bad = [n for n in names if os.path.getsize(os.path.join(d, n)) != tree.get(n)]
if not names or bad or "model.safetensors" not in names: sys.exit(f"bad: {bad or 'empty'}")
print(f"weights ok on the Mac: {len(names)} files, {sum(os.path.getsize(os.path.join(d, n)) for n in names) / 1e9:.2f} GB")
PY
fi
if (( BUILD )); then
  say "building the spike app (Release, generic iOS, bundle $BUNDLE)"
  xcodebuild -project $SPIKE/Spike2b.xcodeproj -scheme Spike2b -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath $B/dd -clonedSourcePackagesDirPath $B/spm -allowProvisioningUpdates SPIKE_BUNDLE_ID=$BUNDLE build > $OUT/build.log 2>&1 \
    || { grep -E "error:" $OUT/build.log | head -20; die "build failed (log: $OUT/build.log)" 3; }
fi
[[ -d $APP ]] || die "no app at $APP (build first)" 3
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $APP/Info.plist) == $BUNDLE ]] || die "the built app is not $BUNDLE (rebuild without --no-build)" 3

# ── The phone ──────────────────────────────────────────────────────────────────────────────────────────────────────
print ""
print "████████████████████████████████████████████████████████████████████████████████████████"
print "██  RUNNING ON T'S DEVICE ($UDID)."
print "██  WATCH THE PHONE FOR THE 'Allow' / PASSCODE PROMPT and keep it unlocked + plugged in."
print "██  App: $BUNDLE (not AirPad). About 12 minutes in all, then the app is uninstalled."
print "████████████████████████████████████████████████████████████████████████████████████████"
print ""

xcrun devicectl list devices --json-output $TMP/devices.json > /dev/null 2>&1 || die "devicectl list devices failed"
python3 -I - "$TMP/devices.json" "$UDID" <<'PY' || die "the phone is not ready (see above)"
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
d = next((x for x in devs if x.get("hardwareProperties", {}).get("udid") == sys.argv[2] or x.get("identifier") == sys.argv[2]), None)
if d is None: sys.exit(f"  no paired device with UDID {sys.argv[2]}")
c, p = d.get("connectionProperties", {}), d.get("deviceProperties", {})
print(f"  {p.get('name', '?')} · {d['hardwareProperties'].get('productType')} · iOS {p.get('osVersionNumber')} · tunnel {c.get('tunnelState')} · "
      f"pairing {c.get('pairingState')} · developer mode {p.get('developerModeStatus')}")
if c.get("tunnelState") != "connected": sys.exit("  not connected: plug the phone in (USB) and unlock it")
if c.get("pairingState") != "paired": sys.exit("  not paired with this Mac")
if p.get("developerModeStatus") != "enabled": sys.exit("  Developer Mode is not enabled")
PY

xcrun devicectl device info lockState --device $UDID --json-output $TMP/lock.json > /dev/null 2>&1 || die "could not read the lock state"
python3 -I - "$TMP/lock.json" <<'PY' || die "the phone is locked: unlock it and run again"
import json, sys
r = json.load(open(sys.argv[1])).get("result", {})
print(f"  lock state: {r}")
locked = [k for k, v in r.items() if v is True and "lock" in k.lower() and "unlock" not in k.lower()]
if locked or r.get("passcodeRequired") is True and r.get("unlockedSinceBoot") is False: sys.exit(1)
PY

INSTALLED=0
cleanup() {
  local rc=$?
  if (( INSTALLED )); then
    # Whatever happened, bring back what the app wrote.
    for f in spike-results.json spike-progress.json; do
      [[ -s $OUT/$f ]] || xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE \
        --source Documents/$f --destination $OUT/$f > /dev/null 2>&1
    done
    if (( KEEP )); then
      say "--keep: the app and its weights stay on the phone ($BUNDLE)"
    else
      say "uninstalling $BUNDLE (removes its container and the weights)"
      xcrun devicectl device uninstall app --device $UDID $BUNDLE > $TMP/uninstall.log 2>&1
      xcrun devicectl device info apps --device $UDID --bundle-id $BUNDLE --json-output $TMP/apps-after.json > /dev/null 2>&1
      if python3 -I -c "import json,sys; a=json.load(open(sys.argv[1]))['result'].get('apps',[]); sys.exit(1 if a else 0)" $TMP/apps-after.json 2>/dev/null; then
        say "confirmed: $BUNDLE is no longer installed"
      else
        say "WARNING: could not confirm the uninstall — check the phone for 'Spike 2b' (log: $TMP/uninstall.log)"
      fi
    fi
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

xcrun devicectl device info apps --device $UDID --bundle-id $BUNDLE --json-output $TMP/apps-before.json > /dev/null 2>&1
python3 -I -c "import json,sys; a=json.load(open(sys.argv[1]))['result'].get('apps',[]); print('  note: an older', a[0].get('name'), 'install of this bundle id is on the phone; it will be replaced and then removed') if a else None" $TMP/apps-before.json 2>/dev/null

say "installing the spike app"
xcrun devicectl device install app --device $UDID $APP > $TMP/install.log 2>&1 || { tail -5 $TMP/install.log; die "install failed" 4; }
INSTALLED=1

say "asking the app for the phone's free space"
xcrun devicectl device process launch --device $UDID --terminate-existing $BUNDLE -SpikeFreeSpaceOnly YES > $TMP/launch-free.log 2>&1 || { tail -5 $TMP/launch-free.log; die "launch failed (is the phone unlocked? did it ask to trust the developer?)" 4; }
FREE_OK=0
for i in {1..15}; do
  sleep 2
  if xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE \
       --source Documents/spike-freespace.json --destination $OUT/freespace.json > /dev/null 2>&1 && [[ -s $OUT/freespace.json ]]; then FREE_OK=1; break; fi
done
(( FREE_OK )) || die "the app did not report free space (if the phone shows 'Untrusted Developer', trust it in Settings › General › VPN & Device Management and run again)" 4
NEED=$(( 6 * 1000 * 1000 * 1000 ))
python3 -I - "$OUT/freespace.json" $NEED <<'PY' || die "less than 6 GB free on the phone" 5
import json, sys
f = json.load(open(sys.argv[1])); free = f.get("importantUsageBytes", -1)
print(f"  phone free space: {free / 1e9:.1f} GB (important usage), total {f.get('totalBytes', 0) / 1e9:.0f} GB")
sys.exit(0 if free >= int(sys.argv[2]) else 1)
PY

if [[ $PHASES == all || $PHASES == *mlx* ]] && (( ! DRY )); then
  say "copying the weights to the phone by USB (3.06 GB)"
  t0=$SECONDS
  xcrun devicectl device copy to --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source $MODEL_DIR --destination Documents/models/$MODEL_NAME > $TMP/copy.log 2>&1 || { tail -5 $TMP/copy.log; die "weights copy failed" 6; }
  say "weights copied in $(( SECONDS - t0 )) s"
fi

ARGS=(-SpikePhases $PHASES -SpikeRepeats $REPEATS -SpikeMLXRepeats $MLX_REPEATS)
(( DRY )) && ARGS+=(-SpikeDryRun YES)
say "launching the battery (${ARGS[*]})"
xcrun devicectl device process launch --device $UDID --terminate-existing $BUNDLE $ARGS > $TMP/launch.log 2>&1 || { tail -5 $TMP/launch.log; die "launch failed" 4; }

deadline=$(( SECONDS + TIMEOUT_MIN * 60 )); last=""; last_change=$SECONDS; DONE=0
while (( SECONDS < deadline )); do
  sleep 10
  rm -f $OUT/spike-progress.json
  xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source Documents/spike-progress.json --destination $OUT/spike-progress.json > /dev/null 2>&1 || continue
  line=$(python3 -I -c "import json,sys; p=json.load(open(sys.argv[1])); print(f\"{p['elapsedS']:>4}s {p['phase']}: {p['line']}\" + (' DONE' if p.get('done') else ''))" $OUT/spike-progress.json 2>/dev/null)
  [[ -n $line && $line != $last ]] && { say "$line"; last=$line; last_change=$SECONDS; }
  [[ $line == *DONE ]] && { DONE=1; break; }
  if (( SECONDS - last_change > 300 )); then
    say "no progress for 5 minutes — checking the app is still running"
    xcrun devicectl device info processes --device $UDID --json-output $TMP/procs.json > /dev/null 2>&1
    grep -q "Spike2b.app" $TMP/procs.json 2>/dev/null || { say "the app is no longer running (jetsam or crash?) — collecting what it wrote"; break; }
    last_change=$SECONDS
  fi
done
(( DONE )) || say "WARNING: the battery did not finish (timeout ${TIMEOUT_MIN} min or the app stopped); keeping partial results"

for f in spike-results.json spike-progress.json; do
  xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source Documents/$f --destination $OUT/$f > /dev/null 2>&1 || say "could not copy $f back"
done
[[ -s $OUT/spike-results.json ]] || die "no results came back" 7
APP_MB=$(du -sm $APP | awk '{print $1}')
python3 -I -c "
import json,sys; r=json.load(open(sys.argv[1])); w=r.get('mlx',{}).get('weights',{}).get('bytesOnDisk',0)
print(f'  storage used on the phone while installed: app ~{sys.argv[2]} MB + weights {w/1e9:.2f} GB')" $OUT/spike-results.json $APP_MB
MAC=$B/results/mac/spike-results.json
python3 -I $SPIKE/grade.py --phone $OUT/spike-results.json $( [[ -s $MAC ]] && echo --mac $MAC ) --out $OUT/answers.md > /dev/null && say "answers: $OUT/answers.md"
say "results: $OUT"
exit 0
