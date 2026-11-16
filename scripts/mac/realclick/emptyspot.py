# emptyspot.py <png of the window at (0,60)> <card cx> <card cy> → screen x y of a 40-pt block of plain Map ground
# (lowest pixel variance in the Map column, ≥ 300 pt from the card's centre, clear of the window's edges)
import sys
from PIL import Image
import numpy as np
im=np.asarray(Image.open(sys.argv[1]).convert('L'),dtype=float); cx,cy=float(sys.argv[2]),float(sys.argv[3])
best=None
for y in range(160,820,20):
    for x in range(260,940,20):
        if ((x-cx)**2+((y+60)-cy)**2)**0.5 < 300: continue
        b=im[y*2:(y+40)*2, x*2:(x+40)*2]
        v=b.std()
        if best is None or v<best[0]: best=(v,x+20,y+20+60)
print(best[1],best[2])
