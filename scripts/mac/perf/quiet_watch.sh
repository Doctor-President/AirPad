#!/bin/zsh
# Sweep 2b — "day and night, never side by side": logs every second whether a build, Simulator or model server (other
# than T's own Host) is running. Usage: quiet_watch.sh <out.log> & … ; a measurement whose window has a BUSY line is thrown away.
OUT=${1:?log}; : > $OUT
while true; do
  b=$(ps -axo comm= | grep -cE "xcodebuild|swift-frontend|clang|ld$|launchd_sim|ibtoold|actool")
  m=$(ps -axo command= | grep -E "ollama (serve|runner)" | grep -v "AirPad Host.app" | grep -vc grep)
  (( b + m > 0 )) && echo "$(date +%s) BUSY build=$b model=$m" >> $OUT
  sleep 1
done
