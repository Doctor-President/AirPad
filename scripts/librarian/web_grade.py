#!/usr/bin/env python3
"""Sweep 2a amendment — grade the web cases (benchmark/cases-web.json) on the DELIVERED answer, with the stage that failed.

  python3 scripts/librarian/web_grade.py <cases-web.json> <run-dir> [<run-dir> ...] [--md out.md] [--json out.json]

A run dir holds results.json (LibrarianBench rows) and webtrace.jsonl (the app's -WebTrace). Rules:
  news-top / news-followup   PASS = the answer names at least 3 actual stories (items carrying a specific name or number
                             that is in what the search returned), and never says it can't reach the web.
  news-topic                 PASS = at least 2 such items on the topic.
  capability                 PASS = not sent to search, and the answer doesn't deny a capability the app has.
Each FAIL names the stage: provider (what came back), filter (the relevance filter kept none / kept page furniture),
no-search (a follow-up answered from memory), searched-self (a question about the Librarian was web-searched), writer.
On the top-stories path (sweep 2b · 1d) the trace's plan row says how many articles survived the front/section drop:
fewer than 3 → "app: fewer than 3 articles after the drop"; else too few stories named → "writer: listed N < 3 of a K-article packet".
"""
import json, re, sys, os, math
from collections import defaultdict

OUTLETS = set("""ap associated press reuters bbc cnn nbc abc cbs npr fox guardian times york new washington post politico hill
bloomberg cnbc aljazeera jazeera al google news yahoo usnews youtube nyt wsj journal street wall axios telegraph independent
sky msnbc forbes verge wired today world latest breaking top stories story headlines update updates live video videos""".split())
GENERIC = set("""i i'm i’ll here there these those this that the a an and or but what which who when where why how yes yeah no
also plus meanwhile want would could should you your they their it its if in on at as by for from with about into than then
some many most more less other others one two three first second third key want let me my we our us can do does did is are was
were be been being have has had will just like well so not sure today's today tonight week month year recent recently
political politics climate tech technology health public economy economic global international national europe asia africa
america american americas middle east u.s us uk eu ai sources source""".split())
DENY = re.compile(r"(can(?:'|’)?t|cannot|can not|unable to|don(?:'|’)t have|do not have|no)\s+(?:\w+\s+){0,4}?(real[- ]time|access to (?:the )?(?:web|internet|today)|search(?:ing)? (?:the )?(?:web|internet)|browse|pull up|look (?:things )?up)", re.I)


def words(s):
    return re.findall(r"[A-Za-z0-9][A-Za-z0-9'’\-\.]*[A-Za-z0-9]|[A-Za-z0-9]", s)


def specifics(item):
    """Names and numbers an item commits to: capitalised words (not sentence-first generic words) and figures."""
    out = set()
    toks = words(re.sub(r"\[\d+\]|\*\*|^[\s\-\*\d\.\)]+", " ", item))
    for i, t in enumerate(toks):
        low = t.lower().strip(".")
        if low in OUTLETS or low in GENERIC or len(low) < 2:
            continue
        if re.search(r"\d", t) or (t[0].isupper() and (i > 0 or low not in GENERIC)):
            out.add(low)
    return out


def items(answer):
    parts = []
    for line in answer.split("\n"):
        line = line.strip()
        if not line:
            continue
        if re.match(r"^([\-\*•]|\d+[\.\)])\s+", line):
            parts.append(line)
        else:
            parts += [s for s in re.split(r"(?<=[\.\!\?\]])\s+(?=[A-Z\[])|,\s+(?=\[\d+\])|;\s+", line) if s.strip()]
    return parts


def load_trace(path):
    turns = defaultdict(list)
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            turns[r.get("turn", 0)].append(r)
    return [turns[k] for k in sorted(turns)]


def trace_facts(rows):
    f = {"searched": False, "links": 0, "kept": None, "passages": 0, "evidence": "", "titles": [], "query": "", "how": "",
         "provider": "", "promptTok": None, "hadResults": False, "frontPages": 0, "path": "", "articles": None, "dropped": None}
    for r in rows:
        k = r.get("kind")
        if k == "query":
            f["query"], f["how"] = r.get("query", ""), r.get("how", "")
        elif k == "plan":
            # the server route notes two plan rows (the prefetch decision, then the evidence path): keep the one with a path
            if r.get("path"):
                f["path"] = r["path"]
            if r.get("path") == "top-stories":   # sweep 2b · 1d: the top-stories packet's article count after the drop
                f["articles"], f["dropped"] = r.get("articles"), r.get("frontOrSection")
        elif k == "provider":
            f["provider"] = (f["provider"] + " " + r.get("name", "") + ":" + str(r.get("freshness", ""))).strip()
        elif k == "tool":
            f["searched"] = True
            f["links"] += len(r.get("links", []))
            for l in r.get("links", []):
                f["titles"].append(l.get("title", ""))
                f["evidence"] += " " + l.get("title", "") + " " + (l.get("snippet") or "")
                path = re.sub(r"^https?://[^/]+", "", l.get("url", "")).strip("/")
                if path.count("/") == 0 and len(path) < 25 and not re.search(r"\d{4}", path):
                    f["frontPages"] += 1
        elif k == "rerank":
            f["kept"], f["passages"] = r.get("kept"), len(r.get("passages", []))
        elif k == "applePrompt" or k == "model":
            f["promptTok"] = r.get("tokenCount", f["promptTok"])
            f["hadResults"] = f["hadResults"] or str(r.get("prompt", "")).startswith("Web results")
    return f


