#!/bin/bash
# Inventory F3 — project.yml integrity. `xcodegen generate` rewrites the pbxproj AND all three
# Info.plists from project.yml, so anything that lives only in a generated file (a plist key, a
# hand-edited version) is silently dropped by the next regenerate. This regenerates and fails if
# any generated file differs from what's committed (or staged).
#   scripts/check_project_yml.sh   → "F3 PASS" (exit 0) or the drift + "F3 FAIL" (exit 1)
# The check leaves the regenerated files in place; on FAIL, `git diff` shows what project.yml lacks.
set -euo pipefail
cd "$(dirname "$0")/.."
GEN=(AirPad.xcodeproj/project.pbxproj AirPad/Info.plist AirPadShare/Info.plist AirPadWidgets/Info.plist)
xcodegen generate --quiet
if git diff --quiet -- "${GEN[@]}"; then
  echo "F3 PASS — xcodegen generate reproduces ${GEN[*]}"
else
  git diff --stat -- "${GEN[@]}"
  git diff -- "${GEN[@]}" | grep '^[-+][^-+]' | head -20
  echo "F3 FAIL — project.yml does not reproduce the committed generated files"
  exit 1
fi
