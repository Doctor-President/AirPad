#!/bin/zsh
# iPhone Simulator build:  buildios.sh <Debug|Release> <tag>   (Release = bench: + -D PERFLOG -D PANBENCH)
source ${0:A:h}/env.sh; cd $ROOT; C=${1:?config}; TAG=${2:?tag}; O=$RUNS/$TAG; mkdir -p $O
FLAGS=(); [[ $C == Release ]] && FLAGS=(OTHER_SWIFT_FLAGS='$(inherited) -Xcc -DACCELERATE_NEW_LAPACK -D PERFLOG -D PANBENCH')
DD=$ROOT/build/dd-ios-${(L)C}
xcodebuild -project AirPad.xcodeproj -scheme AirPad -configuration $C -destination "generic/platform=iOS Simulator" -derivedDataPath $DD ARCHS=arm64 ONLY_ACTIVE_ARCH=YES $FLAGS build > $O/build.log 2>&1; e=$?
git checkout -- AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme 2>/dev/null
echo "ios $C $TAG exit $e → $DD/Build/Products/$C-iphonesimulator/AirPad.app"; grep -E "error:" $O/build.log | sort -u | head -5
zsh ${0:A:h}/prune.sh; exit $e
