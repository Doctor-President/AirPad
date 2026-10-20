#!/bin/zsh
# live-29 (4) — the Sample Library entries that carry attributes (People ×12 now, Coffee ×5), their detail
# view, light, so their attribute layout can be judged for the App Store screenshots. Sample Library content only.
#   scripts/renders/shoot_live29_attributes.sh <out_dir>   (installs nothing: the app on the Simulator is what is shot)
set -uo pipefail
OUT=${1:?out}; SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APPID=com.doctorpresident.airpad
mkdir -p $OUT
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui $SIM appearance ${MODE:-light}
TITLES=("the guy on three" "The reading-room regular" "Sparrow — Huehuetenango" "Sid" "Passion House — Blue Collar" "Mom"
        "Metric — Ethiopia Guji" "Mara" "Linda" "Joaquin" "Intelligentsia — Black Cat" "Gary" "Dolores"
        "Dark Matter — Unicorn Blood" "Amélie from Tuesday class")
i=0
for t in $TITLES; do i=$((i+1))
  xcrun simctl launch --terminate-running-process $SIM $APPID -UITestLibrary -UITestLibraryFresh -UITestSampleLibrary \
    -EmbedCPUOnly -GlassFreezeTime 1 -OpenCardView -OpenEntryTitled "$t" >/dev/null
  python3 -c "import time; time.sleep(9)"
  xcrun simctl io $SIM screenshot --type=png "$OUT/$(printf %02d $i)-${t//[^A-Za-z0-9]/_}.png" >/dev/null 2>&1
done
xcrun simctl terminate $SIM $APPID; xcrun simctl status_bar $SIM clear
ls $OUT/*.png | wc -l
