#!/bin/zsh
# 1.1 store — shot 1 (Map in a Pro look on a custom background: pairings) and shot 5 (the Map in each look, default
# backgrounds), Sample scratch library, clean status bar. Usage: shoot_map.sh <sim> <out> [seed]
set -u
SIM=$1; OUT=$2; HERE=${0:A:h}; source $HERE/lib.sh; mkdir -p $OUT
prep; xcrun simctl install $SIM $APP
if [[ ${3:-} == seed ]]; then
  launch -UITestLibraryFresh -OpenMap; sleep 25; xcrun simctl terminate $SIM $BID
  C=$(xcrun simctl get_app_container $SIM $BID data)/Library/Caches/AirPadUITestScratch
  python3 $HERE/seed_entry.py $C $HERE/assets/pourover-2400.jpg $HERE/assets/drip-2400.jpg
fi
W=${WAIT:-14}
map() { local name=$1 ap=$2 look=$3 g=${4:-}; xcrun simctl ui $SIM appearance $ap
  local a=(-OpenMap -mapLook.v1 $look); [[ -n $g ]] && a+=(-MapGroundDebug $g)
  launch $a; sleep $W; snap $OUT/$name.png; }
D0=$(side 111115); L0='{"custom":false,"color":"FFEEED","gradient":false,"color2":"FFF8EF","angle":90,"dot":"3B362F","dotOpacity":0.805}'
D0='{"custom":false,"color":"111115","gradient":false,"color2":"1D1D26","angle":90,"dot":"FFFFFF","dotOpacity":0.809}'
# shot 1 — pairings: <look> <appearance> <background name> <side json>
pairs=(
  "aura dark navy-violet $(side 0B1630 241046 60)"
  "aura dark deep-teal $(side 0E2A2E)"
  "aura light sand $(side F3E6D6)"
  "aura light sky-cream $(side E6EEF7 F6EFE6 90)"
  "glass dark ink-blue $(side 0C1424 1A2238 90)"
  "glass dark plum $(side 1C1420)"
  "riso light cream $(side F4EEDF)"
  "riso dark forest $(side 0F2018)"
  "gradient dark midnight $(side 0A0F1E 1B1030 120)"
  "outline light paper $(side F7F3EA)"
)
for p in $pairs; do set -- ${=p}; look=$1 ap=$2 bg=$3; shift 3; js="$*"
  if [[ $ap == dark ]]; then g=$(ground "$js" "$L0"); else g=$(ground "$D0" "$js"); fi
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  map 01-map-$nm-$ap-$bg $ap $look $g
done
# shot 5 — every look, default backgrounds
for ap in dark light; do for look in flat glass aura riso gradient outline; do
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  map 05-look-$nm-$ap $ap $look
done; done
xcrun simctl terminate $SIM $BID; xcrun simctl ui $SIM appearance light
ls $OUT/*.png | wc -l
