#!/bin/zsh
# sweep-1 N15 — Librarian Ask field: Return sends (field empties, a chat turn starts); ⇧Return makes a new line and sends
# nothing. Real clicks + keys (⇧ held as a real modifier by skey).   n15.sh <pid> <out> [n=3]
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; N=${3:-3}; mkdir -p $O; : > $O/results.txt
AT=$ROOT/build/runs/s1-proof/axtext
ask() { $AT $P | grep ' · macLibrarianColumn · '; }
askxy() { ask | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'; }
clickask() { local f=($(askxy)); $R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; }
for i in $(seq 1 $N); do
  $R has $P macLibrarianBack | grep -q yes && { $R click $P macLibrarianBack >/dev/null; sleep 1.2; }
  home=$($R has $P macLibrarianEmpty | cut -c1-3)
  clickask; $R type $P "test question" >/dev/null; before=$(ask | sed -E 's/.*val=\[([^]]*)\].*/\1/')
  $R key $P 36 >/dev/null; sleep 2
  after=$(ask | sed -E 's/.*val=\[([^]]*)\].*/\1/'); chat=$($R has $P macLibrarianEmpty | cut -c1-3); back=$($R has $P macLibrarianBack | cut -c1-3)
  ok=$([[ $home == yes && $before == "Test question" && -z $after && $chat == no && $back == yes ]] && echo PASS || echo FAIL)
  echo "send $i: home-before=$home typed=[$before] field-after=[$after] home-after=$chat chat-view(back)=$back → $ok" | tee -a $O/results.txt
  [[ $i == 1 ]] && cap $P $O/send-1.png
  sleep 20   # let the answer finish
  clickask; $R type $P "line one" >/dev/null; $SK 36 >/dev/null; sleep 0.4; $R type $P "line two" >/dev/null; sleep 0.8
  v=$(ask | sed -E 's/.*val=\[([^]]*)\].*/\1/'); m=$($ROOT/build/kit/mods)
  ok=$([[ $v == 'Line one\nLine two' && $m != *"cmd true"* ]] && echo PASS || echo FAIL)
  print -r -- "shift-return $i: field=[$v] mods=[$m] → $ok" | tee -a $O/results.txt
  [[ $i == 1 ]] && cap $P $O/multi-1.png
  $R cmdkey $P 0 >/dev/null; $R key $P 51 >/dev/null; sleep 0.4   # ⌘A, delete: empty the field
  echo "  cleared: [$(ask | sed -E 's/.*val=\[([^]]*)\].*/\1/')]" | tee -a $O/results.txt
done
print -r -- "send PASS $(grep -c "^send.*PASS" $O/results.txt)/$N · shift-return PASS $(grep -c "^shift.*PASS" $O/results.txt)/$N" | tee -a $O/results.txt
