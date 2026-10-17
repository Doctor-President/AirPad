#!/bin/zsh
# live-20 (1) — build + run the Apple Intelligence naming harness on this Mac. Synthetic notes only.
#   scripts/fm_naming_harness/run.sh <notes.json> [before|after|both] [runs]
set -euo pipefail
A=~/Developer/AirPad; OUT=${TMPDIR:-/tmp}/fm_naming_harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O -parse-as-library -o $OUT $A/scripts/fm_naming_harness/main.swift $A/AirPad/Services/AppleNaming.swift
$OUT "$@"
