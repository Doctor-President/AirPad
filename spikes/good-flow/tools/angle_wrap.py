#!/usr/bin/env python3
"""Good Flow spike · wrap Chrome's ANGLE translation (build/angle/translated.txt, from tools/angle_dump.mjs) so the app
can draw it from GFUniforms: drops ANGLE's main0, makes its uniform reference thread-space, adds gf_vertex/gf_fragment.
Diagnostic only (`-ShaderVariant angle-…`, read from the app's Documents/angle_wrapped.metal). Output: build/angle/."""
import os, re
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, 'build/angle')
s = open(os.path.join(D, 'translated.txt')).read().split('\n', 1)[1]
i = s.index('fragment ANGLE_FragmentOut main0(')
j = s.index('void ANGLE_initGlobals(thread ANGLE_NonConstGlobals & ANGLE_nonConstGlobals)\n{')
s = s[:i] + s[j:]
s = s.replace('constant ANGLE_UserUniforms & ANGLE_userUniforms', 'thread ANGLE_UserUniforms & ANGLE_userUniforms')
hdr = open(os.path.join(ROOT, 'App/GFShared.h')).read()
gf = set(re.findall(r'\b([a-zA-Z0-9]+)\b', hdr.split('typedef struct {')[1].split('} GFUniforms')[0]))
names = re.findall(r'_uu(\w+);', s[s.index('struct ANGLE_UserUniforms'):s.index('struct ANGLE_FragmentOut')])
lines = []
for f in names:
    if f in ('SheetA', 'SheetB'):
        continue
    g = f[0].lower() + f[1:]
    lines.append(f'  U._uu{f} = u.{g};' if g in gf else f'  U._uu{f} = 0;  // not read by the Flow path')
old = '  float ANGLE_sf8d = (_un * 127.099998f);'
if old in s:   # the same diagnostic snap as GoodFlow.metal's GF_QHASH
    s = s.replace(old, '#ifdef GF_QHASH\n  _un = metal::rint(_un*1024.0f)/1024.0f;\n#endif\n' + old)
s = s.replace('#include <metal_stdlib>', '#include <metal_stdlib>\n#include "GFShared.h"\nusing namespace metal;', 1)
s += '''
struct GFAVOut { float4 pos [[position]]; };
vertex GFAVOut gf_vertex(uint vid [[vertex_id]]){ float2 a = float2(vid == 1 ? 3. : -1., vid == 2 ? 3. : -1.); GFAVOut o; o.pos = float4(a, 0., 1.); return o; }
fragment float4 gf_fragment(GFAVOut vin [[stage_in]], constant GFUniforms& u [[buffer(0)]]){
  ANGLE_UserUniforms U;
%s
  U._uuOrg = float2(0.);
  ANGLE_NonConstGlobals G;
  G.ANGLE_flippedFragCoord = vin.pos;
  G.ANGLE_flippedFragCoord.y = u.res.y - vin.pos.y;   // GL's y-up gl_FragCoord
  ANGLE_FragmentOut O;
  ANGLE__0_main(O, U, G);
  return O._uo;
}
''' % '\n'.join(lines)
open(os.path.join(D, 'angle_wrapped.metal'), 'w').write(s)
print('wrote', os.path.join(D, 'angle_wrapped.metal'))
