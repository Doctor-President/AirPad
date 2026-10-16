#!/bin/zsh
# live-21 (1) — package the renders into Ops/design-refs/surface-palette-shadows-2026-10-16/.
#   scripts/renders/package_live21.sh <raw_dir>
set -euo pipefail
R=${1:?raw}; O=~/Developer/Ops/design-refs/surface-palette-shadows-2026-10-16; A=~/Developer/AirPad/scripts/renders
python3 $A/matte.py $R/3-layers-raw $R/3-layers L2-vertical
mkdir -p $R/1-clips-small; for f in $R/1-clips/*.mp4; do ffmpeg -loglevel error -y -i $f -vf "scale=540:-2" -c:v libx264 -crf 26 -preset slow -an $R/1-clips-small/$(basename $f); done
rm -rf $O; mkdir -p $O/1-panels $O/1-clips $O/2-palettes $O/3-shadows $O/3-layers
half() { python3 - "$@" <<'PY'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src); im.resize((im.width // 2, im.height // 2)).save(dst, optimize=True)
PY
}
for d in 1-panels 2-palettes 3-shadows; do for f in $R/$d/*.png; do half $f $O/$d/$(basename $f); done; done
cp $R/1-clips-small/*.mp4 $O/1-clips/
cp $R/3-layers/*.png $O/3-layers/
# contact sheets
cd $R/1-panels
for m in light dark; do for b in grid map vertical; do
  args=(); for st in long home; do for v in A B C D E; do args+=("$v $st:$v-$m-$b-$st.png"); done; done
  python3 $A/sheet.py $O/1-panels-sheet-$m-$b.png 5 0.2 "${args[@]}"
done; done
args=(); for m in light dark; do for v in B C; do for st in long home; do args+=("RT $v $m $st:RT-$v-$m-grid-$st.png"); done; done; done
python3 $A/sheet.py $O/1-panels-sheet-reduce-transparency.png 4 0.2 "${args[@]}"
cd $R/2-palettes; args=(); for p in L1 L2 L3; do for s in card map entry librarian; do args+=("$p $s:$p-$s.png"); done; done
python3 $A/sheet.py $O/2-palettes-sheet.png 4 0.2 "${args[@]}"
cd $R/3-shadows
for p in L1 L2; do for v in vertical coverflow; do
  args=(); for s in S1 S2 S3 S4; do for f in F1 F2 F3 F4; do args+=("$p $s $f:$p-$s-$f-$v.png"); done; done
  python3 $A/sheet.py $O/3-shadows-sheet-$p-$v.png 4 0.2 "${args[@]}"
done; done
args=(); for v in vertical coverflow; do for s in S1 S2 S3; do args+=("dark $s $v:dark-$s-$v.png"); done; done
python3 $A/sheet.py $O/3-shadows-sheet-dark.png 3 0.2 "${args[@]}"
python3 $A/layers_preview.py $R $O/3-layers-sheet.png
python3 $A/contrast.py backdrops $R/1-backdrops > $O/contrast-panels.md
python3 $A/contrast.py fields > $O/contrast-card-field.md
du -sh $O; find $O -type f | wc -l
