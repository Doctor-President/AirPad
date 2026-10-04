#!/usr/bin/env python3
"""Brief CH-0 — Gauntlet v2: planner, grader, and grader self-test ("test the tests").

The Librarian gate. The app's DEBUG render tap writes `turn-NNN.json` (wire request, plan, raw deltas,
every displayed answer frame, committed answer + chips + Thought process); the XCUITest
(`AirPadUITests/LibrarianGauntletV2.swift`) writes `ui-<row>.json` (what was ON SCREEN). This script
grades each row from both, cross-checked against the Host `--observe` log and Ollama's `/api/ps`.

  plan     — expand cases.json × thinking × runs into the UI test's config + the expectations file
  grade    — grade a run dir → grades.json + table.md (validity first: an invalid row ABORTS, never passes)
  selftest — grade the KNOWN-BAD corpus and prove every grader goes RED on at least one item, and the
             known-GOOD control stays green (a grader that passes a known-bad item is broken)
  emit-md  — render the case list as markdown (the Ops doc is generated, never hand-kept)

Grader IDs (every row is graded by every applicable grader):
  V*  run validity — any miss = ABORT (the row is invalid, never "pass")
  F*  the whole STREAM (every frame the answer body displayed)
  A*  the final answer as SHOWN
  C*  citations end to end
  T*/H*  thinking channel + history hygiene
  I*  the BU2 invariants (carried over)
  R1  repeat — a case passes only 3/3 (intermittent = FAIL), aggregated in the table
  CC  CC's read of every answer (verdicts.json) — a row passes only when graders AND CC agree
"""
import argparse, datetime, difflib, glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))

GRADERS = {
    "V0": "turn completed + on-screen capture present",
    "V1": "model that answered == model requested (app wire tag + Host `chat done model=`)",
    "V2": "digest of the answering model == expected (Ollama /api/ps during the turn)",
    "V3": "`think` the model received == requested (app wire + Host `chat→ollama think=`)",
    "V4": "grounded case retrieved a non-empty packet",
    "V5": "route == expected",
    "V6": "Ollama + Host versions recorded for the run",
    "V7": "cold-start setup really was cold (nothing resident before the turn)",
    "F1": "no displayed frame contains reasoning prose",
    "F2": "no displayed frame contains system-prompt text",
    "F3": "no displayed frame contains <think>/</think>/channel tokens",
    "F4": "nothing displayed was later retracted / moved into Thought process (stream-then-jump)",
    "A1": "answer not empty (and no error banner)",
    "A2": "no reasoning prose in the shown answer",
    "A3": "no system-prompt echo in the shown answer",
    "A4": "no <think>/channel tokens in the shown answer",
    "A5": "no refusal / forbidden phrase",
    "A6": "required facts present",
    "A7": "on-screen answer == the committed answer (capture/render agree)",
    "A8": "the app stayed responsive (main-thread stall ≤ 5 s; a hang the watchdog had to kill = FAIL)",
    "C1": "no bare E<n> entry labels",
    "C2": "a grounded answer cites >= 1 entry",
    "C3": "every entry the prose names has a chip for THAT entry; no [n] beside a title points elsewhere",
    "C4": "no chip for an entry the answer doesn't discuss",
    "C5": "every chip resolves to a packet entry; on-screen chips == committed chips",
    "T1": "Thinking OFF → no reasoning reached the Thought-process block or the thinking channel",
    "H1": "the history sent on a follow-up carries no reasoning / tags / system prompt",
    "I1": "INV-chip: a READ turn chips its read entry",
    "I2": "INV-receipt: a READ turn's receipt says it read in full",
    "I3": "INV-window: estimated tokens < window; Ollama did not truncate",
    "I4": "INV-budget: packet chars <= budget",
    "I5": "INV-bubble: a re-ask (Retry / offer) replaces the turn, never duplicates it",
    "I6": "INV-carry: a follow-up keeps the SAME entry open",
    "I7": "survey shape: cards/passages within caps",
    "R1": "repeat: 3/3 runs pass (aggregate)",
}

# Reasoning prose — TIGHT. A clean answer addressed to the user never narrates these. (Kept narrow on
# purpose: a false FAIL costs as much as a false PASS — CLAUDE.md BU rule.)
REASONING = [
    "we are given", "we are done", "the user asked", "the user is asking", "the user wants",
    "the user just asked", "the user's question", "okay, the user", "first, the user", "the user has",
    "let me reconsider", "let me think", "let me check", "let me re-read", "let me look at",
    "let me parse", "let me make sure", "let me see", "but wait", "wait, ", "hmm,", "chain of thought",
    "the system prompt", "the instructions say", "according to the instructions", "i need to answer",
    "i need to make sure", "i need to figure out", "i should check", "i should make sure",
    "we don't have the full text", "the packet", "okay, let's", "alright, let's", "now, let's",
    "so the answer is", "i'll structure", "draft:", "final answer:", "double-check",
]
TOKENS = ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|channel|>", "<|message|>", "<|start|>",
          "<|end|>", "<|assistant|>", "<|user|>", "<|system|>", "<start_of_turn>", "<end_of_turn>",
          "[inst]", "<|endoftext|>", "<|eot_id|>"]
