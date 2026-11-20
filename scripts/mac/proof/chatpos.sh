#!/bin/zsh
# sweep-1 · 1.2 — does the question move after it shows? Asks each question inside the open chat (real click, keys,
# Return) and logs the screen y of its bubble (and of the previous question's) for ~6 s: "t:new/prev".
#   chatpos.sh <pid> <out> <question…>      PASS per question = shown by the first sample and one y throughout
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; shift 2; mkdir -p $O
AC=$ROOT/build/runs/s1-proof/axcount; AT=$ROOT/build/runs/s1-proof/axtext
y() { $AC $P "$1" 980 -5000 5000 v | awk '/AXStaticText/ {gsub(/[(),]/," "); print $3; exit}'; }
prev=""
for Q in "$@"; do
  for w in $(seq 1 90); do $R has $P 'Stop answer' | grep -q yes || break; sleep 1; done; sleep 1
  f=($($AT $P | grep ' · macLibrarianColumn · ' | head -1 | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'))
  $R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; sleep 0.3; $R type $P "$Q" >/dev/null; sleep 0.5
  t0=$(python3 -c 'import time;print(time.time())'); $R key $P 36 >/dev/null; line=""; ys=()
  for k in $(seq 1 30); do
    a=$(y "$Q"); b=$([[ -n $prev ]] && y "$prev"); t=$(python3 -c "import time;print(int((time.time()-$t0)*1000))")
    line="$line $t:${a:-none}/${b:--}"; ys+=(${a:-none})
  done
  u=$(print -l $ys | sort -u | wc -l | tr -d ' ')
  ok=$([[ ${ys[1]} != none && $u == 1 ]] && echo PASS || echo FAIL)
  print -r -- "'$Q' → $ok (distinct y: $(print -l $ys | sort -u | tr '\n' ' '))·$line" | tee -a $O/chatpos.txt
  prev=$Q
done
