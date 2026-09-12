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
#   AIRPAD_TF_DEV_TUNERS=1  — compile the `#if DEBUG` dev tuners INTO the Release archive
#   (SWIFT_ACTIVE_COMPILATION_CONDITIONS gains DEBUG, still -O). This is how T dials a spike
#   on TestFlight, where neither print() nor os_log reaches him. It is deliberately a FLAG and
#   never project.yml, so an App Store build can't pick it up by accident — and it verifies a
#   known tuner symbol is actually in the binary afterwards rather than trusting the flag.
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
DEV_TUNER_ARGS=()
if [[ "${AIRPAD_TF_DEV_TUNERS:-0}" == "1" ]]; then
  say "dev tuners: ON — DEBUG code compiled into the Release archive"
  DEV_TUNER_ARGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) DEBUG")
fi
say "Archiving…"
xcodebuild \
  -project AirPad.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${DEV_TUNER_ARGS[@]+"${DEV_TUNER_ARGS[@]}"}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive || die "Archive failed — see xcodebuild output above."

# The flag is not the evidence: a silently dropped build setting looks exactly like a clean build,
# so confirm the tuner is really in the shipped Mach-O before uploading.
#
# Two traps this has already hit, hence the shape below:
#   • Swift stores string literals of <=15 UTF-8 bytes INLINE in the String struct, so they never
#     appear in the binary. A short probe reports 0 and reads as "absent". Probes must be LONG.
#   • `grep -r` over a Mach-O does not find them either; `strings` does. And under `set -o pipefail`
#     a no-match grep in a $( ) assignment kills the script with NO message at all.
# So: use strings, tolerate no-match, and require a POSITIVE CONTROL — a string known to ship in
# Release — to pass first. Without the control, "0 hits" proves nothing about the build.
if [[ "${AIRPAD_TF_DEV_TUNERS:-0}" == "1" ]]; then
  APP_DIR="$ARCHIVE_PATH/Products/Applications/AirPad.app"
  BINS=("$APP_DIR/AirPad")
  [[ -f "$APP_DIR/AirPad.debug.dylib" ]] && BINS+=("$APP_DIR/AirPad.debug.dylib")   # Xcode 16+ split
  count_in() { local pat="$1" n=0 b hits; for b in "${BINS[@]}"; do
      hits=$(strings -a "$b" | grep -cF "$pat" || true); n=$(( n + hits )); done; printf '%s' "$n"; }

  control=$(count_in "u_camera_position")                        # a Release-shipping literal
  (( control > 0 )) || die "Verification is broken: the control string is absent too, so a 0 for the
  tuner would mean nothing. Not uploading."
  tuner=$(count_in "COMPLETE STATE (both appearances)")           # tuner export header, DEBUG-only
  (( tuner > 0 )) || die "Dev tuners requested but absent from the archive — the flag did not take
  (control probe found $control, so the check itself is sound). Not uploading."
  say "dev tuners verified in the archive (tuner $tuner hit(s), control $control)"
fi

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
