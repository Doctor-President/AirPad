# 1.1 store — the look / background pairings (shot 1) as "<look> <appearance> <name> <side json>"; source after lib.sh.
D0='{"custom":false,"color":"111115","gradient":false,"color2":"1D1D26","angle":90,"dot":"FFFFFF","dotOpacity":0.809}'
L0='{"custom":false,"color":"FFEEED","gradient":false,"color2":"FFF8EF","angle":90,"dot":"3B362F","dotOpacity":0.805}'
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
# pair_args "<pair>" → sets: look ap bg nm args (launch arguments as one string)
pair_args() { set -- ${=1}; look=$1 ap=$2 bg=$3; shift 3; local js="$*" g
  if [[ $ap == dark ]]; then g=$(ground "$js" "$L0"); else g=$(ground "$D0" "$js"); fi
  nm=$look; [[ $look == aura && $ap == light ]] && nm=wash
  args="-mapLook.v1 $look -MapGroundDebug $g"; }
