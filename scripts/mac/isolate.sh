#!/bin/zsh
# Mac batch A — the ISOLATED Mac copy for automated runs. From a built AirPad.app (Catalyst) make a copy with its own
# bundle ID (com.doctorpresident.airpad.macA → its own sandbox container), ad-hoc signed with App Sandbox and the
# non-restricted Mac keys only: NO iCloud (it can never reach T's library), NO App Group, NO extensions.
#   isolate.sh <AirPad.app> <out.app>
set -euo pipefail
SRC=${1:?app}; OUT=${2:?out}; ID=com.doctorpresident.airpad.macA
rm -rf $OUT; ditto $SRC $OUT
rm -rf $OUT/Contents/PlugIns $OUT/Contents/embedded.provisionprofile
plutil -replace CFBundleIdentifier -string $ID $OUT/Contents/Info.plist
plutil -replace CFBundleDisplayName -string "AirPad Mac-A" $OUT/Contents/Info.plist
ENT=${OUT:h}/macA.entitlements
cat > $ENT <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.camera</key><true/>
</dict></plist>
PL
# nested code first (Debug: AirPad.debug.dylib + __preview.dylib; frameworks if any), then the app
for f in $OUT/Contents/**/*.dylib(N) $OUT/Contents/Frameworks/*.framework(N); do codesign -f -s - $f; done
codesign -f -s - --entitlements $ENT $OUT   # ad-hoc: no hardened runtime (library validation would need a Team ID)
codesign --verify --deep --strict $OUT && echo "isolated: $OUT ($ID)"
echo "iCloud/AppGroup keys in copy: $(codesign -d --entitlements :- $OUT 2>/dev/null | grep -c 'icloud\|application-groups' || true)"
