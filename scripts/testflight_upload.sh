#!/usr/bin/env bash
#
# AirPad → TestFlight, headless.
#   1. archive (Release)  2. export (App Store)  3. upload via altool
#
# Credentials are NEVER hardcoded — read from env vars or a gitignored config
# file (default ~/.config/airpad/testflight.env). See scripts/testflight.env.example.
#
# Usage:  ~/Developer/AirPad/scripts/testflight_upload.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Stable Xcode 26.6 — never the broken 26.5 beta; no sudo needed.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SCHEME="AirPad"
CONFIG="Release"
TEAM_ID="8XM4B5F42Y"
ARCHIVE_PATH="/tmp/AirPad.xcarchive"
EXPORT_DIR="/tmp/AirPad_export"
EXPORT_PLIST="$REPO_ROOT/scripts/ExportOptions.plist"

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m→ %s\033[0m\n' "$*"; }

# ---- Credentials: real env vars win; otherwise a gitignored config file ----
for c in "${AIRPAD_TF_CONFIG:-}" "$HOME/.config/airpad/testflight.env" "$REPO_ROOT/.testflight.env"; do
  if [[ -n "$c" && -f "$c" ]]; then
    say "config: $c"
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      [[ -n "${!k:-}" ]] || export "$k=${v//\"/}"
    done < <(grep -vE '^\s*#|^\s*$' "$c")
    break
  fi
done

missing=()
[[ -n "${ASC_KEY_ID:-}"    ]] || missing+=(ASC_KEY_ID)
[[ -n "${ASC_ISSUER_ID:-}" ]] || missing+=(ASC_ISSUER_ID)
[[ -n "${ASC_KEY_PATH:-}"  ]] || missing+=(ASC_KEY_PATH)
(( ${#missing[@]} == 0 )) || die "Missing credentials: ${missing[*]}
  Set them via env vars, or in ~/.config/airpad/testflight.env
  (copy scripts/testflight.env.example)."

ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"          # expand a leading ~
[[ -r "$ASC_KEY_PATH" ]] || die "Key not readable: $ASC_KEY_PATH"

# App Store rejects duplicate build numbers, so each run gets a unique one.
BUILD_NUMBER="${AIRPAD_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

say "Xcode: $(xcodebuild -version | head -1)  |  Key $ASC_KEY_ID  Team $TEAM_ID  Build $BUILD_NUMBER"

# ---- 1. Archive (Release). API key lets xcodebuild provision the ----
#         distribution cert + App Store profile headlessly on first run.
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
say "Archiving…"
xcodebuild \
  -project AirPad.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive || die "Archive failed — see xcodebuild output above."

# ---- 2. Export for the App Store (produces the .ipa) ----
say "Exporting (App Store)…"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" || die "Export failed — see xcodebuild output above."

IPA="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[[ -f "$IPA" ]] || die "No .ipa produced in $EXPORT_DIR"
say "IPA: $IPA"

# ---- 3. Upload via altool ----
# NOTE: altool has no --private-key-path. It finds AuthKey_<KeyID>.p8 inside
# API_PRIVATE_KEYS_DIR. The key is already named that in ~/.appstore, so point
# the dir there; if a non-standard filename is ever used, stage a temp copy.
if [[ "$(basename "$ASC_KEY_PATH")" == "AuthKey_${ASC_KEY_ID}.p8" ]]; then
  export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"
else
  KEYDIR="$(mktemp -d)"; trap 'rm -rf "$KEYDIR"' EXIT
  cp "$ASC_KEY_PATH" "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
  chmod 600 "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
  export API_PRIVATE_KEYS_DIR="$KEYDIR"
fi

say "Uploading to App Store Connect…"
xcrun altool --upload-app \
  -f "$IPA" \
  --type ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" || die "Upload failed — see altool output above."

printf '\n\033[32m✅ Uploaded — check TestFlight in ~2-3 min\033[0m\n'
