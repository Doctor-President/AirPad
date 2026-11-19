#!/bin/zsh
# sweep-1 proof 2 · N4 — a document item's actions, real clicks/keys: ··· menu (Quick Look / Open a Copy with <App> /
# Reveal in Finder / Share / Copy filename), right-click menu on the preview, and the hovered-preview keys (Space,
# ⌘O, ⌘⇧R). Checks: Quick Look = an app window "Quick Look" (Esc closes it); Open a Copy = Preview opens a document
# named after the item (then Preview is quit — it was not running before); Reveal = Finder frontmost with the stored file
# selected (the reveal window is closed after).   n4.sh <pid> <out> <document item id> [n=2]
D=${0:A:h}; source $D/lib.sh; P=${1:?pid}; O=${2:?out}; ID=${3:?id}; N=${4:-2}; mkdir -p $O; : > $O/results.txt
CS=$ROOT/build/runs/s1-proof2/cskey; RR=$ROOT/build/runs/s1-proof/rright
log() { print -r -- "$*" | tee -a $O/results.txt; }
wins() { osascript -e "tell application \"System Events\" to get name of every window of (first process whose unix id is $P)" 2>/dev/null; }
front() { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null; }
qlcheck() {   # <label>
  sleep 2.5; local w=$(wins); local open=$([[ $w == *"Quick Look"* ]] && echo yes || echo no)
  [[ -n $2 ]] && screencapture -x $O/$2.png
  $R key $P 53 >/dev/null; sleep 1.5; local w2=$(wins); local closed=$([[ $w2 != *"Quick Look"* ]] && echo yes || echo no)
  log "$1: windows=[$w] ql-open=$open · Esc → windows=[$w2] closed=$closed → $([[ $open == yes && $closed == yes ]] && echo PASS || echo FAIL)"
}
opencheck() {   # <label>
  local t=0 w=""; while (( t < 10 )); do w=$(osascript -e 'tell application "System Events" to get name of every window of process "Preview"' 2>/dev/null); [[ -n $w ]] && break; sleep 1; t=$((t + 1)); done
  local fr=$(front); local dp=$(osascript -e 'tell application "Preview" to get path of front document' 2>/dev/null)
  [[ -n $2 ]] && screencapture -x $O/$2.png
  log "$1: Preview windows=[$w] front=[$fr] doc path=[$dp] → $([[ $w == *"Sweep Test Brochure"* ]] && echo PASS || echo FAIL)"
  osascript -e 'tell application "Preview" to quit' >/dev/null 2>&1; sleep 1.5; $PF $P >/dev/null; sleep 0.8
}
revealcheck() {   # <label>
  sleep 2.5; local fr=$(front); local sel=$(osascript -e 'tell application "Finder" to get POSIX path of (item 1 of (get selection) as alias)' 2>/dev/null)
  local fw=$(osascript -e 'tell application "Finder" to get name of front window' 2>/dev/null)
  [[ -n $2 ]] && screencapture -x $O/$2.png
  log "$1: front=[$fr] Finder front window=[$fw] selection=[$sel] → $([[ $fr == Finder && $sel == *"$ID"* ]] && echo PASS || echo FAIL)"
  [[ -n $fw && $fw != dropfiles ]] && osascript -e "tell application \"Finder\" to close window \"$fw\"" >/dev/null 2>&1
  sleep 1; $PF $P >/dev/null; sleep 0.8
}
menu() { $PF $P >/dev/null; sleep 0.5; $R click $P documentMenu-$ID >/dev/null; sleep 1; }
pv=($($R find $P documentOpen-$ID | sed -E 's/\(([0-9-]+),([0-9-]+) ([0-9]+)×([0-9]+)\)/\1 \2 \3 \4/')); PX=$((pv[1] + pv[3] / 4)); PY=$((pv[2] + pv[4] / 2))
log "preview frame ${pv[*]} · pointer for hover/right-click ($PX,$PY)"
for i in $(seq 1 $N); do
  menu; titles=""; for m in quick_look open_a_copy_with_preview reveal_in_finder share copy_filename; do titles+="[$($R get $P $m AXTitle 2>/dev/null)]"; done
  [[ $i == 1 ]] && screencapture -x -R560,600,700,300 $O/menu.png
  log "t$i menu items: $titles → $([[ $titles == '[Quick Look][Open a Copy with Preview][Reveal in Finder][Share][Copy filename]' ]] && echo PASS || echo FAIL)"
  $R click $P quick_look >/dev/null; qlcheck "t$i menu Quick Look" $([[ $i == 1 ]] && echo ql-menu)
  menu; $R click $P open_a_copy_with_preview >/dev/null; opencheck "t$i menu Open a Copy" $([[ $i == 1 ]] && echo open-menu)
  menu; $R click $P reveal_in_finder >/dev/null; revealcheck "t$i menu Reveal" $([[ $i == 1 ]] && echo reveal-menu)
  $PF $P >/dev/null; sleep 0.5; $RR $PX $PY >/dev/null; sleep 1.2
  rt=""; for m in "Quick Look" "Open a Copy with Preview" "Reveal in Finder"; do rt+="[$($R get $P "$m" AXTitle 2>/dev/null)]"; done   # the context menu's items carry their titles as ids
  [[ $i == 1 ]] && screencapture -x -R$((PX - 20)),$((PY - 20)),420,300 $O/rightclick.png
  log "t$i right-click items: $rt → $([[ $rt == '[Quick Look][Open a Copy with Preview][Reveal in Finder]' ]] && echo PASS || echo FAIL)"
  $R key $P 53 >/dev/null; sleep 0.8
  $PF $P >/dev/null; sleep 0.4
  $ROOT/build/kit/rclick hover $P documentOpen-$ID >/dev/null; sleep 0.6
  $R key $P 49 >/dev/null; qlcheck "t$i hover Space" $([[ $i == 1 ]] && echo ql-space)
  $R hover $P documentOpen-$ID >/dev/null; sleep 0.6; $R cmdkey $P 31 >/dev/null; opencheck "t$i hover ⌘O" $([[ $i == 1 ]] && echo open-cmdo)
  $R hover $P documentOpen-$ID >/dev/null; sleep 0.6; $CS 15 >/dev/null; revealcheck "t$i hover ⌘⇧R" $([[ $i == 1 ]] && echo reveal-cmdshiftr)
  log "  mods after t$i: $($ROOT/build/kit/mods)"
done
for k in "menu items" "menu Quick Look" "menu Open a Copy" "menu Reveal" "right-click" "hover Space" "hover ⌘O" "hover ⌘⇧R"; do
  log "$k: $(grep -c "^t[0-9] $k.*PASS$" $O/results.txt)/$N"; done
