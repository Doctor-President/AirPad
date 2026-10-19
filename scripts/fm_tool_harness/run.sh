#!/bin/zsh
# live-28 (A6) — FoundationModels Tool calling on this Mac (macOS 27 + Apple Intelligence). Report-only.
set -euo pipefail
A=~/Developer/AirPad; OUT=${TMPDIR:-/tmp}/fm_tool_harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O -parse-as-library -o $OUT $A/scripts/fm_tool_harness/main.swift
$OUT "$@"
