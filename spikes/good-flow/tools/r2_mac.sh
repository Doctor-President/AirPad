#!/bin/zsh
# Good Flow spike · round 2: one scripted Mac launch (works with the screen LOCKED: no events posted).
#   tools/r2_mac.sh <name> <seconds> [app args…]   e.g. tools/r2_mac.sh cards-light 20 -Case Cards -Script "dump:a@8,quit@19"
# Sizes the window to WIN (default "1728 1028") with rclick, waits until the app quits (or <seconds> + 20), then copies
# the app's Documents/r2 (dumps, snaps) and any recordings named r2-* to build/r2/<name>/.
set -u
SPIKE=${0:A:h:h}; RC=${SPIKE:h:h}/scripts/mac/realclick; T=$SPIKE/build/tools; mkdir -p $T
APP=$SPIKE/build/dd/Build/Products/Release-maccatalyst/GoodFlow.app
C=~/Library/Containers/com.doctorpresident.spike.SpikeHarness/Data/Documents
[[ $T/rclick -nt $RC/rclick.swift ]] || swiftc -O -o $T/rclick $RC/rclick.swift 2>/dev/null
N=${1:?name}; S=${2:?seconds}; shift 2
free=$(df -g / | awk 'NR==2 {print $4}'); (( free < 15 )) && { echo "DISK $free GB < 15: not running"; exit 5 }
for p in $(pgrep -x GoodFlow); do kill $p; done; sleep 1
rm -rf $C/r2; rm -f $C/recordings/r2-*.json(N)
open -n -a $APP --args -ApplePersistenceIgnoreState YES "$@"
P=; for i in $(seq 1 20); do P=$(pgrep -nx GoodFlow); [[ -n $P ]] && break; sleep 0.5; done
[[ -z $P ]] && { echo "the app did not start"; exit 4 }
sleep 1.5; $T/rclick winmove $P 0 0 > /dev/null 2>&1; $T/rclick winsize $P ${=WIN:-1728 1028} > /dev/null 2>&1
caffeinate -i -w $P &
for i in $(seq 1 $(( (S + 20) * 2 ))); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
kill $P 2>/dev/null
O=$SPIKE/build/r2/$N; rm -rf $O; mkdir -p $O
cp -R $C/r2/. $O/ 2>/dev/null; cp $C/recordings/r2-*.json(N) $O/ 2>/dev/null
echo "$N: $(ls $O | tr '\n' ' ')"