def grade_run(cases, run):
    res = json.load(open(os.path.join(run, "results.json"), encoding="utf-8"))
    trace = load_trace(os.path.join(run, "webtrace.jsonl"))
    spec = {t["id"]: t for c in cases["chats"] for t in c["turns"]}
    out, prev_evidence = [], {}
    for i, row in enumerate(res["rows"]):
        t = spec.get(row["id"], {})
        f = trace_facts(trace[i]) if i < len(trace) else trace_facts([])
        ans = row.get("answer", "")
        typ = t.get("type", "")
        ev = f["evidence"] if f["searched"] else prev_evidence.get(row.get("chat", ""), "")
        if f["searched"]:
            prev_evidence[row.get("chat", "")] = f["evidence"]
        evlow = set(w.lower().strip(".") for w in words(ev))
        named = [it for it in items(ans) if specifics(it) & evlow]
        if typ == "news-topic":
            topic = set(t.get("topic", []))
            named = [it for it in named if topic & set(w.lower() for w in words(it)) or len(specifics(it) & evlow) >= 2]
        denies = bool(DENY.search(ans))
        g = {"id": row["id"], "type": typ, "searched": f["searched"], "links": f["links"], "frontPages": f["frontPages"],
             "kept": f["kept"], "passages": f["passages"], "stories": len(named), "denies": denies, "chips": len(row.get("chips", [])),
             "sec": row.get("elapsedSec"), "how": f["how"], "provider": f["provider"], "answerChars": len(ans),
             "caption": row.get("provenanceCaption", ""), "unconfirmed": row.get("unconfirmedLine", False)}
        if not ans:
            g["verdict"], g["stage"] = "FAIL", "no answer (" + (row.get("error") or "?")[:40] + ")"
        elif typ in ("news-top", "news-followup", "news-topic"):
            need = 2 if typ == "news-topic" else 3
            if len(named) >= need and not denies:
                g["verdict"], g["stage"] = "PASS", ""
            elif f["path"] == "top-stories" and f["articles"] is not None and f["articles"] < 3:
                g["verdict"], g["stage"] = "FAIL", "app: fewer than 3 articles after the drop (%d results, %s front/section pages)" % (
                    f["links"], f["dropped"])
            elif f["path"] == "top-stories" and f["articles"]:
                g["verdict"], g["stage"] = "FAIL", "writer: listed %d < %d of a %d-article packet" % (len(named), need, f["articles"])
            elif typ == "news-followup" and not f["searched"]:
                g["verdict"], g["stage"] = "FAIL", "no-search: the follow-up was answered from the chat alone"
            elif f["searched"] and f["links"] == 0:
                g["verdict"], g["stage"] = "FAIL", "provider: nothing came back"
            elif f["searched"] and f["links"] and not f["kept"]:
                g["verdict"], g["stage"] = "FAIL", "filter: %d results came back, the relevance filter kept 0" % f["links"]
            elif f["searched"] and f["frontPages"] * 2 >= max(1, f["links"]):
                g["verdict"], g["stage"] = "FAIL", "provider: %d of %d results are front pages, not articles" % (f["frontPages"], f["links"])
            elif f["searched"]:
                g["verdict"], g["stage"] = "FAIL", "filter/packet: kept passages carry page furniture, not the stories"
            else:
                g["verdict"], g["stage"] = "FAIL", "no-search"
            if denies:
                g["stage"] += "; says it can't reach the web" + (" although the app searched" if f["searched"] else "")
        elif typ == "capability":
            if f["searched"]:
                g["verdict"], g["stage"] = "FAIL", "searched-self: the question about the Librarian was sent to web search"
            elif denies:
                g["verdict"], g["stage"] = "FAIL", "writer: denies a capability the app has"
            else:
                g["verdict"], g["stage"] = "PASS", ""
        else:
            g["verdict"], g["stage"] = "?", ""
        out.append(g)
    return out


def main():
    args = sys.argv[1:]
    md = js = None
    if "--md" in args:
        i = args.index("--md"); md = args[i + 1]; del args[i:i + 2]
    if "--json" in args:
        i = args.index("--json"); js = args[i + 1]; del args[i:i + 2]
    cases = json.load(open(args[0], encoding="utf-8"))
    lines, alljs = [], {}
    for run in args[1:]:
        g = grade_run(cases, run)
        alljs[os.path.basename(run.rstrip("/"))] = g
        n = sum(1 for x in g if x["verdict"] == "PASS")
        lines.append("### %s — %d/%d pass" % (os.path.basename(run.rstrip("/")), n, len(g)))
        lines.append("| id | type | verdict | results | front pages | kept by filter | stories named | s | stage that failed |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for x in g:
            lines.append("| %s | %s | %s | %s | %s | %s | %d | %s | %s |" % (
                x["id"], x["type"], x["verdict"], x["links"] if x["searched"] else "no search", x["frontPages"] if x["searched"] else "",
                ("%s of %s" % (x["kept"], x["passages"])) if x["kept"] is not None else "", x["stories"], x["sec"], x["stage"]))
        lines.append("")
    text = "\n".join(lines)
    print(text)
    if md:
        open(md, "w", encoding="utf-8").write(text + "\n")
    if js:
        json.dump(alljs, open(js, "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main()
