#!/bin/zsh
# live-23 (5b) — Apple Intelligence General chat on this Mac (macOS 27 + Apple Intelligence), with the app's OWN request
# builder + refusal detector (AirPad/Services/AppleChat.swift compiled in). Synthetic questions only.
#   scripts/fm_chat_harness/run.sh [before|after|both|dated|dated-ab|general-ab] [runs]   (live-27: dated-ab = after vs after + the dated line; live-28 (A5): general-ab = the dated line vs the new General ending; live-29 (B5): web-ab = General vs + web packet vs pasted news; live-30 (A1): webnew-ab = the results framed as the app's search, followup = the 10 two-turn follow-up chats)
set -euo pipefail
A=${0:A:h:h:h}; OUT=${TMPDIR:-/tmp}/fm_chat_harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O -parse-as-library -o $OUT $A/scripts/fm_chat_harness/main.swift $A/AirPad/Services/AppleChat.swift $A/AirPad/Services/AppleWebQuery.swift \
  $A/AirPad/Services/WebEvidencePure.swift $A/AirPad/Services/WordPieceTokenizer.swift
# live-33 — `pipeline "<question>" …`: the Tavily key from this Mac's Keychain into the harness's environment only.
if [[ ${1:-} == pipeline ]]; then
  HARNESS_TAVILY_KEY=$(security find-generic-password -s airpad-live-tavily -w 2>/dev/null) \
  HARNESS_APP=${HARNESS_APP:-$A/../../../build/dd-after33/Build/Products/Debug-iphonesimulator/AirPad.app} $OUT "$@"
else $OUT "$@"; fi
