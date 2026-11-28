#!/usr/bin/env python3
"""Good Flow spike · round 2 (outcome 5): instrument Chrome's own ANGLE translation of the bench shader
(build/angle/angle_wrapped.metal, from angle_dump.mjs + angle_wrap.py: compiled fast / fast fp32 functions it reproduces
T's bench stills 120/120) so the three hash11 values of each pool are ALSO written to a device buffer, exactly as that
shader computed them while drawing. Output: build/angle/angle_pools.metal; the app's `-PoolsFromAngle <dir>` draws it
(GFPoolsAngle, GFMeasure.swift) and writes <dir>/angle-pools.json + the stills it drew (must still equal the reference)."""
import os, re
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, 'build/angle')
s = open(os.path.join(D, 'angle_wrapped.metal')).read()
s = s.replace('struct ANGLE_NonConstGlobals\n{\n', 'struct ANGLE_NonConstGlobals\n{\n  device float* gfDump;\n', 1)
n = 0
for var, k in (('ANGLE_s1266', 0), ('ANGLE_s126f', 1), ('ANGLE_s1281', 2)):
    line = re.search(r'\n(\s*)float %s = _uhash11\((\w+)\);\n' % var, s)
    assert line, var
    ind = line.group(1)
    s = s.replace(line.group(0), line.group(0) + f'{ind}ANGLE_nonConstGlobals.gfDump[_ui*3+{k}] = {var};\n', 1); n += 1
s = s.replace('fragment float4 gf_fragment(GFAVOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]]){',
              'fragment float4 gf_fragment(GFAVOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]], device float* gfDump [[buffer(1)]]){')
s = s.replace('  ANGLE_NonConstGlobals G;\n', '  ANGLE_NonConstGlobals G;\n  G.gfDump = gfDump;\n', 1)
open(os.path.join(D, 'angle_pools.metal'), 'w').write(s)
print('wrote', os.path.join(D, 'angle_pools.metal'), n, 'writes')
