#!/bin/zsh
# Good Flow spike · round 2: one launch in CC's own Simulator ("CC good-flow r2", its UDID in build/r2-sim-udid.txt), never a
# device. Create it first: xcrun simctl create "CC good-flow r2" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
# com.apple.CoreSimulator.SimRuntime.iOS-27-0 > build/r2-sim-udid.txt; boot; build -derivedDataPath build/dd-sim; install.
#   tools/r2_sim.sh <name> <seconds> [app args…]    copies Documents/r2 and Documents/recordings to build/r2/sim-<name>/
set -u
SPIKE=${0:A:h:h}; SIM=$(cat $SPIKE/build/r2-sim-udid.txt); B=com.doctorpresident.spike.SpikeHarness
N=${1:?name}; S=${2:?seconds}; shift 2
D=$(xcrun simctl get_app_container $SIM $B data)/Documents
rm -rf $D/r2 $D/recordings
xcrun simctl launch --terminate-running-process $SIM $B -ApplePersistenceIgnoreState YES "$@" > /dev/null
sleep $S
xcrun simctl terminate $SIM $B 2>/dev/null
O=$SPIKE/build/r2/sim-$N; rm -rf $O; mkdir -p $O; cp -R $D/r2/. $O/ 2>/dev/null; cp $D/recordings/*.json $O/ 2>/dev/null
echo "sim-$N: $(ls $O | tr '\n' ' ')"
