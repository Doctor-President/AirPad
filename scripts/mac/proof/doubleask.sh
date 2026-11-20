#!/bin/zsh
# sweep-1 review fix — a second Return while the first question still reads the library: the first question's bubble
# stays (its own text), the second isn't sent (it stays in the field), and nothing is lost.  doubleask.sh <pid> <out> <trial>
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; T=${3:-1}; mkdir -p $O
AC=$ROOT/build/runs/s1-proof/axcount; AT=$ROOT/build/runs/s1-proof/axtext
tag() { python3 -c "import random;print(''.join(random.choice('bcdfghjklmnpqrstvwxz') for _ in range(5)))"; }
Q1="what is a reef $(tag)"; Q2="what is a dune $(tag)"
for w in $(seq 1 90); do $R has $P 'Stop answer' | grep -q yes || break; sleep 1; done; sleep 1
f=($($AT $P | grep ' · macLibrarianColumn · ' | head -1 | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'))
$R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; sleep 0.3
$R cmdkey $P 0 >/dev/null; $R key $P 51 >/dev/null; sleep 0.3          # ⌘A, Delete: an empty field
# a pause before each Return: a Return straight after typing can go to the spelling panel (marked text passes, N15)
$R type $P "$Q1" >/dev/null; sleep 0.7; $R key $P 36 >/dev/null; sleep 0.2
$R type $P "$Q2" >/dev/null; sleep 0.7; $R key $P 36 >/dev/null     # ~1.5 s after the first Return: Q1 still reads
line=""; for k in $(seq 1 30); do
  a=($($AC $P "$Q1" 980 175 795)); b=($($AC $P "$Q2" 980 175 795)); line="$line ${a[2]}/${b[2]}"; done
field=$($AT $P | grep ' · macLibrarianColumn · ' | head -1 | sed -E 's/.*val=\[([^]]*)\].*/\1/')
cap $P $O/doubleask-$T.png
q1gone=$(print -- $line | tr ' ' '\n' | grep -c '^0/'); q2shown=$(print -- $line | tr ' ' '\n' | grep -vc '/0$')
ok=$([[ $q1gone == 0 && $q2shown == 0 && $field == *dune* ]] && echo PASS || echo FAIL)
print -r -- "$T: Q1 missing in $q1gone/30 samples · Q2 shown in $q2shown/30 · field after=[$field] → $ok ·$line" | tee -a $O/doubleask.txt
