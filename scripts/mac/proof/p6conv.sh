#!/bin/zsh
# proof 6 · 5 conventions. p6conv.sh <pid> <out> m1|m2|m6
#  m1: ⌘, → Settings (its list: Privacy …); ⌘W → Settings gone, the main window and the app still there (3 trials)
#  m2: Library › Cards: ⌘= ×4, ⌘− ×4, ⌘0 — cards per row (first-row cardTile-* frames) + card width + slider after each
#  m6: the Edit menu's items named Find*
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; W=$3; mkdir -p $O
log() { print -r -- "$*" | tee -a $O/results.txt; }
wins() { osascript -e "tell application \"System Events\" to get name of every window of (first process whose unix id is $P)" 2>/dev/null; }
row() { local y0="" n=0 w=""; for i in $(seq 0 12); do f=$($R find $P 'cardTile-*' $i 2>/dev/null) || break
    y=$(echo $f | sed -E 's/\(([-0-9]+),([-0-9]+) ([0-9]+)×.*/\2/'); [[ -z $y0 ]] && { y0=$y; w=$(echo $f | sed -E 's/.* ([0-9]+)×.*/\1/'); }
    [[ $y == $y0 ]] && n=$((n + 1)); done; echo "perRow=$n cardW=$w slider=$($R get $P cardsSizeSlider AXValue)"; }
$PF $P >/dev/null; sleep 0.4
case $W in
m1) st() { echo "settings=$($R has $P Settings | cut -c1-3) privacy=$($R has $P Privacy | cut -c1-3) wins=[$(wins)]"; }   # Settings opens in the window's right column
    for t in 1 2 3; do s0=$(st); $R cmdkey $P 43 >/dev/null; sleep 2; s1=$(st); [[ $t == 1 ]] && cap $P $O/m1-settings.png
      $R cmdkey $P 13 >/dev/null; sleep 1.5; s2=$(st); alive=$(kill -0 $P 2>/dev/null && echo yes || echo no); [[ $t == 1 ]] && cap $P $O/m1-after-cmdw.png
      log "M1 t$t: before [$s0] · ⌘, → [$s1] · ⌘W → [$s2] app alive=$alive → $([[ $s1 == *"privacy=yes"* && $s2 == *"privacy=no"* && $s2 == *"AirPad Mac-A"* && $alive == yes ]] && echo PASS || echo FAIL)"; done ;;
m2) $R menu $P View Cards >/dev/null; sleep 2; prev=$(row); log "M2 start: $prev"; ch=0; n=0
    for k in 24 24 24 24 27 27 27 27 27 27 29; do $R cmdkey $P $k >/dev/null; sleep 1.5; cur=$(row); n=$((n + 1))
      c=$([[ ${cur%% slider*} != ${prev%% slider*} ]] && echo changed || echo same); [[ $c == changed ]] && ch=$((ch + 1))
      log "M2 press $n (⌘ key $k): $cur → $c"; prev=$cur; [[ $n == 4 ]] && cap $P $O/m2-zoomin.png; done
    log "M2: $ch of $n presses changed the grid" ;;
m6) items=$(osascript -e "tell application \"System Events\" to get name of every menu item of menu 1 of menu bar item \"Edit\" of menu bar 1 of (first process whose unix id is $P)" 2>/dev/null)
    log "M6 Edit menu: [$items] · items starting 'Find': $(echo $items | tr ',' '\n' | grep -c '^ *Find')" ;;
esac
