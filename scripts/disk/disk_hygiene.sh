#!/bin/zsh
# live-28 (2) — keep AirPad/build from taking the Mac to 0 bytes (live-27: 114 GB of per-arc Xcode build folders; at 0
# free the gauntlet died and T's Host went down). Run at the start and end of every round.
#   scripts/disk/disk_hygiene.sh              delete stale derived data, print "free X GB → Y GB"
#   scripts/disk/disk_hygiene.sh --dry-run    say what it would delete, delete nothing
#   scripts/disk/disk_hygiene.sh --check 30   print free space; exit 3 if under 30 GB (the gauntlet's gate)
# What goes — build output Xcode can make again, nothing else:
#   - derived-data folders (a Build/Intermediates.noindex inside, up to 3 levels down) except the newest 2 and what the
#     current branch needs ($DISK_HYGIENE_KEEP, default gauntlet-dd: the gauntlet's own build). A folder that also
#     holds outputs (stills, result bundles, notes) loses only its derived-data parts.
#   - stray root build products (Debug-iphonesimulator, XCBuildData, … from builds without -derivedDataPath) and
#     copied .app folders, older than 7 days.
# Never: gauntlet-runs, inventory-runs, renders, anything outside the build/ folder, T's data.
set -uo pipefail
ROOT=${DISK_HYGIENE_ROOT:-$HOME/Developer/AirPad/build}
KEEP=(${=DISK_HYGIENE_KEEP:-gauntlet-dd})
NEVER=(gauntlet-runs inventory-runs renders)
DD_PARTS=(Build Index.noindex ModuleCache.noindex SourcePackages SDKExplicitPrecompiledModules CompilationCache.noindex
          SDKStatCaches.noindex Logs TestResults info.plist)
STRAY=(AirPad.build Debug-iphoneos Debug-iphonesimulator Release-iphoneos Release-iphonesimulator EagerLinkingTBDs
       ExplicitPrecompiledModules SwiftExplicitPrecompiledModules XCBuildData Logs)
DRY=0; CHECK=""
while (( $# )); do case $1 in --dry-run) DRY=1; shift;; --check) CHECK=$2; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done
[[ -d $ROOT && ${ROOT:t} == build ]] || { echo "disk_hygiene: refusing root '$ROOT' (not an AirPad build/ folder)"; exit 2; }
ROOT=${ROOT:A}
free_gb() { df -k "$ROOT" | awk 'NR==2{printf "%.1f", $4/1048576}'; }

if [[ -n $CHECK ]]; then
  F=$(free_gb)
  if (( F < CHECK )); then
    echo "disk_hygiene: free $F GB — under $CHECK GB: stop and report (scripts/disk/disk_hygiene.sh frees stale derived data)"; exit 3
  fi
  echo "disk_hygiene: free $F GB (floor $CHECK GB)"; exit 0
fi

BEFORE=$(free_gb)
inside() { [[ $1 == $ROOT/* ]]; }
top() { local r=${1#$ROOT/}; print -r -- ${r%%/*}; }
gone() {   # delete one path inside ROOT (or say so in a dry run)
  local p=$1; inside "$p" || { echo "disk_hygiene: BUG — $p is outside $ROOT; not deleting"; return; }
  local sz=$(du -sk "$p" 2>/dev/null | cut -f1)
  if (( DRY )); then echo "  would delete ${p#$ROOT/} ($(( sz / 1024 )) MB)"; else rm -rf -- "$p"; echo "  deleted ${p#$ROOT/} ($(( sz / 1024 )) MB)"; fi
}
is_dd_only() {   # every entry of $1 is a derived-data part
  local e; for e in "$1"/*(DN); do (( ${DD_PARTS[(Ie)${e:t}]} )) || return 1; done; return 0
}

# derived-data roots, newest first by their Build/ folder's time
typeset -a ROOTS
while IFS= read -r ix; do
  d=${ix%/Build/Intermediates.noindex}
  t=$(top "$d"); (( ${NEVER[(Ie)$t]} )) && continue
  ROOTS+=("$(stat -f %m "$d/Build") $d")
done < <(find "$ROOT" -maxdepth 4 -type d -path '*/Build/Intermediates.noindex' 2>/dev/null)
KEPT=0
for line in ${(On)ROOTS}; do
  d=${line#* }; t=$(top "$d")
  if (( ${KEEP[(Ie)$t]} )) || (( ${KEEP[(Ie)${d#$ROOT/}]} )); then echo "  keep ${d#$ROOT/} (current branch needs it)"; continue; fi
  if (( KEPT < 2 )); then (( KEPT++ )); echo "  keep ${d#$ROOT/} (newest $KEPT)"; continue; fi
  if is_dd_only "$d"; then gone "$d"
  else for part in $DD_PARTS; do [[ -e $d/$part ]] && gone "$d/$part"; done; fi
done

# stray root products and copied apps, older than 7 days
NOW=$(date +%s)
for e in "$ROOT"/*(DN); do
  n=${e:t}; (( ${NEVER[(Ie)$n]} )) && continue; (( ${KEEP[(Ie)$n]} )) && continue
  age=$(( (NOW - $(stat -f %m "$e")) / 86400 )); (( age < 7 )) && continue
  if (( ${STRAY[(Ie)$n]} )); then gone "$e"; continue; fi
  if [[ -d $e ]]; then
    apps=("$e"/*.app(DN)); all=("$e"/*(DN))
    (( ${#apps} > 0 && ${#apps} == ${#all} )) && gone "$e"
  fi
done
AFTER=$(free_gb)
echo "disk_hygiene: free $BEFORE GB → $AFTER GB$( (( DRY )) && print ' (dry run)')"
