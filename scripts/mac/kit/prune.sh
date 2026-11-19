#!/bin/zsh
# keep the newest N (default 12) runs in build/runs; a run with a .keep file is never removed
source ${0:A:h}/env.sh; N=${1:-12}; i=0
for d in $(ls -1td $RUNS/*/ 2>/dev/null); do i=$((i+1)); (( i <= N )) && continue; [[ -f $d/.keep ]] && continue; rm -rf $d; done