MARKER_RE = re.compile(r"\[\d+\]|\[\d*$")
SUPERSCRIPTS = "⁰¹²³⁴⁵⁶⁷⁸⁹"


# ─────────────────────────── text helpers ───────────────────────────

def norm_ws(s):
    return re.sub(r"\s+", " ", s or "").strip()

def strip_markers(s):
    s = MARKER_RE.sub("", s or "")
    return s.translate({ord(c): None for c in SUPERSCRIPTS})

def norm_cmp(s):
    """For comparing two renderings of the same answer: drop citation markers, markdown punctuation,
    whitespace differences."""
    s = strip_markers(s)
    s = re.sub(r"[*_`#>|~]", "", s)
    s = re.sub(r"^\s*[-•]\s+", "", s, flags=re.M)
    return norm_ws(s).lower()

def title_norm(s):
    s = "".join(ch if ch.isalnum() else " " for ch in (s or "").lower())
    return " ".join(s.split())

def title_main(title):
    return re.split(r"[:—·]", title or "")[0]

def title_mentioned(title, text):
    """Mirror of ChatSession.titleMentioned — the main part of a title, normalized, ≥4 chars."""
    needle = title_norm(title_main(title))
    if len(needle) < 4:
        return False
    return needle in title_norm(text)

STOP = set("about above after again against their there these those which while would could should being other through between where what when with from into that this have your yours they them were will also than then just like only some such very more most much many each idea ideas entry entries note notes".split())

def content_tokens(s):
    """Content words, stemmed to a 5-char prefix (relational ~ relationships)."""
    return {w[:5] for w in re.findall(r"[a-z]{4,}", (s or "").lower()) if w not in STOP}

def hits(text, needles):
    low = (text or "").lower()
    return [n for n in needles if n in low]

def sysprompt_echo(text, sysprompt):
    """Any CLAUSE of the system prompt (split at sentence/clause punctuation and dashes), ≥40 chars,
    appearing verbatim (case/whitespace-insensitive) in `text`. Clause-level on purpose: the Librarian's
    system prompt is ONE 2,300-char line, so a whole-line match could never fire (found by CH-0's
    test-the-tests pass)."""
    if not text or not sysprompt:
        return None
    hay = norm_ws(text).lower()
    for frag in re.split(r"(?<=[.;:!?])\s+|\s+[—–]\s+|\s+\(|\)\s+", sysprompt):
        f = norm_ws(frag).lower().rstrip(".;:")
        if len(f) >= 40 and f in hay:
            return f[:48]
    return None


# ─────────────────────────── logs ───────────────────────────

def parse_host_log(path):
    """→ {reqTag: {"model":…, "think":…, "truncated":…, "loadMs":…, "ttftMs":…, "eval":…, "prompt_eval":…}}"""
    out, pending = {}, None
    if not path or not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        m = re.search(r"chat/e2e reqID=(\S+)", line)
        if m:
            pending = m.group(1)
            out.setdefault(pending, {})
            continue
        m = re.search(r"chat→ollama .*think=(\S+)", line)
        if m and pending:
            out[pending]["think"] = m.group(1)
            continue
        m = re.search(r"chat done req=(\S+) model=(\S+) .*?prompt_eval=(\d+) eval=(\d+) truncated=(\w+) loadMs=(\d+) ttftMs=(\d+)", line)
        if m:
            d = out.setdefault(m.group(1), {})
            d.update(model=m.group(2), prompt_eval=int(m.group(3)), eval=int(m.group(4)),
                     truncated=m.group(5) == "true", loadMs=int(m.group(6)), ttftMs=int(m.group(7)))
    return out

def req_tag(request_id):
    if not request_id:
        return "absent"
    return request_id[:8] + "…" if len(request_id) > 8 else request_id

def parse_ps_log(path):
    """ps.log lines: `<epoch>\t<name>@<digest>,<name>@<digest>` (empty list = nothing loaded)."""
    rows = []
    if not path or not os.path.exists(path):
        return rows
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0]:
            continue
        try:
            ts = float(parts[0])
        except ValueError:
            continue
        loaded = [x.split("@", 1) for x in (parts[1].split(",") if len(parts) > 1 and parts[1] else [])]
        rows.append((ts, [(a, b) for a, b in loaded]))
    return rows

