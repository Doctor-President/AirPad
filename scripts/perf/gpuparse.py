import sys, xml.etree.ElementTree as ET, collections
path=sys.argv[1]; want=sys.argv[2] if len(sys.argv)>2 else 'AirPad'
ids={}
cols=None
tot=collections.defaultdict(int); frames=collections.defaultdict(set); cnt=collections.defaultdict(int)
tmin=None; tmax=None
def val(e):
    if e is None: return None
    r=e.get('ref')
    if r is not None: return ids.get(r)
    v=(e.get('fmt'), e.text, e)
    if e.get('id'): ids[e.get('id')]=v
    # register nested ids
    for c in e.iter():
        if c is not e and c.get('id'): ids[c.get('id')]=(c.get('fmt'), c.text, c)
    return v
for ev, el in ET.iterparse(path, events=('end',)):
    if el.tag=='schema':
        cols=[c.findtext('mnemonic') for c in el.findall('col')]
    elif el.tag=='row':
        vals=[val(c) for c in list(el)]
        row=dict(zip(cols, vals))
        proc=row.get('process'); pname=proc[0] if proc else ''
        ch=row.get('channel-name'); chn=ch[0] if ch else ''
        if want in (pname or ''):
            d=int(row['duration'][1]); s=int(row['start'][1])
            tot[chn]+=d; cnt[chn]+=1
            cb=row.get('cmdbuffer-id'); frames[chn].add(cb[1] if cb else None)
            tmin=s if tmin is None else min(tmin,s); tmax=s if tmax is None else max(tmax,s)
        el.clear()
span=(tmax-tmin)/1e9 if tmin else 0
print('span %.2fs'%span)
for k in tot: print('%-10s busy %.1f ms total, %d intervals, %d cmdbufs -> %.3f ms/cmdbuf, %.1f%% busy'%(k, tot[k]/1e6, cnt[k], len(frames[k]), tot[k]/1e6/max(1,len(frames[k])), 100*tot[k]/1e9/max(span,1e-9)))
