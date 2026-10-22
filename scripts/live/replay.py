#!/usr/bin/env python3
# live-32 — replay one recorded request (a -WebTrace step's messages, as JSON) to a server model N times per variant and
# count self-corrections in the answer ("wait", "actually,", "let me fix…") and whether it names the current holder.
#   LIVE_SERVER=http://<lm-studio>:1234 [LIVE_MODEL=…] replay.py <messages.json> <off|on|plan|ambig|cool|ambigcool> <n>
# off = reasoning_effort "none" (what the app sends); on = the model's default (thinking); cool = + temperature 0.3.
# At most 2 at once: T's server shares an 8,192-token context across its parallel slots (3 at once: "Context size has
# been exceeded").
import os,json,sys,time,re,urllib.request,urllib.error,concurrent.futures as cf
msgs=json.load(open(sys.argv[1])); variant=sys.argv[2]; n=int(sys.argv[3])
extra={"ambig": " When a list or table request could be read two ways (a person who held the office twice, say), say in one short sentence how you read it, then write the list once, in order, without second-guessing it.", "plan": " PLAN FIRST: work out the whole answer before you write it, then write it once, in order. A table or list is complete when you write it; if something is missing, include it silently — never write 'wait', 'actually', 'let me fix that' or a second version."}
def one(i):
    m=json.loads(json.dumps(msgs))
    body={"model":os.environ.get("LIVE_MODEL","qwen/qwen3.5-9b"),"stream":False,"messages":m}
    if variant in ("off","plan","ambig","cool","ambigcool"): body["reasoning_effort"]="none"
    if variant=="plan": m[0]["content"]+=extra["plan"]
    if variant in ("ambig","ambigcool"):
        c=m[0]["content"]; k=c.find("\n\nWeb results the app found")
        m[0]["content"]=(c[:k]+extra["ambig"]+c[k:]) if k>0 and m[0]["role"]=="user" else c+extra["ambig"]
    if variant in ("cool","ambigcool"): body["temperature"]=0.3
    t=time.time()
    req=urllib.request.Request(os.environ["LIVE_SERVER"].rstrip("/")+"/v1/chat/completions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
    try: d=json.load(urllib.request.urlopen(req,timeout=300))
    except urllib.error.HTTPError as e: return dict(i=i,s=round(time.time()-t,1),leak=False,trump47=False,chars=0,reasoning=0,error=e.read()[:80].decode(errors="replace"))
    msg=d["choices"][0]["message"]; c=msg.get("content") or ""; r=msg.get("reasoning_content") or ""
    leak=bool(re.search(r"\b(wait|actually,|let me (fix|correct|expand|redo|re-?check)|hmm|i made an? (error|mistake)|oops)\b|\(wait",c,re.I))
    trump=bool(re.search(r"\b47\b[^\n]*trump|trump[^\n]*\b(2025|incumbent|present)",c,re.I))
    return dict(i=i,s=round(time.time()-t,1),leak=leak,trump47=trump,chars=len(c),reasoning=len(r))
with cf.ThreadPoolExecutor(2) as ex: res=list(ex.map(one,range(n)))
print(variant, "errors", sum(1 for x in res if x.get("error")), "leak", sum(x["leak"] for x in res),"/",n, "| trump current", sum(x["trump47"] for x in res),"/",n,
      "| s median", sorted(x["s"] for x in res)[n//2], "| reasoning ch median", sorted(x["reasoning"] for x in res)[n//2])
json.dump(res,open(f"{sys.argv[1]}.{variant}.json","w"))
