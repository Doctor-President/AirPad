#!/bin/zsh
# sweep-1 · 1.2 chat check — T saw a question "disappear for a while" after asking. Real click into the Ask field, real
# typing, real Return; then the transcript is read through Accessibility every ~0.1–0.3 s for SECS seconds: is the
# question on screen? A sample without it after it first showed = it disappeared. Stills at ~0.5 s and ~3 s.
#   chatcheck.sh <pid> <out> <label> [n=10] [secs=25]      (the recorder runs in the app; save it after the run)
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; L=${3:?label}; N=${4:-10}; SECS=${5:-25}; mkdir -p $O
AT=$ROOT/build/runs/s1-proof/axtext
QS=("What is photosynthesis?" "Who painted the Mona Lisa?" "How tall is Mount Everest?" "What is the speed of light?"
    "Who was Ada Lovelace?" "How many moons does Mars have?" "What is the capital of Australia?" "When did the Berlin Wall fall?"
    "Who wrote Pride and Prejudice?" "What is a black hole?")
ask() { $AT $P | grep ' · macLibrarianColumn · '; }
askxy() { ask | head -1 | sed -E 's/.*\(([0-9]+),([0-9]+) ([0-9]+)×([0-9]+)\).*/\1 \2 \3 \4/'; }
clickask() { local f=($(askxy)); $R clickat $P $((f[1] + f[3] / 2)) $((f[2] + f[4] / 2)) >/dev/null; }
now() { python3 -c 'import time;print(int(time.time()*1000))'; }
for i in $(seq 1 $N); do
  Q=${QS[$(( (i - 1) % ${#QS} + 1 ))]}
  $R has $P macLibrarianBack | grep -q yes && { $R click $P macLibrarianBack >/dev/null; sleep 1.2; }
  $R has $P macLibrarianNewChat | grep -q yes && { $R click $P macLibrarianNewChat >/dev/null; sleep 1; }
  clickask; sleep 0.3; $R type $P "$Q" >/dev/null; sleep 0.5
  F=$O/$L-$i.tsv; : > $F
  t0=$(now); $R key $P 36 >/dev/null
  s1=0; s2=0
  while :; do
    t=$(( $(now) - t0 )); (( t > SECS * 1000 )) && break
    c=$($AT $P | grep -v macLibrarianColumn | grep -c -F -- "$Q")
    print "$t\t$c" >> $F
    (( s1 == 0 && t > 400 )) && { cap $P $O/$L-$i-0s5.png; s1=1; }
    (( s2 == 0 && t > 3000 )) && { cap $P $O/$L-$i-3s.png; s2=1; }
  done
  python3 - $F "$Q" "$L $i" <<'EOF' | tee -a $O/results.txt
import sys
rows=[tuple(map(int,l.split('\t'))) for l in open(sys.argv[1]) if l.strip()]
first=next((t for t,c in rows if c>0),None)
# missing = fewer copies of the question on screen than already seen (the bubble, and later a chat title, carry it)
gone=[]; gap=0; run=0; prev=None; top=0; changes=[]
for t,c in rows:
    if c < top: gone.append(t); run += (t-prev) if prev is not None else 0
    else: gap=max(gap,run); run=0
    if not changes or changes[-1][1]!=c: changes.append((t,c))
    top=max(top,c); prev=t
gap=max(gap,run)
ok = first is not None and first < 1500 and not gone
steps=" ".join(f"{t}:{c}" for t,c in changes[:12])
print(f"{sys.argv[3]}: samples={len(rows)} first-shown={first} ms · missing-after={len(gone)} (longest {gap} ms) · count t:n {steps} · '{sys.argv[2]}' -> {'PASS' if ok else 'FAIL'}")
EOF
  sleep 3
done
print -r -- "$L: PASS $(grep -c "^$L .*PASS" $O/results.txt)/$N" | tee -a $O/results.txt
