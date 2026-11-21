#!/bin/zsh
# Sweep 2a amendment — the web cases (benchmark/cases-web.json) on one route with a REAL search provider.
#   zsh scripts/librarian/web_bench.sh <tavily|brave|empty> <apple|server> <model|-> <out-dir> [cases.json] [-- extra launch args]
# The key is the live harness's test key in this Mac's Keychain (airpad-live-<provider>, put there by T for test runs):
# read straight into the launch arguments, never printed, never written; every file the run wrote is checked for it.
# "empty": no real provider — a local stub that answers every search with zero results (what does the app say then?).
# Env: BENCH_SIM (default build/sweep2a/sim-web.udid, so it can run beside the main benchmark), BENCH_APP.
set -u
cd ${0:A:h}/../..
prov=$1; route=$2; model=$3; out=${4:A}; shift 4
cases=scripts/librarian/benchmark/cases-web.json
[[ $# -gt 0 && $1 != -- ]] && { cases=$1; shift }
[[ ${1:-} == -- ]] && shift
export BENCH_SIM=${BENCH_SIM:-$(cat build/sweep2a/sim-web.udid)}
B=com.doctorpresident.airpad
mkdir -p $out
stub=""
case $prov in
  tavily) KEY=$(security find-generic-password -s airpad-live-tavily -w 2>/dev/null); wargs=(-webSearchProvider tavily -TavilyTestKey "$KEY") ;;
  brave)  KEY=$(security find-generic-password -s airpad-live-brave -w 2>/dev/null);  wargs=(-webSearchProvider brave -BraveTestKey "$KEY") ;;
  empty)  KEY=stub-key; python3 scripts/librarian/empty_search_stub.py 18477 > $out/stub.log 2>&1 & stub=$!
          wargs=(-webSearchProvider brave -BraveTestKey stub-key -WebSearchBaseURL http://127.0.0.1:18477) ;;
  *) echo "provider: tavily | brave | empty"; exit 2 ;;
esac
[[ -z $KEY ]] && { echo "no Keychain item airpad-live-$prov"; exit 1 }
xcrun simctl bootstatus $BENCH_SIM -b > /dev/null 2>&1
DATA=$(xcrun simctl get_app_container $BENCH_SIM $B data 2>/dev/null); [[ -n $DATA ]] && rm -f $DATA/tmp/webtrace.jsonl
zsh scripts/librarian/bench.sh $route $model $cases $out -- -WebTrace YES -webSearchEnabled YES "${wargs[@]}" "$@"
DATA=$(xcrun simctl get_app_container $BENCH_SIM $B data 2>/dev/null)
cp $DATA/tmp/webtrace.jsonl $out/webtrace.jsonl 2>/dev/null || echo "no web trace"
[[ -n $stub ]] && kill $stub 2>/dev/null
if [[ $prov != empty ]]; then
  leaks=$(/usr/bin/grep -rlF -- "$KEY" $out 2>/dev/null)
  [[ -n $leaks ]] && { echo "KEY FOUND in: $leaks — deleting those files"; echo $leaks | xargs rm -f } || echo "key check: not in any file of $out"
fi
KEY=""
