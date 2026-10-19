#!/bin/zsh
# live-28 (2) — disk_hygiene.sh against a FIXTURE build/ tree in a scratch dir (never AirPad/build).
#   scripts/disk/test_disk_hygiene.sh   → one line per check, then "test_disk_hygiene: N/M PASS"
set -uo pipefail
HERE=${0:A:h}; S=$HERE/disk_hygiene.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/disk-hygiene-test.XXXX"); B=$T/build
PASS=0; TOTAL=0
check() { (( TOTAL++ )); if eval "$2"; then (( PASS++ )); echo "  PASS  $1"; else echo "  FAIL  $1"; fi }
dd() { mkdir -p "$B/$1/Build/Intermediates.noindex" "$B/$1/Build/Products" "$B/$1/Index.noindex" "$B/$1/ModuleCache.noindex"
       print x > "$B/$1/info.plist"; touch -t $2 "$B/$1/Build" "$B/$1"; }
# derived-data roots, oldest → newest
dd arc-a 202610010000; dd arc-b 202610050000; dd arc-c 202610100000; dd arc-d 202610150000; dd arc-e 202610180000
# an arc folder with derived data AND outputs (stills, a result bundle): only the derived data goes
dd arc-mixed 202610020000; mkdir -p "$B/arc-mixed/stills" "$B/arc-mixed/run.xcresult"; print s > "$B/arc-mixed/stills/a.jpg"
# derived data nested in an arc folder of outputs
mkdir -p "$B/arc-out/notes"; print n > "$B/arc-out/notes/x.md"; dd arc-out/dd-before 202610030000
# needed by the current branch (the gauntlet's build) — old, but kept
dd gauntlet-dd 202609010000
# never: run outputs, even with a Build/ inside
mkdir -p "$B/gauntlet-runs/live27/Build/Intermediates.noindex" "$B/inventory-runs/x" "$B/renders/live25"; touch -t 202601010000 "$B/gauntlet-runs/live27/Build"
# stray root build products (no derived-data path), old
mkdir -p "$B/Debug-iphonesimulator/AirPad.app" "$B/XCBuildData"; touch -t 202605010000 "$B/Debug-iphonesimulator" "$B/XCBuildData"
# an old copied app
mkdir -p "$B/gauntlet-app-ci0/AirPad.app"; touch -t 202610050000 "$B/gauntlet-app-ci0"
# a file outside build/ that must never be touched
print keep > $T/outside.txt

# dry run changes nothing
DISK_HYGIENE_ROOT=$B DISK_HYGIENE_KEEP="gauntlet-dd" $S --dry-run > $T/dry.log 2>&1
check "dry run deletes nothing" "[[ -d $B/arc-a/Build && -d $B/arc-b/Build ]]"
check "dry run names what it would delete" "/usr/bin/grep -q 'arc-a' $T/dry.log"

DISK_HYGIENE_ROOT=$B DISK_HYGIENE_KEEP="gauntlet-dd" $S > $T/run.log 2>&1
check "the newest 2 derived-data folders stay (arc-e, arc-d)" "[[ -d $B/arc-e/Build && -d $B/arc-d/Build ]]"
check "older derived-data folders go (arc-a, arc-b, arc-c)" "[[ ! -e $B/arc-a && ! -e $B/arc-b && ! -e $B/arc-c ]]"
check "a mixed arc folder keeps its outputs, loses its derived data" "[[ -f $B/arc-mixed/stills/a.jpg && -d $B/arc-mixed/run.xcresult && ! -e $B/arc-mixed/Build && ! -e $B/arc-mixed/Index.noindex ]]"
check "nested derived data goes, the arc's notes stay" "[[ ! -e $B/arc-out/dd-before && -f $B/arc-out/notes/x.md ]]"
check "what the current branch needs stays (gauntlet-dd)" "[[ -d $B/gauntlet-dd/Build ]]"
check "gauntlet-runs is never touched (even its Build/)" "[[ -d $B/gauntlet-runs/live27/Build/Intermediates.noindex ]]"
check "inventory-runs and renders are never touched" "[[ -d $B/inventory-runs/x && -d $B/renders/live25 ]]"
check "stale root build products go" "[[ ! -e $B/Debug-iphonesimulator && ! -e $B/XCBuildData ]]"
check "an old copied app goes" "[[ ! -e $B/gauntlet-app-ci0 ]]"
check "nothing outside build/ is touched" "[[ -f $T/outside.txt ]]"
check "it reports free before → after" "/usr/bin/grep -qE 'free [0-9.]+ GB → [0-9.]+ GB' $T/run.log"
check "a root that isn't an AirPad build/ is refused" "! DISK_HYGIENE_ROOT=$T $S >/dev/null 2>&1 && [[ -f $T/outside.txt ]]"
DISK_HYGIENE_ROOT=$B $S --check 1 > $T/c1.log 2>&1; c1=$?
DISK_HYGIENE_ROOT=$B $S --check 100000 > $T/c2.log 2>&1; c2=$?
check "--check passes above the floor" "(( c1 == 0 ))"
check "--check stops below the floor (exit 3) and says so" "(( c2 == 3 )) && /usr/bin/grep -q 'under 100000 GB' $T/c2.log"
rm -rf $T
echo "test_disk_hygiene: $PASS/$TOTAL PASS"
(( PASS == TOTAL ))
