#!/bin/zsh
# proof 6 · 2 (5e2ba97b) — a LEGACY-shaped document item (type document, `file` set, document_items empty) with real
# events: hover + Space → Quick Look (Esc closes) · ··· › Open a Copy with Preview (Preview opens it, then quit) ·
# ··· › Reveal in Finder (Finder selects the stored file, window closed after) · ··· › Copy filename (pbpaste = name + ext).
#   p6legacy.sh <pid> <out> <item id> <stored-file id> <expected filename> [n=2]
D=${0:A:h}; source $D/lib.sh; P=$1; O=$2; ID=$3; FID=$4; FN=$5; N=${6:-2}; mkdir -p $O
log() { print -r -- "$*" | tee -a $O/results.txt; }
wins() { osascript -e "tell application \"System Events\" to get name of every window of (first process whose unix id is $P)" 2>/dev/null; }
front() { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null; }
menu() { $PF $P >/dev/null; sleep 0.5; $R click $P documentMenu-$ID >/dev/null; sleep 1; }
for i in $(seq 1 $N); do
  # Quick Look: hover + Space
  $PF $P >/dev/null; sleep 0.4; $R hover $P documentOpen-$ID >/dev/null; sleep 0.6; $R key $P 49 >/dev/null; sleep 2.5
  w=$(wins); [[ $i == 1 ]] && screencapture -x $O/ql.png && sips -Z 1350 $O/ql.png --out $O/ql-s.png >/dev/null
  $R key $P 53 >/dev/null; sleep 1.5; w2=$(wins)
  log "t$i hover Space Quick Look: windows=[$w] · Esc → [$w2] → $([[ $w == *"Quick Look"* && $w2 != *"Quick Look"* ]] && echo PASS || echo FAIL)"
  # Open a Copy
  pv=$(pgrep -x Preview); menu; items=""; for m in quick_look open_a_copy_with_preview reveal_in_finder share copy_filename; do items+="[$($R get $P $m AXTitle 2>/dev/null)]"; done
  [[ $i == 1 ]] && { screencapture -x -R560,180,700,300 $O/menu.png; }
  log "t$i menu items: $items"
  $R click $P open_a_copy_with_preview >/dev/null
  t=0 w=""; while (( t < 10 )); do w=$(osascript -e 'tell application "System Events" to get name of every window of process "Preview"' 2>/dev/null); [[ -n $w ]] && break; sleep 1; t=$((t + 1)); done
  dp=$(osascript -e 'tell application "Preview" to get path of front document' 2>/dev/null)
  [[ $i == 1 ]] && screencapture -x $O/open.png && sips -Z 1350 $O/open.png --out $O/open-s.png >/dev/null
  log "t$i Open a Copy: Preview windows=[$w] doc=[$dp] → $([[ $w == *"Sweep Test Brochure"* && $dp == *"Opened Copies"* ]] && echo PASS || echo FAIL)"
  [[ -z $pv ]] && osascript -e 'tell application "Preview" to quit' >/dev/null 2>&1; sleep 1.5
  # Reveal
  menu; $R click $P reveal_in_finder >/dev/null; sleep 2.5; fr=$(front)
  sel=$(osascript -e 'tell application "Finder" to get POSIX path of (item 1 of (get selection) as alias)' 2>/dev/null)
  fw=$(osascript -e 'tell application "Finder" to get name of front window' 2>/dev/null)
  [[ $i == 1 ]] && screencapture -x $O/reveal.png && sips -Z 1350 $O/reveal.png --out $O/reveal-s.png >/dev/null
  log "t$i Reveal: front=[$fr] window=[$fw] selection=[$sel] → $([[ $fr == Finder && $sel == *"$FID"* ]] && echo PASS || echo FAIL)"
  [[ $fw == items ]] && osascript -e 'tell application "Finder" to close window "items"' >/dev/null 2>&1; sleep 1
  # Copy filename
  print -n "sentinel-$i" | pbcopy; menu; $R click $P copy_filename >/dev/null; sleep 1; pb=$(pbpaste)
  log "t$i Copy filename: pasteboard=[$pb] → $([[ $pb == "$FN" ]] && echo PASS || echo FAIL)"
done
