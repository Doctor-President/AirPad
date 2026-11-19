#!/bin/zsh
# one Mac config → isolated copy:  build1.sh <Debug|Release|Perf> <tag>   → build/runs/<tag>/AirPadMacA.app
source ${0:A:h}/env.sh; cd $ROOT; C=${1:?config}; TAG=${2:?tag}; O=$RUNS/$TAG; mkdir -p $O
CONF=$C; FLAGS=(); [[ $C == Perf ]] && { CONF=Release; FLAGS=(OTHER_SWIFT_FLAGS='$(inherited) -D PERFLOG -D PANBENCH'); }
DD=$ROOT/build/dd-mac-${(L)C}
xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration $CONF -destination "generic/platform=macOS,variant=Mac Catalyst" -derivedDataPath $DD $FLAGS build > $O/build.log 2>&1; e=$?
git checkout -- AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null
[[ $e == 0 ]] && zsh $ROOT/scripts/mac/isolate.sh $DD/Build/Products/$CONF-maccatalyst/AirPad.app $O/AirPadMacA.app > /dev/null 2>&1
echo "$C $TAG exit $e $(git rev-parse --short HEAD)$(git diff --quiet || echo +dirty) → $O/AirPadMacA.app"; grep -E "error:" $O/build.log | sort -u | head -5
zsh ${0:A:h}/prune.sh; exit $e
