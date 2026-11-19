#!/bin/zsh
# exit 0 when the screen is unlocked and this shell may post events (real clicks); prints the state
source ${0:A:h}/env.sh; [[ -x $KIT/locked ]] || zsh ${0:A:h}/tools.sh >/dev/null
s=$($KIT/locked); echo $s; [[ $s == "locked 0 ax 1 post 1" ]]
