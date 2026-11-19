#!/bin/zsh
# compile the real-event tools into build/kit when their source is newer
source ${0:A:h}/env.sh; H=$ROOT/scripts/mac/realclick
for s in $H/*.swift; do t=$KIT/${s:t:r}; [[ $t -nt $s ]] || swiftc -O -o $t $s 2>$KIT/${s:t:r}.err || echo "FAILED ${s:t}"; done
ls $KIT | grep -v '\.err$' | tr '\n' ' '; echo
