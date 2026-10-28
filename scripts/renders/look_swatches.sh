#!/bin/zsh
# pro-build — the Map look picker's swatches (Assets.xcassets/LookSwatches): the real app, Sample Library, one orb alone
# (`-MapSwatch`: the largest orb, pinned to #2F6FD6 and its nearest study family; `-MapNoTitles`), every look on both Maps
# at the shipped values (`-AppearanceTunerReset`), cropped around the detected orb to 132 px (44 pt @3x).
# Needs a DEBUG build installed on the Simulator. Usage: scripts/renders/look_swatches.sh [work_dir]
SIM=${SIM:-0CEF9A50-F6A1-4CEF-BCFF-624421778F76}; APP=com.doctorpresident.airpad
R=${0:A:h:h:h}; W=${1:-$R/build/swatches}; mkdir -p $W; cd $W
BASE=(-UITestLibrary -UITestSampleLibrary -EmbedCPUOnly -OpenMap -NoMapDebugHUD -AppearanceTuner YES -AppearanceTunerReset YES -MapSwatch -MapNoTitles -com.airpad.callouts.view.buttons YES -com.airpad.callouts.map.intro YES)
shot() { xcrun simctl ui $SIM appearance $2; xcrun simctl terminate $SIM $APP >/dev/null 2>&1
  xcrun simctl launch $SIM $APP $BASE -MapLookSet $3 >/dev/null 2>&1; sleep 27
  xcrun simctl io $SIM screenshot --type=png raw-$1.png >/dev/null 2>&1; echo $1; }
for l in flat glass aura eclipse riso gradient outline; do shot dark-$l dark $l; done
for l in flat glass aura riso gradient outline; do n=$l; [[ $l == aura ]] && n=wash; shot light-$n light $l; done
xcrun simctl ui $SIM appearance dark; xcrun simctl terminate $SIM $APP >/dev/null 2>&1
A=$R/AirPad/Assets.xcassets/LookSwatches python3 - <<'PY'
import numpy as np, json, os
from PIL import Image
A=os.environ['A']; os.makedirs(A,exist_ok=True)
json.dump({"info":{"author":"xcode","version":1},"properties":{"provides-namespace":False}},open(f'{A}/Contents.json','w'))
for g,ls in {'dark':['flat','glass','aura','eclipse','riso','gradient','outline'],'light':['flat','glass','wash','riso','gradient','outline']}.items():
    for l in ls:
        im=np.asarray(Image.open(f'raw-{g}-{l}.png').convert('RGB')).astype(float)
        H,W,_=im.shape; cy,cx=H//2,W//2; h=int(W*0.36); reg=im[cy-h:cy+h,cx-h:cx+h]
        ground=np.median(np.concatenate([q.reshape(-1,3) for q in (reg[:20,:20],reg[-20:,-20:],reg[:20,-20:],reg[-20:,:20])]),axis=0)
        ys,xs=np.nonzero(np.abs(reg-ground).max(axis=2)>22)
        y0,y1,x0,x1=np.percentile(ys,0.5),np.percentile(ys,99.5),np.percentile(xs,0.5),np.percentile(xs,99.5)
        oy,ox=(y0+y1)/2+cy-h,(x0+x1)/2+cx-h; s=int(max(y1-y0,x1-x0)/2*1.12)
        n=f'swatch-{g}-{l}'; os.makedirs(f'{A}/{n}.imageset',exist_ok=True)
        Image.fromarray(im[int(oy-s):int(oy+s),int(ox-s):int(ox+s)].astype(np.uint8)).resize((132,132),Image.LANCZOS).save(f'{A}/{n}.imageset/{n}.png')
        json.dump({"images":[{"filename":f"{n}.png","idiom":"universal","scale":"3x"}],"info":{"author":"xcode","version":1}},open(f'{A}/{n}.imageset/Contents.json','w'))
print('swatches written')
PY
