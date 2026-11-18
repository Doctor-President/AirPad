#!/bin/zsh
# E fix-up 6 · M2 — one video session across inline / full screen / PiP. REAL clicks on an open video entry (the
# 5-min test clip burns its timecode into the frame, top-left). After each step: a still, the PiP window (if any),
# whether AirPad is playing audio (CoreMedia's playback assertion, pmset).
#   m2-video.sh <pid> <out> [flow]      AirPad at 0,60 1100×840, Librarian hidden, the video entry open
#   flow viewer (default): play inline 6 s → viewer → play → PiP on → close the viewer (×) → PiP's × → close viewer
#   flow inline:  play inline → PiP from the inline player → Back (leave the entry) → PiP's ×
#   flow return:  play inline → viewer → play → PiP on → close the player (×) → PiP's "return" → close viewer
set -u
B=${0:A:h:h:h:h}/build/mac-e/fixup6; RC=${0:A:h:h:h:h}/build/mac-e/fixup4/rclick; X=$B/rraw
P=${1:?pid}; OUT=${2:?out}; FLOW=${3:-viewer}; mkdir -p $OUT
INLINE_PLAY=(${=INLINE_PLAY:-397 754}); INLINE_PIP=(${=INLINE_PIP:-407 580}); FS_PIP=(${=FS_PIP:-80 137})
mv0() { swift -e "import CoreGraphics; CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:$1,y:$2),mouseButton:.left)?.post(tap:.cghidEventTap)"; }
audio() { pmset -g assertions | grep -q "pid $P(AirPad).*CoreMedia" && echo PLAYING || echo silent; }
pip() { swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]; for w in l where (w["kCGWindowOwnerName"] as? String) == "Picture in Picture" { let b = w["kCGWindowBounds"] as! [String:Double]; print("pip", Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)) }' | head -1; }
n=0
shot() { n=$((n+1)); screencapture -x $OUT/$(printf %02d $n)-$1.png; local p=$(pip); echo "$n $1 · audio $(audio) · ${p:-no pip}" | tee -a $OUT/steps.txt; }
pipclick() {   # pipclick close|return|play — hover the PiP window, then its control (PiP is PIPAgent's window: raw click)
  local p=($(pip)); [[ ${#p} != 5 ]] && { echo "no pip window" | tee -a $OUT/steps.txt; return }
  local x=$p[2] y=$p[3] w=$p[4] h=$p[5]; mv0 $((x+w/2)) $((y+h/2)); sleep 0.4; mv0 $((x+w/2+6)) $((y+h/2+4)); sleep 0.4
  case $1 in close) $X $((x+50*w/790)) $((y+28*h/425));; return) $X $((x+743*w/790)) $((y+28*h/425));; play) $X $((x+w/2)) $((y+213*h/425));; esac > /dev/null
}
playinline() { mv0 600 650; sleep 0.4; $RC clickat $P $INLINE_PLAY > /dev/null; sleep 6; mv0 600 300; shot inline-playing-6s; }
fullscreen() { $RC click $P "Open fullscreen" > /dev/null; sleep 2.5; shot viewer-open; $RC click $P play.fill > /dev/null; sleep 2.5; shot fullscreen-playing
  mv0 300 300; sleep 0.3; mv0 310 310; sleep 0.3; $RC clickat $P $FS_PIP > /dev/null; sleep 3; shot pip-on; }
closeplayer() { $RC winsize $P 900 840 > /dev/null; sleep 1; $RC click $P sheetClose > /dev/null; sleep 2.5; shot player-closed; }
closeviewer() { $RC click $P xmark > /dev/null; sleep 2; $RC winsize $P 1100 840 > /dev/null; sleep 1.5; mv0 600 650; sleep 0.6; shot entry; }
case $FLOW in
viewer) playinline; fullscreen; closeplayer; pipclick close; sleep 3; shot pip-closed; sleep 8; shot pip-closed-11s; closeviewer;;
return) playinline; fullscreen; closeplayer; pipclick return; sleep 3; shot pip-returned; sleep 5; shot pip-returned-8s; closeviewer;;
stayclose|stayreturn)   # PiP from the inline player, the entry stays on screen, then PiP's × / "return"
        playinline; mv0 600 650; sleep 0.4; $RC clickat $P $INLINE_PIP > /dev/null; sleep 3; shot inline-pip-on
        pipclick ${FLOW#stay}; sleep 3; shot pip-${FLOW#stay}; sleep 5; shot pip-${FLOW#stay}-8s;;
inline) playinline; mv0 600 650; sleep 0.4; $RC clickat $P $INLINE_PIP > /dev/null; sleep 3; shot inline-pip-on
        $RC click $P toolbar.back > /dev/null; sleep 2.5; shot left-entry; pipclick close; sleep 3; shot pip-closed; sleep 8; shot pip-closed-11s;;
esac
