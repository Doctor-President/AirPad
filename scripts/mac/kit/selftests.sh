#!/bin/zsh
# Every Mac launch-arg self-test on a DEBUG isolated copy.  selftests.sh <app> <out>   ONLY="A B" to pick
# MapPointer runs on a fresh Sample scratch (a drifted shared scratch left 3 orbs: "no orb on screen", sweep 2b verifier).
source ${0:A:h}/env.sh; cd $ROOT; A=$1; O=$2; mkdir -p $O
PREF=~/Library/Containers/com.doctorpresident.airpad.macA/Data/Library/Preferences/com.doctorpresident.airpad.macA
for k in view.buttons map.intro librarian.intro librarian.sample librarian.mode librarian.model entry.intro capture.title; do defaults write $PREF com.airpad.callouts.$k -bool true; done
TESTS=("MacClickSelfTest -UITestSeedChats -MacWindowSize 1350x840 -MacClickVia window -MacLibrarian open -MacSidebar on"
  "MacResizeSelfTest -MacWindowSize 1350x840 -MacLibrarian open -MacSidebar on" "MacZoomFitSelfTest -OpenMap -MacWindowSize 1350x840"
  "MacChatsPanelSelfTest -UITestSeedChats -MacWindowSize 1350x840" "MacLayoutSelfTest -OpenMap -MacWindowSize 1350x840"
  "MacMenuSelfTest -OpenMap" "MacSettingsSelfTest" "EditorRoundTripSelfTest" "MapPointerSelfTest -OpenMap -UITestLibraryFresh"
  "MacBatchESelfTest -MacWindowSize 1350x840 -MacLibrarian open -MacSidebar on"
  "MacFixupSelfTest -MacWindowSize 1350x840 -MacLibrarian open -MacSidebar on" "MacCardSizeSelfTest -OpenMap -MacWindowSize 1350x840"
  "CaptureClickSelfTest" "EntryMenuSelfTest -OpenMap" "Sweep2bFixupSelfTest")
for T in $TESTS; do
  set -- ${=T}; N=$1; shift
  [[ -n ${ONLY:-} && " $ONLY " != *" $N "* ]] && continue
  WAIT=300 zsh scripts/mac/selftest_mac.sh $A $N $O "$@" > /dev/null 2>&1
  echo "$N $* :: $(head -1 $O/$N.txt 2>/dev/null) · $($KIT/locked | cut -d' ' -f1-2)" >> $O/summary.txt
done
echo DONE >> $O/summary.txt
