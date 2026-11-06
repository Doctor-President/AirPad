#!/bin/zsh
# restcpu.sh <app> <label> <settle_s> <window_s> <args…> — launch, settle, then CPU% = Δ(cpu time) / Δ(wall) over the window,
# plus RSS. Isolated copy only.
APP=$1; LBL=$2; SET=$3; WIN=$4; shift 4
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES "$@" > /dev/null 2>&1 & P=$!
sleep $SET
t() { ps -p $P -o time= | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
c0=$(t); w0=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())'); w0=$(python3 -c 'import time;print(time.time())')
sleep $WIN
c1=$(t); w1=$(python3 -c 'import time;print(time.time())'); rss=$(ps -p $P -o rss=)
kill $P; wait $P 2>/dev/null
python3 -c "print(f'$LBL: CPU {100*($c1-$c0)/($w1-$w0):.1f}% over {$w1-$w0:.0f}s · RSS {int($rss)/1024:.0f} MB')"
