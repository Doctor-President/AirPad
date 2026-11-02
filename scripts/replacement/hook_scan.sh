#!/bin/zsh
# 1.0r S2b — Release hook scan: every DEBUG launch-arg hook in the app's source must be absent from a Release
# (App Store mode) binary. Collects the hook names from `arguments.contains("-X")` / `firstIndex(of: "-X")` in AirPad/,
# then counts them in `strings` of the built binary. Positive control: the same scan on the Debug binary must find them.
#   hook_scan.sh <release AirPad.app> <debug AirPad.app> <out-dir>
set -u
REL=$1; DBG=$2; OUT=$3; ROOT=${0:A:h:h:h}; mkdir -p $OUT
grep -rhoE 'contains\("-[A-Za-z][A-Za-z0-9]+"\)|firstIndex\(of: "-[A-Za-z][A-Za-z0-9]+"\)' $ROOT/AirPad \
  | grep -oE '"-[A-Za-z][A-Za-z0-9]+"' | tr -d '"' | sort -u > $OUT/hooks.txt
bin() { local app=$1; for f in $app/AirPad $app/AirPad.debug.dylib; do [[ -f $f ]] && strings -a $f; done; }
bin $REL > $OUT/release-strings.txt; bin $DBG > $OUT/debug-strings.txt
grep -xFf $OUT/hooks.txt $OUT/release-strings.txt | sort -u > $OUT/release-hits.txt
grep -xFf $OUT/hooks.txt $OUT/debug-strings.txt | sort -u > $OUT/debug-hits.txt
echo "hooks in source: $(wc -l < $OUT/hooks.txt | tr -d ' ') · Release hits: $(wc -l < $OUT/release-hits.txt | tr -d ' ') · Debug hits (control): $(wc -l < $OUT/debug-hits.txt | tr -d ' ')"
[[ -s $OUT/release-hits.txt ]] && { echo "Release hits:"; cat $OUT/release-hits.txt; }
