#!/bin/zsh
# live-23 (5b) — Apple Intelligence General chat on this Mac (macOS 27 + Apple Intelligence), with the app's OWN request
# builder + refusal detector (AirPad/Services/AppleChat.swift compiled in). Synthetic questions only.
#   scripts/fm_chat_harness/run.sh [before|after|both|dated|dated-ab] [runs]   (live-27: dated-ab = after vs after + the dated line)
set -euo pipefail
A=~/Developer/AirPad; OUT=${TMPDIR:-/tmp}/fm_chat_harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O -parse-as-library -o $OUT $A/scripts/fm_chat_harness/main.swift $A/AirPad/Services/AppleChat.swift
$OUT "$@"
