# source me: opens the isolated Debug build on the Sample Library Map with the first List entry's card (-MapCardNode)
R=./rclick
start() { caffeinate -d -u -t 300 & ./h5-debug/AirPadMacA.app/Contents/MacOS/AirPad -ApplePersistenceIgnoreState YES "$@" >> h5/app.log 2>&1 & P=$!; sleep 12; $R winmove $P 0 60 >/dev/null; $R winsize $P 1350 840 >/dev/null; [[ $($R has $P sidebar.today) == no ]] && { $R click $P toolbar.sidebar >/dev/null; sleep 1 }; $R click $P sidebar.sample >/dev/null; sleep 1.5 }
