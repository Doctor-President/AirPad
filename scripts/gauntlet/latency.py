#!/usr/bin/env python3
"""Brief CI-2 ruling 4 — where does a turn's time go?  `latency.py <label>=<glob of store-pass dirs> ... [--cases S1,1]`

Per case, medians over the matching passes:
  prompt_eval  tokens Ollama prefilled (Host `chat done … prompt_eval=`)
  ttft         first token (Host)              load   model load (Host)
  app          app-side overhead = the turn's wall time − the Host's own totalMs (retrieval, plan, facts, transport)
  sys / user / facts   system prompt chars, user-turn chars, COMPUTED FACTS chars (+ its date-line count)
Prefill is the model's cost per added token; `app` isolates the code's cost from the model's."""
import glob, json, os, re, statistics, sys
sys.path.insert(0, os.path.dirname(__file__))
import gauntlet as G


def host_totals(path):
    out = {}
    for line in open(path, errors="replace"):
        m = re.search(r"chat done req=(\S+) .*totalMs=(\d+)", line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cases = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--cases=")), ["S1", "1"])
    print("| set | case | n | prompt_eval | ttft ms | load ms | app ms | sys chars | user chars | facts chars | date lines |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for spec in args:
        label, pat = spec.split("=", 1)
        for case in cases:
            rows = []
            for pd in glob.glob(os.path.expanduser(pat)):
                if not os.path.isdir(pd) or not os.path.exists(os.path.join(pd, "store-rows.json")):
                    continue
                host = G.parse_host_log(os.path.join(pd, "host.log")); tot = host_totals(os.path.join(pd, "host.log"))
                for r in json.load(open(os.path.join(pd, "store-rows.json")))["rows"]:
                    if r["case"] != case:
                        continue
                    t = G.load_json(os.path.join(pd, f"turn-{r['seq']:03d}.json"), {})
                    tag = G.req_tag(t.get("requestID", "")); h = host.get(tag, {})
                    uc = t.get("userContent") or ""
                    fx = uc[uc.find("COMPUTED FACTS"):uc.find("\nQuestion:")] if "COMPUTED FACTS" in uc else ""
                    rows.append(dict(pe=h.get("prompt_eval"), tt=h.get("ttftMs"), ld=h.get("loadMs"),
                                     app=(r["elapsedSec"] * 1000 - tot[tag]) if tag in tot else None,
                                     sys=len(t.get("systemPrompt") or ""), user=len(uc), facts=len(fx),
                                     dates=len(re.findall(r"\[\d+\] [^\n]*? — written ", fx))))
            if not rows:
                continue
            med = lambda k: (round(statistics.median([x[k] for x in rows if x[k] is not None]))
                             if any(x[k] is not None for x in rows) else "—")
            print(f"| {label} | {case} | {len(rows)} | {med('pe')} | {med('tt')} | {med('ld')} | {med('app')} | "
                  f"{med('sys')} | {med('user')} | {med('facts')} | {med('dates')} |")


if __name__ == "__main__":
    main()
