#!/bin/zsh
# 1.1 store — a clean store simulator: the bench app, the Sample Library seeded into its scratch, the two synthetic
# entries, Face ID enrolled, a Files folder. Usage: setup_sim.sh <sim>
set -u
SIM=$1; HERE=${0:A:h}; source $HERE/lib.sh
prep
xcrun simctl uninstall $SIM $BID 2>/dev/null; xcrun simctl install $SIM $APP
launch -OpenMap; sleep 30; xcrun simctl terminate $SIM $BID
C=$(xcrun simctl get_app_container $SIM $BID data)/Library/Caches/AirPadBenchScratch
ls $C/nodes | wc -l
python3 $HERE/seed_entry.py $C $HERE/assets/pourover-2400.jpg $HERE/assets/drip-2400.jpg
xcrun simctl spawn $SIM notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn $SIM notifyutil -p com.apple.BiometricKit.enrollmentChanged
xcrun simctl launch $SIM com.apple.DocumentsApp >/dev/null; sleep 6; xcrun simctl terminate $SIM com.apple.DocumentsApp
D=$(find ~/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Shared/AppGroup -maxdepth 2 -name "File Provider Storage" -type d | head -1)
mkdir -p "$D/AirPad notes"; echo "files: $D"
launch -OpenMap; sleep 20; snap $HERE/t/setup-$SIM.png; xcrun simctl terminate $SIM $BID
