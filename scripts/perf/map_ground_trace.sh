#!/bin/zsh
# 1.1-A (6) — Map ground GPU cost on T's iPhone (Metal System Trace). STAGED: CC does not run this; T / the parent session does.
# Before: scripts/perf/map_ground_build.sh (both apps). T: plug in, unlock, Auto-Lock Never, phone flat on a table, hands off.
# Expected duration ≈ 17 min at REST=45 (8 traced cases on A + 2 traced on B + 2 rest cases + 2 installs + 1 seed launch).
# Replaces the TestFlight app (T's prefs are backed up + restored; the run uses the isolated -UITestLibrary scratch with the
# Sample Library, never T's Library). Afterwards T reinstalls the TestFlight build from TestFlight.
#   scripts/perf/map_ground_trace.sh                 (REST=45 default; KEEP=1 keeps the ≈2 GB .trace files)
set -u
D=${D:-00008150-001E58283A8B401C}; APPID=com.doctorpresident.airpad; REST=${REST:-45}
WT=${0:A:h:h:h}; P=${0:A:h}; E=${E:-$WT/build/map-ground-$(date +%Y%m%d-%H%M)}; mkdir -p $E
typeset -A APP; APP[a]=$WT/build/mg-a-dd/Build/Products/Release-iphoneos/AirPad.app; APP[b]=$WT/build/mg-b-dd/Build/Products/Release-iphoneos/AirPad.app
for k in a b; do [[ -d $APP[$k] ]] || { echo "missing $APP[$k] — run scripts/perf/map_ground_build.sh"; exit 1; }; done
FREE=$(df -g ~ | awk 'NR==2{print $4}'); (( FREE >= 30 )) || { echo "only ${FREE} GB free — need ≥ 30 (each 45 s trace ≈ 2 GB until exported)"; exit 1; }
PREFS=Library/Preferences/$APPID.plist
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -MapLookSet flat -appearance.override dark -MapHeatLog YES)
export DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=YES
terminate() { xcrun devicectl device process terminate --device $D --pid $(xcrun devicectl device info processes --device $D 2>/dev/null | awk '/AirPad.app\/AirPad/{print $1; exit}') >/dev/null 2>&1; }
# case <name> <secs> <trace 1|0> [app args…] — one launch; the Map drifts (-MapAutoPan = the panning state, full frame rate)
run_case() {
  local NAME=$1 SECS=$2 TR=$3; shift 3
  xcrun devicectl device info lockState --device $D >/dev/null 2>&1; sleep 3
  for try in 1 2; do
    xcrun devicectl device process launch --device $D --terminate-existing --console $APPID -- $BASE "$@" > $E/$NAME.console 2>&1 &
    LP=$!; sleep 16
    grep -q "\[MapHeat\]" $E/$NAME.console && break
    kill $LP 2>/dev/null; sleep 4
  done
  if (( TR )); then
    xcrun xctrace record --device $D --template "Metal System Trace" --attach AirPad --time-limit ${SECS}s --output $E/$NAME.trace > $E/$NAME.xctrace.log 2>&1
    xcrun xctrace export --input $E/$NAME.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' --output $E/$NAME.gpu.xml >/dev/null 2>&1
    python3 $P/gpuparse.py $E/$NAME.gpu.xml > $E/$NAME.gpu.txt 2>&1
    [[ ${KEEP:-0} == 1 ]] || rm -rf $E/$NAME.trace $E/$NAME.gpu.xml
  else
    sleep $SECS
  fi
  kill $LP 2>/dev/null; sleep 1; terminate
  printf "%-22s [MapHeat] lines %s\n" $NAME $(grep -c "\[MapHeat\]" $E/$NAME.console)
}
# ── A: today's Info.plist (60 Hz cap) ──
xcrun devicectl device install app --device $D $APP[a] || exit 1
xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $APPID --source $PREFS --destination $E/prefs-backup.plist || exit 1
run_case seed 25 0 -UITestLibraryFresh            # seeds the Sample into the scratch + settles its layout (not measured)
for C in all wellsOff rippleOff wellsRippleOff dotsOff gridOff titlesOff orbsOff; do
  run_case a-$C $REST 1 -MapAutoPan -MapGroundCase $C
done
run_case a-rest $REST 0                           # no drift: the idle rate (8 fps) + CPU at rest
# ── B: CADisableMinimumFrameDurationOnPhone = YES (120 Hz) ──
xcrun devicectl device install app --device $D $APP[b] || exit 1
for C in all wellsOff; do run_case b-$C $REST 1 -MapAutoPan -MapGroundCase $C; done
run_case b-rest $REST 0
# ── restore T's prefs ──
xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $APPID --source $PREFS --destination $E/prefs-after.plist
if ! cmp -s $E/prefs-backup.plist $E/prefs-after.plist; then
  echo "prefs changed — restoring backup"
  xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $APPID --source $E/prefs-backup.plist --destination $PREFS
fi
python3 $P/map_ground_summarize.py $E | tee $E/summary.txt
echo "Done ($E). T: reinstall the TestFlight build from TestFlight."
