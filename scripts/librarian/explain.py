#!/usr/bin/env python3
"""Turn a Librarian recording (Settings > About > Librarian recorder; Mac Ctrl-Opt-Cmd-L, iPhone three-finger hold)
into plain language: one paragraph per turn saying what route answered, what the rules made of the question, which
entries were considered and at what score, what was cut and why, what was sent, what was cited, and how long it took.

  explain.py <librarian-*.json> [--turn N] [--detail] [--json]

The recording holds IDs, scores, counts and timings only (the question's words only if T switched that on), so it
is safe to read; still never copy entry names into Ops.
"""
import json, sys

ROUTES = {"apple": "Apple Intelligence (on this device)", "server": "your own server", "host": "AirPad Host", "local": "the on-device model"}


def load(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if d.get("kind") != "librarian":
        raise SystemExit(f"{path}: not a Librarian recording")
    return d


def short(i):
    i = i or "?"
    return i if len(i) <= 13 else i[:4] + ".." + i[-6:]


def summarise(t):
    """Numbers for one turn (a dict the benchmark and the failure catalogue reuse)."""
    passages = t.get("passages", [])
    cards = t.get("cards", [])
    sent = t.get("sent", [])
    cited = t.get("cited", [])
    cut = t.get("cutoffs", {})
    sent_nodes = {s.get("node") for s in sent}
    cited_nodes = {c.get("node") for c in cited if not c.get("web")}
    inline_nodes = {c.get("node") for c in cited if c.get("inline") and not c.get("web")}
    ans = t.get("answer", {})
    tok = t.get("tokens", {})
    pk = t.get("packet", {})
    scores = [p["score"] for p in passages]
    return {
        "seq": t.get("seq"), "turn": t.get("turn"), "mode": t.get("mode"), "route": t.get("route"), "model": t.get("model"),
        "served_model": t.get("servedModel"), "decision": t.get("decision") or t.get("generalTool"), "shape": t.get("shape"),
        "rules": [k for k, v in (t.get("rules") or {}).items() if v is True],
        "named_terms": (t.get("rules") or {}).get("namedTerms", 0),
        "passages_scored": len(passages), "passages_over_bar": sum(1 for p in passages if p.get("clearsBar")),
        "passage_top": max(scores) if scores else None, "passage_low": min(scores) if scores else None,
        "passage_floor": cut.get("passageFloor"), "card_floor": cut.get("cardFloor"),
        "cards_over_floor": t.get("cardsOverFloor", 0), "card_top": cards[0]["score"] if cards else None,
        "sent": len(sent), "sent_reads": sum(1 for s in sent if s.get("kind", "").startswith("read")),
        "sent_passages": sum(1 for s in sent if s.get("kind") == "passage"), "sent_cards": sum(1 for s in sent if s.get("kind") == "card"),
        "sent_entries": len(sent_nodes), "sent_low": min((s["score"] for s in sent if s.get("kind") != "read"), default=None),
        "packet_chars": pk.get("chars"), "est_tokens": pk.get("estTokens"), "window": pk.get("windowTokens"),
        "prompt_tokens": tok.get("prompt"), "answer_tokens": tok.get("answer"), "model_window": tok.get("modelWindow"),
        "chips": len(cited), "chips_inline": len(inline_nodes), "chips_by_rule": len(cited_nodes - inline_nodes),
        "sent_not_cited": len(sent_nodes - cited_nodes), "cited_not_sent": len(cited_nodes - sent_nodes) if sent else 0,
        "answer_chars": ans.get("chars"), "thinking_chars": ans.get("thinkingChars"),
        "first_token_ms": t.get("firstTokenMs"), "first_answer_ms": t.get("firstAnswerMs"), "retrieved_ms": t.get("retrievedMs"),
        "sent_ms": t.get("sentMs"), "total_ms": t.get("totalMs"),
        "flags": [k for k in ("declined", "titleFallback", "absenceGuardFired", "generalKnowledgeLine", "datedLine",
                              "unconfirmedLine", "saysResultsDontAnswer", "stopped") if ans.get(k)],
        "failed": bool(t.get("failed")), "carry": t.get("carryCheck"), "offers": t.get("offers"),
        "question": t.get("question"), "question_words": t.get("questionWords"),
    }


def secs(ms):
    return "?" if ms is None else f"{ms / 1000:.1f} s"


def sentence(t):
    s = summarise(t)
    out = []
    who = ROUTES.get(s["route"], s["route"] or "?")
    model = s["served_model"] or s["model"]
    head = f"Turn {s['seq']} ({s['mode']} mode, {who}" + (f", {model}" if model and model != "?" else "") + ")"
    if s["question"]:
        head += f': "{s["question"]}"'
    else:
        head += f": a {s['question_words']}-word question"
    out.append(head + ".")
    if s["rules"]:
        out.append("The app's phrase rules flagged it as: " + ", ".join(s["rules"]) + (f" (names {s['named_terms']} thing(s))" if s["named_terms"] else "") + ".")
    if s["mode"] == "library":
        if s["passages_scored"]:
            out.append(f"Search scored {s['passages_scored']} passages from {s['passage_low']:.2f} to {s['passage_top']:.2f}; "
                       f"{s['passages_over_bar']} cleared the {s['passage_floor']} bar. "
                       f"{s['cards_over_floor']} entry summaries cleared the {s['card_floor']} bar"
                       + (f" (best {s['card_top']:.2f})." if s["card_top"] is not None else "."))
        d = s["decision"] or "?"
        why = {"survey": "No single entry stood out, so it sent a survey", "empty": "Nothing cleared a bar, so it took the no-match path",
               "none(subject)": "Nothing in this place names what was asked about, so the app answered itself (no model call)"}.get(d)
        if why is None:
            why = f"It chose to read ({d})"
        out.append(f"{why}: {s['sent_reads']} read in full, {s['sent_passages']} passages, {s['sent_cards']} one-line summaries "
                   f"from {s['sent_entries']} entries" + (f", the weakest scored {s['sent_low']:.2f}" if s["sent_low"] is not None else "")
                   + (f"; {s['packet_chars']:,} characters" if s["packet_chars"] else "") + ".")
        if s["carry"]:
            c = s["carry"]
            out.append(f"An entry was open from the turn before: its best passage scored {c['openBest']:.2f} against {c['otherBest']:.2f} "
                       f"for anything else ({'kept open' if c['stillRelevant'] or c['deictic'] else 'let go'}).")
    else:
        out.append(f"General path: {s['decision'] or 'plain answer'}.")
    if s["failed"]:
        out.append("The request failed before an answer.")
    elif s["answer_chars"] is not None:
        tok = ""
        if s["prompt_tokens"] and s["prompt_tokens"] > 0:
            tok = f" The model read {s['prompt_tokens']:,} tokens" + (f" and wrote {s['answer_tokens']:,}" if (s["answer_tokens"] or 0) > 0 else "") \
                + (f" (its window is {s['model_window']:,})" if s["model_window"] else "") + "."
        out.append(f"The answer is {s['answer_chars']:,} characters; first word after {secs(s['first_answer_ms'] or s['first_token_ms'])}, "
                   f"done in {secs(s['total_ms'])}." + tok)
        if s["sent"]:
            out.append(f"It shows {s['chips']} source chip(s): {s['chips_inline']} the answer cited itself, {s['chips_by_rule']} attached by a rule "
                       f"(read in full, or named by title). {s['sent_not_cited']} of the {s['sent_entries']} entries sent were not cited.")
        if s["flags"]:
            out.append("Flags: " + ", ".join(s["flags"]) + ".")
    return " ".join(out)


def detail(t):
    lines = []
    cut = t.get("cutoffs", {})
    if cut:
        lines.append("  cut-offs: " + ", ".join(f"{k}={v}" for k, v in sorted(cut.items())))
    for p in t.get("passages", []):
        lines.append(f"  passage  {short(p['node'])}  {p['score']:.3f}  {'over' if p.get('clearsBar') else 'under'} the bar")
    for c in t.get("cards", []):
        lines.append(f"  summary  {short(c['node'])}  {c['score']:.3f}")
    for r in t.get("ranking", []):
        lines.append(f"  entry    {short(r['node'])}  sum {r['aggregate']:.2f}  top {r['top']:.2f}  x{r['count']}")
    cited = {c.get("node"): c for c in t.get("cited", [])}
    for s in t.get("sent", []):
        c = cited.get(s.get("node"))
        mark = "cited inline" if c and c.get("inline") else ("chip by rule" if c else "not cited")
        lines.append(f"  sent [{s['n']}] {s['kind']:<12} {short(s['node'])}  {s['score']:.3f}  {s['chars']:>6} chars  {s['origin']:<7} {mark}")
    return "\n".join(lines)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    d = load(args[0])
    only = int(sys.argv[sys.argv.index("--turn") + 1]) if "--turn" in sys.argv else None
    if only is not None:
        args = [a for a in args if a != str(only)] or args
    turns = [t for t in d.get("turns", []) if only is None or t.get("seq") == only]
    if "--json" in sys.argv:
        print(json.dumps([summarise(t) for t in turns], indent=1))
        sys.exit(0)
    dev = d.get("device", {})
    print(f"Librarian recording, {d.get('saved')}, AirPad {dev.get('app')} on {'Mac' if dev.get('mac') else 'iPhone/iPad'}; "
          f"{len(d.get('turns', []))} turn(s); question text {'included' if d.get('includesQuestion') else 'not included'}.\n")
    for t in turns:
        print(sentence(t))
        if "--detail" in sys.argv:
            print(detail(t))
        print()
