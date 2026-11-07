#!/bin/zsh
# Mac batch B2 — the upgrade test: an existing library from an OLDER build gains revision stamps silently, nothing lost.
#   upgrade.sh <old.app> <new-release.app> <new-debug.app> <sim udid> <out_dir>
# 1. erase the Simulator, install the old build, launch it (no iCloud on the Simulator → the local library; the Sample
#    Library seeds), let it run, quit; snapshot the library (before/).
#    Then make a "user edit" as the old build would have saved it (a note changed in node.json, no stamp).
# 2. install the new Release build OVER it (same bundle id = an App Store update), launch, let background passes run,
#    quit; snapshot (after-release/).
# 3. install the new Debug build over that, make a real edit through the store (harness command), quit; snapshot
#    (after-edit/). compare.py checks every entry's user content survives each step and counts stamps.
set -uo pipefail
OLD=${1:?old}; NEWR=${2:?new release}; NEWD=${3:?new debug}; SIM=${4:?udid}; OUT=${5:?out}
BUNDLE=com.doctorpresident.airpad
mkdir -p $OUT; OUT=${OUT:A}
xcrun simctl shutdown $SIM 2>/dev/null; xcrun simctl erase $SIM; xcrun simctl boot $SIM
lib() { echo "$(xcrun simctl get_app_container $SIM $BUNDLE data)/Documents/AirPad"; }
run() {  # run the installed app for $1 seconds with args
  local secs=$1; shift
  xcrun simctl launch --terminate-running-process $SIM $BUNDLE "$@" > /dev/null
  sleep $secs
  xcrun simctl terminate $SIM $BUNDLE 2>/dev/null; sleep 2
}
snap() { rm -rf $OUT/$1; ditto "$(lib)" $OUT/$1; echo "$1: $(ls $OUT/$1/nodes | wc -l | tr -d ' ') entries"; }

xcrun simctl install $SIM $OLD
run 75
snap before-raw
# A user edit as the old build saved it: first text note of the first entry gets a line (written like the old app, no stamp).
python3 - "$(lib)" <<'PY'
import json, os, sys
root = sys.argv[1]
for d in sorted(os.listdir(os.path.join(root, "nodes"))):
    p = os.path.join(root, "nodes", d, "node.json")
    try: n = json.load(open(p))
    except Exception: continue
    for it in n.get("items", []):
        if it.get("type") == "text":
            it["content"] = (it.get("content") or "") + "\n\nEdited on the old build before the update ✓"
            json.dump(n, open(p, "w"), indent=2, sort_keys=True, ensure_ascii=False)
            open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(p))), ".upgrade-edited"), "w").write(d)
            print("old-build edit in", d); sys.exit(0)
PY
snap before
xcrun simctl install $SIM $NEWR
run 75
snap after-release
xcrun simctl install $SIM $NEWD
EDITED=$(cat "$(lib)/.upgrade-edited")
ITEM=$(python3 -c "import json,sys; n=json.load(open(sys.argv[1])); print(next(i['id'] for i in n['items'] if i.get('type')=='text'))" "$(lib)/nodes/$EDITED/node.json")
mkdir -p $OUT/cmd
python3 - $OUT/cmd $EDITED $ITEM "$(lib)/nodes/$EDITED/node.json" <<'PY'
import json, sys
d, e, i, p = sys.argv[1:5]
text = next(x["content"] for x in json.load(open(p))["items"] if x["id"] == i)
json.dump({"id": "edit", "op": "set_text", "entry": e, "item": i, "text": text + "\nEdited on 1.0.2 after the update ✓"}, open(f"{d}/cmd-1.json", "w"))
json.dump({"id": "dump", "op": "dump"}, open(f"{d}/cmd-2.json", "w"))
PY
run 40 -TwoDeviceCommands $OUT/cmd
snap after-edit
python3 ${0:A:h}/compare_upgrade.py $OUT
