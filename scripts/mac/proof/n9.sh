#!/bin/zsh
# sweep-1 N9 — docked Librarian: toolbar Search → panel "Search"; the panel ‹ ends search (field empty, title gone,
# panel home); then the chats button ends search and shows "Chats". Real clicks + typing.  n9.sh <pid> <out> [n=5]
source ${0:A:h}/lib.sh; P=${1:?pid}; O=${2:?out}; N=${3:-5}; mkdir -p $O; : > $O/results.txt
x0() { $R has $P "$1" | sed -E 's/^yes \(([0-9-]+),.*/\1/;s/^no$/-1/'; }
for i in $(seq 1 $N); do
  $R click $P toolbar.search >/dev/null; $R type $P coffee >/dev/null; sleep 1.5
  s1=$($R has $P macLibrarianSearchTitle | cut -c1-3)
  $R click $P macLibrarianBack >/dev/null; sleep 1.2
  v=$($R get $P toolbar.search AXValue); t=$($R has $P macLibrarianSearchTitle); h=$($R has $P macLibrarianEmpty | cut -c1-3)
  ok=$([[ $s1 == yes && -z $v && $t == no && $h == yes ]] && echo PASS || echo FAIL)
  echo "back $i: search-up=$s1 field=[$v] title-after=$t home=$h → $ok" | tee -a $O/results.txt
  $R click $P toolbar.search >/dev/null; $R type $P coffee >/dev/null; sleep 1.5
  s1=$($R has $P macLibrarianSearchTitle | cut -c1-3)
  $R click $P macLibrarianHistory >/dev/null; sleep 1.5
  v=$($R get $P toolbar.search AXValue); t=$($R has $P macLibrarianSearchTitle); cx=$(x0 Chats)
  ok=$([[ $s1 == yes && -z $v && $t == no && $cx -ge 980 ]] && echo PASS || echo FAIL)
  echo "chats $i: search-up=$s1 field=[$v] title-after=$t chats-title-x=$cx → $ok" | tee -a $O/results.txt
  [[ $i == 1 ]] && cap $P $O/chats-1.png
  $R click $P macLibrarianBack >/dev/null; sleep 1.2
done
echo "back PASS $(grep -c '^back.*PASS' $O/results.txt)/$N · chats PASS $(grep -c '^chats.*PASS' $O/results.txt)/$N" | tee -a $O/results.txt