def iso_epoch(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


# ─────────────────────────── grading ───────────────────────────

def grade_row(exp, turn, ui, prev_turn, host, ps, versions, cases_meta):
    """→ dict(results={grader: (status, detail)}, stats={…}). status ∈ PASS | FAIL | ABORT | N/A."""
    R = {}
    def res(g, ok, detail="", abort=False):
        R[g] = ("PASS" if ok else ("ABORT" if abort else "FAIL"), detail)
    def na(g, why=""):
        R[g] = ("N/A", why)

    replay = exp.get("replay")
    stats = {}
    # ── V0 completion / capture
    if ui and str(ui.get("driverNote", "")).startswith("APP HUNG"):
        # A product failure, not an invalid run: T would be looking at a frozen app.
        res("A8", False, ui["driverNote"])
        return {"results": R, "stats": stats}
    if (not turn or not ui or not ui.get("turnCompleted", False) or ui.get("driverNote")
            or (norm_ws(turn.get("finalText")) and ui.get("onScreenAnswer") is None)):
        res("V0", False, f"turn={'yes' if turn else 'MISSING'} ui={'yes' if ui else 'MISSING'} "
                         f"completed={ui.get('turnCompleted') if ui else None} note={ui.get('driverNote') if ui else ''}",
            abort=True)
        return {"results": R, "stats": stats}
    res("V0", True, "")

    plan = turn.get("plan") or {}
    final = turn.get("finalText") or ""
    shown = ui.get("onScreenAnswer") or ""
    sysprompt = turn.get("systemPrompt") or ""
    thinking = turn.get("thinking") or ""
    frames = [f.get("s", "") for f in turn.get("frames", [])]
    raw = turn.get("raw", [])
    cites = turn.get("citations") or []
    cand = plan.get("candidates") or []
    route = plan.get("mode") or "(none)"
    tag = req_tag(turn.get("requestID", ""))
    h = host.get(tag, {})
    stats.update(route=route, chips=len(cites), frames=len(frames), thinkingChars=len(thinking),
                 answerChars=len(final), elapsedMs=turn.get("elapsedMs"), loadMs=h.get("loadMs"),
                 ttftMs=h.get("ttftMs"), evalTokens=h.get("eval"), modelAnswered=h.get("model"))

    # ── V1 model
    want_model = "replay" if replay else exp["model"]
    app_model = turn.get("modelRequested")
    if replay:
        res("V1", app_model == "replay", f"app={app_model}", abort=True)
    else:
        host_model = h.get("model")
        res("V1", app_model == want_model and host_model == want_model,
            f"requested={want_model} app-wire={app_model} host-answered={host_model}", abort=True)
    # ── V2 digest
    if replay:
        na("V2", "replay")
    else:
        t0 = iso_epoch(turn.get("startedAt", "")) or 0
        t1 = t0 + (turn.get("elapsedMs") or 0) / 1000 + 5
        seen = {d for ts, loaded in ps if t0 - 2 <= ts <= t1 for n, d in loaded if n == want_model}
        exp_d = exp.get("digest", "")
        ok = bool(seen) and all(d.startswith(exp_d) for d in seen) and bool(exp_d)
        res("V2", ok, f"expected={exp_d[:12] or '(none)'} seen={sorted(x[:12] for x in seen) or 'model not resident during turn'}", abort=True)
    # ── V3 think
    want_think = exp["think"]
    app_think = turn.get("think")
    if replay:
        res("V3", app_think == want_think, f"requested={want_think} app-wire={app_think}", abort=True)
    else:
        host_think = h.get("think")
        res("V3", app_think == want_think and host_think == str(want_think).lower(),
            f"requested={want_think} app-wire={app_think} host-sent={host_think}", abort=True)
    # ── V4 grounded retrieval
    if exp.get("expectRoute") in ("read", "survey"):
        res("V4", len(cand) > 0, f"packet entries={len(cand)}", abort=True)
    else:
        na("V4", "not a grounded case")
    # ── V5 route
    if exp.get("expectRoute"):
        res("V5", route == exp["expectRoute"], f"route={route} expected={exp['expectRoute']}", abort=True)
    else:
        na("V5", "route-agnostic case")
    # ── V6 versions
    res("V6", bool(versions.get("ollama")) and bool(versions.get("host") or replay),
        f"ollama={versions.get('ollama')} host={versions.get('host')}", abort=True)
    # ── V7 cold
    if exp.get("cold") and not replay:
        ej = ui.get("ejectedAtEpoch")
        t0 = iso_epoch(turn.get("startedAt", "")) or 0
        between = [loaded for ts, loaded in ps if ej and ej + 1 <= ts <= t0]
        res("V7", bool(ej) and any(not l for l in between),
            f"ejected={'yes' if ej else 'NO'} empty-samples-before-turn={sum(1 for l in between if not l)}/{len(between)}",
            abort=True)
    else:
        na("V7")

    # ── F* stream
    fr = [(i, f, hits(f, REASONING)) for i, f in enumerate(frames)]
    bad = [(i, hs) for i, f, hs in fr if hs]
    res("F1", not bad, f"first reasoning frame #{bad[0][0]}: {bad[0][1][:3]}" if bad else f"{len(frames)} frames clean")
    sp = [(i, sysprompt_echo(f, sysprompt)) for i, f in enumerate(frames)]
    sp = [(i, s) for i, s in sp if s]
    res("F2", not sp, f"frame #{sp[0][0]} shows system prompt: \"{sp[0][1]}…\"" if sp else "")
    tk = [(i, hits(f, TOKENS)) for i, f in enumerate(frames)]
    tk = [(i, t) for i, t in tk if t]
    res("F3", not tk, f"frame #{tk[0][0]} shows {tk[0][1]}" if tk else "")
    fin_n = norm_cmp(final)
    retract = None
    for i, f in enumerate(frames):
        fn = norm_cmp(f)
        if fn and not fin_n.startswith(fn):
            # the divergence: displayed text the final answer doesn't continue. Keep the LARGEST.
            k = 0
            while k < min(len(fn), len(fin_n)) and fn[k] == fin_n[k]:
                k += 1
            if retract is None or len(fn) - k > retract[3]:
                gone = fn[k:k + 160]
                where = "moved into Thought process" if gone[:40] and gone[:40] in norm_cmp(thinking) else "retracted"
                retract = (i, where, gone[:90], len(fn) - k)
    res("F4", retract is None,
        f"frame #{retract[0]}: {retract[3]} displayed chars later {retract[1]}: \"{retract[2]}…\"" if retract else "")

    # ── A* final answer as shown (graded on BOTH the on-screen text and the committed text)
    both = shown + "\n" + final
    banner = ui.get("errorBanner") or bool(turn.get("lastError"))
    res("A1", bool(norm_ws(shown)) and bool(norm_ws(final)) and not banner,
        f"shown={len(shown)} committed={len(final)} banner={banner} err={turn.get('lastError')}")
    a2 = hits(both, REASONING)
    res("A2", not a2, f"reasoning markers {a2[:4]}" if a2 else "")
    a3 = sysprompt_echo(both, sysprompt)
    res("A3", not a3, f"echoes \"{a3}…\"" if a3 else "")
    a4 = hits(both, TOKENS)
    res("A4", not a4, f"tokens {a4}" if a4 else "")
    forb = hits(both, cases_meta["refusals"] + exp.get("mustNotContain", []))
    res("A5", not forb, f"forbidden {forb}" if forb else "")
    facts = exp.get("mustContain") or []
    if facts and exp.get("minFacts", 0) > 0:
        low = both.lower()
        got = sum(1 for syns in facts if any(s.lower() in low for s in syns))
        res("A6", got >= exp["minFacts"], f"facts {got}/{exp['minFacts']} required")
    else:
        na("A6", "no required facts")
    if shown or final:
        # Letters only: the on-screen label joins blocks with ", ", renders [n] as bare superscript
        # digits and drops markdown — none of which is a content difference.
        letters = lambda x: re.sub(r"[^a-z]", "", (x or "").lower())
        ratio = difflib.SequenceMatcher(None, letters(shown), letters(final), autojunk=False).ratio()
        res("A7", ratio >= 0.9, f"similarity {ratio:.2f}")
    else:
        na("A7")

    gap = turn.get("maxMainThreadGapMs")
    if gap is not None:
        res("A8", gap <= 5000, f"longest main-thread stall {gap} ms")
    else:
        na("A8", "no heartbeat recorded")

    # ── C* citations
    c1 = re.findall(r"\bE\d+\b", both)
    res("C1", not c1, f"bare labels {sorted(set(c1))[:6]}" if c1 else "")
    grounded = route in ("read", "survey")
    if grounded and norm_ws(final):
        res("C2", len(cites) >= 1, f"{len(cites)} chips on a {route} answer")
    else:
        na("C2", "not a grounded answer")
    cite_by_idx = {c["index"]: c for c in cites}
    chip_nodes = {c.get("nodeID") for c in cites}
    named = [c for c in cand if c.get("title") and title_mentioned(c["title"], final)]
    c3 = []
    for c in named:
        if c.get("nodeID") not in chip_nodes:
            c3.append(f"names '{title_main(c['title'])[:30]}' but no chip for it")
    # [n] adjacent to a title must point at THAT title's entry (unless the cited entry is also named
    # in the same sentence — "X and Y [3]" where [3] = Y is fine).
    for sent in re.split(r"(?<=[.!?\n])\s+", final):
        sent_l = title_norm(sent)
        titled = [c for c in cand if c.get("title") and title_mentioned(c["title"], sent)]
        if not titled:
            continue
        for m in re.finditer(r"\[(\d+)\]", sent):
            n = int(m.group(1))
            target = cite_by_idx.get(n)
            if not target:
                continue
            tnode = target.get("nodeID")
            if any(c.get("nodeID") == tnode for c in titled):
                continue
            pre = sent[:m.start()]
            near = [c for c in titled if title_norm(title_main(c["title"])) in title_norm(pre[-120:])]
            if near:
                c3.append(f"'{title_main(near[-1]['title'])[:28]}' [{n}] → chip is '{target.get('title','')[:28]}'")
    res("C3", not c3, "; ".join(c3[:3]))
    always = set(plan.get("alwaysCite") or [])
    read_nodes = set(plan.get("readNodeIDs") or [])
    inline = {int(x) for x in re.findall(r"\[(\d+)\]", final)}
    # "Discussed" = named by title anywhere, OR read in full (always cited), OR a sentence that cites
    # its [n] actually talks about it (shares a title word, or ≥2 content words of its snippet). A bare
    # [n] on a sentence about something else is NOT discussion — that is the mis-citation family.
    sentences = re.split(r"(?<=[.!?\n])\s+", final)
    def discussed(c):
        if title_mentioned(c.get("title", ""), final) or c.get("nodeID") in read_nodes:
            return True
        tt, st = content_tokens(c.get("title", "")), content_tokens(c.get("snippet", ""))
        for sent in sentences:
            if f"[{c['index']}]" not in sent:
                continue
            ws = content_tokens(strip_markers(sent))
            if tt & ws or len(st & ws) >= 2:
                return True
        return False
    c4 = [c for c in cites if not discussed(c)]
    res("C4", not c4, "; ".join(f"chip [{c['index']}] '{c.get('title','')[:30]}' not discussed where cited" for c in c4[:3]))
    cand_nodes = {c.get("nodeID") for c in cand}
    outside = [c for c in cites if c.get("nodeID") and c.get("nodeID") not in cand_nodes]
    dedup_titles = []
    seen_nodes = set()
    for c in cites:
        key = c.get("nodeID") or c.get("url") or str(c["index"])
        if key not in seen_nodes:
            seen_nodes.add(key); dedup_titles.append(c.get("title", ""))
    screen_chips = ui.get("onScreenChips") or []
    mism = len(screen_chips) != len(dedup_titles) or any(t and t not in s for t, s in zip(dedup_titles, screen_chips))
    res("C5", not outside and not mism,
        ("chip outside packet: " + ", ".join(c.get("title", "")[:24] for c in outside) + "; " if outside else "")
        + (f"on-screen chips {len(screen_chips)} ≠ committed {len(dedup_titles)}" if mism else ""))
    stats.update(nativeMarkers=len(inline), titleRescue=bool(cites) and not inline and not (set(c["index"] for c in cites) <= always))

    # ── T1 thinking OFF honesty
    raw_think = sum(len(d.get("s", "")) for d in raw if d.get("ch") == "thinking")
    if not exp["think"]:
        res("T1", not thinking and raw_think == 0 and not ui.get("thoughtHeaderPresent"),
            f"Thinking OFF but thought-block={len(thinking)} chars, thinking-channel={raw_think} chars, header={'shown' if ui.get('thoughtHeaderPresent') else 'absent'}")
    else:
        na("T1", f"Thinking ON ({len(thinking)} chars of thought)")

    # ── H1 history hygiene
    hist = [m.get("content", "") for m in (turn.get("history") or []) if m.get("role") == "assistant"]
    if hist:
        hh = [x for x in hist if hits(x, REASONING) or hits(x, TOKENS) or sysprompt_echo(x, sysprompt)]
        res("H1", not hh, f"{len(hh)} prior assistant turn(s) carry reasoning/tags: {hits(hh[0], REASONING + TOKENS)[:3]}" if hh else f"{len(hist)} prior turns clean")
    else:
        na("H1", "first turn")

    # ── I* BU2 invariants
    if route == "read":
        missing = [n for n in plan.get("readNodeIDs", []) if n not in chip_nodes]
        res("I1", not missing, f"read entry not chipped ({len(missing)})")
        rec = turn.get("receipt") or ""
        res("I2", bool(plan.get("readNodeIDs")) and ("in full" in rec or "too long" in rec), f"receipt='{rec}'")
    else:
        na("I1"); na("I2")
    if plan:
        trunc = h.get("truncated")
        res("I3", plan.get("estTokens", 0) < plan.get("windowTokens", 1) and not trunc,
            f"estTok={plan.get('estTokens')} window={plan.get('windowTokens')} truncated={trunc}")
        res("I4", plan.get("packetChars", 0) <= plan.get("budgetChars", 0),
            f"packet={plan.get('packetChars')} budget={plan.get('budgetChars')}")
    else:
        na("I3"); na("I4")
    if exp.get("reask"):
        prev_hist = len((prev_turn or {}).get("history") or [])
        res("I5", prev_turn is not None and len(turn.get("history") or []) == prev_hist,
            f"history turns {prev_hist} → {len(turn.get('history') or [])}")
    else:
        na("I5")
    if exp.get("carriesEntry"):
        now = set(plan.get("readNodeIDs") or [])
        before = set(((prev_turn or {}).get("plan") or {}).get("readNodeIDs") or [])
        res("I6", bool(now) and bool(before) and now <= before, f"read {sorted(x[:8] for x in now)} vs open {sorted(x[:8] for x in before)}")
    else:
        na("I6")
    if route == "survey" and (exp.get("maxCards") or exp.get("maxPassages")):
        ok = plan.get("cardCount", 0) <= exp.get("maxCards", 99) and plan.get("passageCount", 0) <= exp.get("maxPassages", 99)
        res("I7", ok, f"cards={plan.get('cardCount')} passages={plan.get('passageCount')}")
    else:
        na("I7")
    return {"results": R, "stats": stats}


def row_status(g, verdict):
    vals = [s for s, _ in g["results"].values()]
    if "ABORT" in vals:
        return "INVALID"
    if "FAIL" in vals:
        return "FAIL"
    if verdict is None:
        return "PENDING-READ"
    return "PASS" if verdict.get("verdict") == "ok" else "FAIL"


def load_json(p, default=None):
    try:
        return json.load(open(p))
    except Exception:
        return default


def grade_dir(run_dir, quiet=False):
    exp = load_json(os.path.join(run_dir, "expected.json"), {})
    cases_meta = load_json(os.path.join(run_dir, "cases.json")) or load_json(os.path.join(HERE, "cases.json"))
    host = parse_host_log(os.path.join(run_dir, "host.log"))
    ps = parse_ps_log(os.path.join(run_dir, "ps.log"))
    versions = load_json(os.path.join(run_dir, "versions.json"), {})
    verdicts = load_json(os.path.join(run_dir, "verdicts.json"), {})
    turns = {}
    for p in glob.glob(os.path.join(run_dir, "turn-*.json")):
        t = load_json(p)
        if t:
            turns[t["seq"]] = t
    out = {}
    for row, e in exp.get("rows", {}).items():
        ui = load_json(os.path.join(run_dir, f"ui-{row}.json"))
        turn = turns.get(ui["seq"]) if ui else None
        # previous turn in the same CHAT (same app launch) — for carry / re-ask / history checks. For a
        # Retry row that is the forced-failure turn it replaces; for an offer it is the survey it re-asks.
        prev = None
        if turn and (turn.get("seq", 0) - 1) in turns and turns[turn["seq"] - 1].get("launchID") == turn.get("launchID"):
            prev = turns[turn["seq"] - 1]
        g = grade_row(e, turn, ui, prev, host, ps, versions, cases_meta)
        g["status"] = row_status(g, verdicts.get(row))
        g["verdict"] = verdicts.get(row)
        g["answer"] = (ui or {}).get("onScreenAnswer")
        out[row] = g
    json.dump(out, open(os.path.join(run_dir, "grades.json"), "w"), indent=2, ensure_ascii=False)
    write_table(run_dir, exp, out)
    return out


def write_table(run_dir, exp, out):
    lines = ["| row | case | think | status | route | chips (native/rescue) | TTFT | load | eval tok | think chars | red graders |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for row in sorted(out):
        g, e, s = out[row], exp["rows"][row], out[row]["stats"]
        reds = [f"{k}:{d}" for k, (st, d) in g["results"].items() if st in ("FAIL", "ABORT")]
        lines.append(f"| {row} | {e['case']} | {'on' if e['think'] else 'off'} | {g['status']} | {s.get('route','')} | "
                     f"{s.get('chips','')} ({s.get('nativeMarkers','')}/{'Y' if s.get('titleRescue') else 'n'}) | "
                     f"{s.get('ttftMs','')} | {s.get('loadMs','')} | {s.get('evalTokens','')} | {s.get('thinkingChars','')} | "
                     f"{'<br>'.join(reds) if reds else '—'} |")
    # R1 — aggregate (case × think) over runs: 3/3 or FAIL
    agg = {}
    for row, g in out.items():
        e = exp["rows"][row]
        agg.setdefault((e["case"], e["think"]), []).append(g["status"])
    lines += ["", "**R1 — repeat aggregate (pass = every run PASS):**", "",
              "| case | think | runs | aggregate |", "|---|---|---|---|"]
    for (c, t), sts in sorted(agg.items(), key=lambda x: (x[0][0], x[0][1])):
        a = "PASS" if all(s == "PASS" for s in sts) and len(sts) >= exp.get("runs", 3) else (
            "INVALID" if "INVALID" in sts else ("PENDING-READ" if set(sts) <= {"PASS", "PENDING-READ"} and len(sts) >= exp.get("runs", 3) else "FAIL"))
        lines.append(f"| {c} | {'on' if t else 'off'} | {' '.join(sts)} | {a} |")
    open(os.path.join(run_dir, "table.md"), "w").write("\n".join(lines) + "\n")


# ─────────────────────────── plan ───────────────────────────

def plan(cases_path, model, digest, thinks, runs, out_dir, base_args, only=None, replay_files=None, turn_timeout=900):
    cm = json.load(open(cases_path))
    os.makedirs(out_dir, exist_ok=True)
    json.dump(cm, open(os.path.join(out_dir, "cases.json"), "w"), indent=2, ensure_ascii=False)
    groups, rows = [], {}
    # Replay VARIANTS (`variant@chat[:case,case]=file`): several recorded scripts over the same chat in
    # one run — the known-bad corpus. Rows are named <case>.<think>.<variant>.
    variants = {k: v for k, v in (replay_files or {}).items() if "@" in k}
    for spec, rf in variants.items():
        vname, rest = spec.split("@", 1)
        chat_name, _, only_cases = rest.partition(":")
        chat = next(c for c in cm["chats"] if c["chat"] == chat_name)
        keep = set(filter(None, only_cases.split(",")))
        for think in thinks:
            cs = [c for c in chat["cases"] if not keep or c["id"] in keep]
            args = ["-DebugHostModel", model, "-GauntletThink", "YES" if think else "NO", "-GauntletReplay", rf] + chat.get("args", [])
            turns = []
            for i, c in enumerate(cs):
                row = f"{c['id']}.{'on' if think else 'off'}.{vname}"
                turns.append({"row": row, "case": c["id"], "action": c.get("action", "send"), "question": c["question"]})
                e = {k: v for k, v in c.items() if k not in ("what",)}
                if c.get("facts") == "panel":
                    e["mustContain"] = cm["panel"]
                e.update(case=c["id"], chat=chat["chat"], think=think, run=vname, model=model, digest=digest,
                         replay=True, firstInChat=(i == 0))
                rows[row] = e
            groups.append({"group": f"{vname}.{'on' if think else 'off'}", "args": args, "turns": turns, "eject": False})
    replay_files = {k: v for k, v in (replay_files or {}).items() if "@" not in k}
    for r in range(1, (runs if not variants else 0) + 1):
        for think in thinks:
            for chat in cm["chats"]:
                cs = [c for c in chat["cases"] if not only or c["id"] in only]
                if not cs:
                    continue
                gname = f"{chat['chat']}.{'on' if think else 'off'}.r{r}"
                args = ["-DebugHostModel", model, "-GauntletThink", "YES" if think else "NO"] + chat.get("args", [])
                rf = (replay_files or {}).get(chat["chat"])
                if rf:
                    args += ["-GauntletReplay", rf]
                turns = []
                for i, c in enumerate(cs):
                    row = f"{c['id']}.{'on' if think else 'off'}.r{r}"
                    turns.append({"row": row, "case": c["id"], "action": c.get("action", "send"), "question": c["question"]})
                    e = {k: v for k, v in c.items() if k not in ("what",)}
                    if c.get("facts") == "panel":
                        e["mustContain"] = cm["panel"]
                    e.update(case=c["id"], chat=chat["chat"], think=think, run=r, model=model, digest=digest,
                             replay=bool(rf), firstInChat=(i == 0))
                    rows[row] = e
                groups.append({"group": gname, "args": args, "turns": turns,
                               "eject": any(c.get("cold") for c in cs)})
    cfg = {"outDir": out_dir, "baseArgs": base_args, "turnTimeoutSec": turn_timeout, "groups": groups}
    json.dump(cfg, open(os.path.join(out_dir, "config.json"), "w"), indent=2, ensure_ascii=False)
    json.dump({"model": model, "digest": digest, "runs": runs, "rows": rows},
              open(os.path.join(out_dir, "expected.json"), "w"), indent=2, ensure_ascii=False)
    return cfg


# ─────────────────────────── self-test ───────────────────────────

def selftest(kb_dir):
    """Every known-bad row must be RED on each grader its manifest names; every known-GOOD row must be
    all-green (the positive control). And every grader in GRADERS must be proven RED by ≥1 item."""
    man = json.load(open(os.path.join(kb_dir, "manifest.json")))
    proven = {g: [] for g in GRADERS}
    problems, matrix = [], []
    for item in man["items"]:
        run_dir = os.path.join(kb_dir, item["runDir"])
        grades = grade_dir(run_dir, quiet=True)
        for row, want_red in item.get("expectRed", {}).items():
            g = grades.get(row)
            if not g:
                problems.append(f"{item['id']}: row {row} not graded (missing capture?)"); continue
            red = {k for k, (st, _) in g["results"].items() if st in ("FAIL", "ABORT")}
            for w in want_red:
                if w in red:
                    proven[w].append(item["id"])
                else:
                    st, d = g["results"].get(w, ("MISSING", ""))
                    problems.append(f"{item['id']} {row}: grader {w} should be RED but is {st} ({d})")
            matrix.append((item["id"], row, sorted(red), g["results"]))
        for row in item.get("expectGreen", []):
            g = grades.get(row)
            red = {k: d for k, (st, d) in (g or {"results": {}})["results"].items() if st in ("FAIL", "ABORT")}
            if not g or red:
                problems.append(f"{item['id']} {row}: positive control is not green: {red or 'not graded'}")
            matrix.append((item["id"], row, sorted(red), (g or {}).get("results", {})))
        # aggregate known-bad (R1): the item's rows as runs of one case must aggregate to FAIL
        if item.get("expectAggregateFail"):
            sts = [row_status(grades[r], {"verdict": "ok"}) for r in item["expectAggregateFail"] if r in grades]
            agg_pass = len(sts) == len(item["expectAggregateFail"]) and all(s == "PASS" for s in sts)
            if agg_pass:
                problems.append(f"{item['id']}: R1 aggregate PASSED a set with a red run ({sts})")
            else:
                proven["R1"].append(item["id"])
    unproven = [g for g, items in proven.items() if not items]
    return proven, unproven, problems, matrix


# ─────────────────────────── emit-md ───────────────────────────

def emit_md(cases_path):
    cm = json.load(open(cases_path))
    L = ["# Gauntlet v2 — case list (Brief CH-0)", "",
         "_Generated from `AirPad/scripts/gauntlet/cases.json` by `gauntlet.py emit-md` — edit the JSON, not this file._", "",
         "Every case runs **× Thinking {off, on}** (where the model supports it) **× 3 runs**; a case passes only **3/3**.",
         "One *chat* = one app launch = one fresh conversation; its cases run in order inside it (follow-ups, carries, re-asks).",
         "Every row is graded by every applicable grader below; the case only adds its own expectations.", "",
         "## Cases", "", "| # | kind | chat | question | expected route | case-specific checks |", "|---|---|---|---|---|---|"]
    for chat in cm["chats"]:
        for c in chat["cases"]:
            checks = []
            if c.get("facts") == "panel": checks.append(f"lab panel facts ≥{c['minFacts']}/7")
            elif c.get("mustContain"): checks.append(f"facts {c['mustContain']} ≥{c['minFacts']}")
            if c.get("carriesEntry"): checks.append("carries the open entry (I6)")
            if c.get("reask"): checks.append("re-ask replaces the turn (I5)")
            if c.get("maxCards"): checks.append(f"≤{c['maxCards']} cards / ≤{c['maxPassages']} passages (I7)")
            if c.get("cold"): checks.append("COLD: nothing resident before the turn (V7) — adversarial A4")
            if c.get("regression"): checks.append("regression rows: " + ", ".join(c["regression"]))
            if c.get("action", "send") != "send": checks.append(f"action: {c['action']}")
            if chat.get("args"): checks.append("launch: " + " ".join(chat["args"]))
            q = c["question"] or "(taps “Read it in full”)"
            L.append(f"| {c['id']} | {c['kind']} | {chat['chat']} | {q} | {c.get('expectRoute') or 'any'} | {'; '.join(checks) or '—'} |")
    L += ["", "**Regression rows (device-found bugs, 2026-10-03/04):** REG-leak, REG-bareE, REG-label, REG-jump all ride on **S1** "
          "(T's exact question) × Thinking OFF/ON × 3, graded by F1–F4, A2–A4, C1, C3, T1. A2 is the follow-up-history row; "
          "A3 the Retry row; case 1 doubles as A4 cold auto-load; A5 the near-context-limit packet.", "",
          "## Graders", "", "| id | checks | on a miss |", "|---|---|---|"]
    for g, d in GRADERS.items():
        L.append(f"| {g} | {d} | {'ABORT (row invalid)' if g.startswith('V') else ('FAIL the case' if g != 'R1' else 'FAIL the case (aggregate)')} |")
    L += ["| CC | CC reads every answer: one-line verdict + reason (wrong connection, fabricated fact, hedging, thin) | row passes only when graders AND CC agree |", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--cases", default=os.path.join(HERE, "cases.json"))
    p.add_argument("--model", required=True); p.add_argument("--digest", required=True)
    p.add_argument("--think", default="off,on"); p.add_argument("--runs", type=int, default=3)
    p.add_argument("--out", required=True); p.add_argument("--only", default="")
    p.add_argument("--replay", action="append", default=[], help="chat=/abs/replay.json")
    p.add_argument("--turn-timeout", type=int, default=900)
    p.add_argument("--base-args", required=True, help="JSON list")
    g = sub.add_parser("grade"); g.add_argument("run_dir")
    s = sub.add_parser("selftest"); s.add_argument("kb_dir")
    m = sub.add_parser("emit-md"); m.add_argument("--cases", default=os.path.join(HERE, "cases.json"))
    a = ap.parse_args()
    if a.cmd == "plan":
        thinks = [x == "on" for x in a.think.split(",") if x]
        reps = dict(x.split("=", 1) for x in a.replay)
        cfg = plan(a.cases, a.model, a.digest, thinks, a.runs, a.out, json.loads(a.base_args),
                   only=set(filter(None, a.only.split(","))), replay_files=reps, turn_timeout=a.turn_timeout)
        print(f"planned {sum(len(g['turns']) for g in cfg['groups'])} rows in {len(cfg['groups'])} launches → {a.out}/config.json")
    elif a.cmd == "grade":
        out = grade_dir(a.run_dir)
        print(open(os.path.join(a.run_dir, "table.md")).read())
    elif a.cmd == "selftest":
        proven, unproven, problems, matrix = selftest(a.kb_dir)
        for item, row, red, _ in matrix:
            print(f"{item:28s} {row:18s} RED={','.join(red) or '— (green)'}")
        print("\nGRADER → known-bad items that turn it RED:")
        for gid in GRADERS:
            print(f"  {gid}: {', '.join(sorted(set(proven[gid]))) or '*** NEVER RED — BROKEN ***'}")
        for pr in problems:
            print("PROBLEM:", pr)
        ok = not unproven and not problems
        print("\nSELFTEST", "PASS — every grader proven RED; positive control green" if ok else f"FAIL — unproven={unproven} problems={len(problems)}")
        sys.exit(0 if ok else 1)
    elif a.cmd == "emit-md":
        print(emit_md(a.cases))


if __name__ == "__main__":
    main()
