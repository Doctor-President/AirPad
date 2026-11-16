#!/bin/zsh
# E fix-up 3 · H1 — toolbar click → effect latency with real clicks (rlat), per scenario. Mac awake + Accessibility.
#   h1.sh <isolated .app> <out dir> [scenario …]     EXTRA="-Arg v" for launch args
set -u
D=${0:A:h:h:h:h}/build/mac-e/fixup3; mkdir -p $D; for t in rclick rlat rframe; do [[ $D/$t -nt ${0:A:h}/$t.swift ]] || swiftc -O -o $D/$t ${0:A:h}/$t.swift 2>/dev/null; done; APP=${1:?app}; OUT=${2:?out}; shift 2; mkdir -p $OUT
R=$D/rclick; L=$D/rlat; F=$D/rframe
caffeinate -d -u -w $$ &
$APP/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES ${=EXTRA:-} > $OUT/app.log 2>&1 &
P=$!; trap "kill $P 2>/dev/null" EXIT
sleep 12
$R winmove $P 0 160 > /dev/null
{ [[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 } }; $R click $P sidebar.sample > /dev/null; sleep 2
V=start
: >> $OUT/summary.txt
run() { # run <name> <rlat args…>
  local name=$1; shift
  $L $P "$@" > $OUT/$name.txt 2>&1
  print -r -- "$name :: $(tail -1 $OUT/$name.txt)" | tee -a $OUT/summary.txt
}
px() { # px <name> <rframe args…>
  local name=$1; shift
  $F $P "$@" > $OUT/$name.txt 2>&1
  print -r -- "$name :: $(tail -1 $OUT/$name.txt)" | tee -a $OUT/summary.txt
}
for S in "$@"; do
  case $S in
    sb10)       run sb10-$V-$RANDOM 10 wait 300 0 toolbar.sidebar:toolbar.sidebar:AXDescription ;;
    lib2)       run lib2-$V-$RANDOM 2 wait 300 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    lib10)      run lib10-$V-$RANDOM 10 wait 300 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    lib)        run lib-$V 50 wait 300 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    lib-w2)     run lib-w2 50 wait 300 2 toolbar.librarian:toolbar.librarian:AXValue ;;
    lib-fast)   run lib-fast 50 wait 40 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    lib-burst)  run lib-burst 50 fixed 220 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    views)      run views 60 wait 300 0 toolbar.view.Map:toolbar.view.Map:AXSelected toolbar.view.List:toolbar.view.List:AXSelected toolbar.view.Cards:toolbar.view.Cards:AXSelected ;;
    views-fast) run views-fast 60 wait 40 1 toolbar.view.Map:toolbar.view.Map:AXSelected toolbar.view.List:toolbar.view.List:AXSelected toolbar.view.Cards:toolbar.view.Cards:AXSelected ;;
    sidebar)    run sidebar 50 wait 300 0 toolbar.sidebar:toolbar.sidebar:AXDescription ;;
    newback)    run newback 50 wait 400 0 toolbar.newEntry:toolbar.back:AXEnabled toolbar.back:toolbar.back:AXEnabled ;;
    search)     run search 50 wait 200 0 toolbar.search:toolbar.search:AXFocused key53:toolbar.search:AXFocused ;;
    px-lib)     px px-lib 50 250 0 toolbar.librarian ;;
    px-lib-w2)  px px-lib-w2 50 250 2 toolbar.librarian ;;
    px-lib-t)   RFRAME_TRACE=1 px px-lib-t 4 250 0 toolbar.librarian ;;
    px-lib-fast) px px-lib-fast 50 0 0 toolbar.librarian ;;
    px-map)     px px-map 25 250 0 toolbar.view.Map ;;
    px-list)    px px-list 25 250 0 toolbar.view.List ;;
    px-sidebar) px px-sidebar 50 250 0 toolbar.sidebar "$($R find $P sidebar.today | tr -d '()' | awk -F'[, ×]' '{print $1","$2","$3","$4}')" ;;
    cpu)        sleep 3; print -r -- "cpu-$V :: $(ps -o %cpu= -p $P) % (3 s after the last click)" | tee -a $OUT/summary.txt; sample $P 3 1 -mayDie -file $OUT/idle-$V-$RANDOM.txt > /dev/null 2>&1 ;;
    axlist)     print -r -- "axlist-$V :: macListPanel $($R has $P macListPanel) · macListHeader $($R has $P macListHeader)" | tee -a $OUT/summary.txt ;;
    shot)       screencapture -x -R$($R winpos $P | tr -d '()' | awk -F'[, ×]' '{print $1","$2","$3","$4}') $OUT/shot-$V-$RANDOM.png ;;
    map)        V=map; $R click $P toolbar.view.Map > /dev/null; sleep 2 ;;
    list)       V=list; $R click $P toolbar.view.List > /dev/null; sleep 2 ;;
    cards)      V=cards; $R click $P toolbar.view.Cards > /dev/null; sleep 2 ;;
    lib<->)     run $S-$V-$RANDOM ${S#lib} wait ${GAP:-300} 0 toolbar.librarian:toolbar.librarian:AXValue ;;
    sb<->)      run $S-$V-$RANDOM ${S#sb} wait ${GAP:-300} 0 toolbar.sidebar:toolbar.sidebar:AXDescription ;;
    *)          print "unknown $S" ;;
  esac
done
