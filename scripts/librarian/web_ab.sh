#!/bin/zsh
# Sweep 2a amendment — the web cases on an OLDER commit (scratch worktree with the small WebABRun runner patched in;
# see design-refs/librarian-audit/benchmark/web.md). Apple Intelligence route, Simulator only.
#   zsh scripts/librarian/web_ab.sh <tavily|brave> <old .app> <out-dir>
set -u
cd ${0:A:h}/../..
prov=$1; app=${2:A}; out=${3:A}
SIM=$(cat build/sweep2a/sim-web.udid); B=com.doctorpresident.airpad
mkdir -p $out
case $prov in
  tavily) KEY=$(security find-generic-password -s airpad-live-tavily -w 2>/dev/null); wargs=(-webSearchProvider tavily -TavilyTestKey "$KEY") ;;
  brave)  KEY=$(security find-generic-password -s airpad-live-brave -w 2>/dev/null);  wargs=(-webSearchProvider brave -BraveTestKey "$KEY") ;;
esac
[[ -z $KEY ]] && { echo "no key"; exit 1 }
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1
xcrun simctl install $SIM $app || exit 3
DATA=$(xcrun simctl get_app_container $SIM $B data 2>/dev/null); [[ -n $DATA ]] && rm -f $DATA/tmp/webtrace.jsonl
rm -f $out/results.json; log=$out/app.log
xcrun simctl launch --console-pty --terminate-running-process $SIM $B -SampleSeedDemo -EmbedCPUOnly -WebTrace YES -webSearchEnabled YES \
  "${wargs[@]}" -WebABRun ${PWD}/scripts/librarian/benchmark/cases-web.json -WebABOut $out > $log 2>&1 &
launcher=$!
deadline=$(( $(date +%s) + 1200 ))
while ! grep -q "\[LibrarianBench\] done" $log 2>/dev/null; do
  (( $(date +%s) > deadline )) && { echo TIMEOUT; break }
  kill -0 $launcher 2>/dev/null || { sleep 2; break }
  sleep 3
done
xcrun simctl terminate $SIM $B > /dev/null 2>&1
grep -E "\[LibrarianBench\] (START|RESULT|TURN .* END)" $log | sed 's/^.*\[LibrarianBench\]/[bench]/' | cut -c1-160
DATA=$(xcrun simctl get_app_container $SIM $B data 2>/dev/null)
cp $DATA/tmp/webtrace.jsonl $out/webtrace.jsonl 2>/dev/null || echo "no web trace"
leaks=$(/usr/bin/grep -rlF -- "$KEY" $out 2>/dev/null)
[[ -n $leaks ]] && { echo "KEY FOUND in: $leaks — deleting"; echo $leaks | xargs rm -f } || echo "key check: not in any file of $out"
KEY=""
