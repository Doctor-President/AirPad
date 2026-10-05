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
  W*  the Librarian's VOICE (Brief CH-A1b) — W1 fails the row; W2/W3 only FLAG it for CC's read
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
    "A6b": "every value the answer labels high/low/normal/out-of-range (or lower/upper end) matches the entry's OWN range",
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
    "W1": "voice: no sycophantic opener (\"Great question\", \"What a fascinating…\", \"I'd be happy to\")",
    "W2": "voice: question tic — FLAG the RUN when > 50% of its answers end with a question back to the user",
    "W3": "voice: length fit — FLAG a fact/read answer over ~120 words or a broad answer under ~60 (CC reads it)",
    "R1": "repeat: 3/3 runs pass (aggregate)",
}
# Brief CH-A1b — the voice graders are named W* (not the brief's V1–V3: V* is run validity and ABORTs).
FLAG_ONLY = {"W2", "W3"}   # a flag sends the row to CC's read; it never fails the row by itself


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
    """Mirror of ChatSession.titleMentioned — the main part of a title, normalized, ≥4 chars — EXCEPT a
    one-word main part ("Feature" of "Feature: Remote Connect") is too generic to count as naming the entry:
    then the whole title is required (found as a false C3 in CH-A A1)."""
    main = title_main(title)
    needle = title_norm(main if len(title_norm(main).split()) >= 2 or title_norm(main) == title_norm(title) else title)
    if len(needle) < 4:
        return False
    if len(needle.split()) == 1:
        # A one-word title ("Hallucinations") is also an ordinary word: it NAMES the entry only when styled as a
        # name — wrapped in * " ' “ ‘ or capitalised mid-sentence (CH-A: "depicts elaborate hallucinations"
        # was a false C3). Lowercase prose use is not a reference.
        w = re.escape(title.strip())
        return bool(re.search(rf"[*\"'“‘_]{w}|(?<=[a-z,;:] ){w}\b", text or ""))
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


# ── voice (Brief CH-A1b) ── narrow on purpose: a false FAIL costs as much as a false PASS.
SYCOPHANTIC_OPENERS = [
    r"(?:great|good|excellent|fantastic|wonderful|terrific|brilliant|lovely|fascinating|interesting) question",
    r"what (?:a|an) (?:great|fascinating|wonderful|interesting|intriguing|lovely|thoughtful|beautiful|delightful|rich|fun) ",
    r"(?:i'd|i would|i'll|i will|i'm|i am) (?:be )?(?:so |more than )?(?:happy|glad|delighted|thrilled) to",
    r"(?:i'd|i would) love to",
    r"(?:thanks|thank you) for (?:asking|the question|sharing)",
    r"(?:absolutely|certainly|of course|sure)!",
]
_OPENER_RE = re.compile(r"^(?:" + "|".join(SYCOPHANTIC_OPENERS) + ")")

def plain_answer(s):
    """Answer text with citation markers and markdown punctuation removed, curly apostrophes folded."""
    s = strip_markers(s or "").replace("\u2019", "'")
    s = re.sub(r"[*_`#>|~]", "", s)
    return norm_ws(re.sub(r"^\s*(?:[-•]|\d+\.)\s+", "", s, flags=re.M))

def sycophantic_opener(text):
    head = plain_answer(text)[:160].lower().lstrip("\"'“ ")
    m = _OPENER_RE.match(head)
    return head[:m.end() + 20].strip() if m else None

def word_count(text):
    return len(re.findall(r"[A-Za-z0-9][\w'.-]*", plain_answer(text)))

def ends_with_question(text):
    return plain_answer(text).rstrip(" )\"'”’").endswith("?")

def length_class(exp):
    """'short' (a fact or a read question) | 'broad' (a synthesis / survey question) | None (not judged).
    An explicit `length` on the case wins; otherwise the expected route decides."""
    if exp.get("length"):
        return exp["length"]
    return {"read": "short", "empty": "short", "survey": "broad"}.get(exp.get("expectRoute") or "")

W3_SHORT_MAX, W3_BROAD_MIN, W2_MAX_SHARE = 120, 60, 0.5


# ── A6b (Brief CH-A1b iteration 2) — status labels vs the entry's OWN reference ranges ──
# Voice iteration 1 called testosterone 897 "well above the normal range (300–1080)", filed cholesterol 213
# (<200) under "within normal ranges", and put albumin 5.0 "at the lower end" of 3.4–5.0. A6 (required facts)
# passed those answers, because every number was present. A6b reads what the answer CLAIMS about each value.
# Lenient by design (a false FAIL costs as much as a false PASS): a claim it can't attribute is not checked.
LAB_ROW_RE = re.compile(r"([A-Z][A-Z0-9 ,&*/()%.-]*?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?|[<>]=?\s*\d+(?:\.\d+)?)"
                        r"\s+(?:[A-Za-z/%*.\d]+\s+){0,2}?([HLN])\b")
# analyte key → (keyword in the ENTRY's row name, answer-side pattern). Order = most specific first.
ANALYTES = [
    ("pct_free_t", "PERCENTAGE FREE", r"(?:percentage|percent|%)\s*free(?:\s+testosterone)?|free\s+testosterone\s+(?:percentage|percent|%)|testosterone,?\s+percentage\s+free"),
    ("free_t", "FREE", r"free\s+testosterone(?:\s+calculation)?|testosterone,?\s+free(?:\s+calculation)?|free\s+t\b"),
    ("shbg", "BINDING GLOBULIN", r"\bshbg\b|sex[- ]hormone[- ]binding globulin"),
    ("total_t", "TESTOSTERONE", r"(?:total\s+)?testosterone(?:\s*\(immunoassay\)|,?\s+immunoassay|,?\s+total)?"),
    ("ldl", "LDL", r"\bldl(?:[- ]c)?\b(?:\s*\([^)]{0,40}\))?(?:[ ,-]+(?:calculated\s+)?cholesterol)?|low[- ]density lipoprotein(?:\s+cholesterol)?|bad cholesterol"),
    ("hdl", "HDL", r"\bhdl(?:[- ]c)?\b(?:\s*\([^)]{0,40}\))?(?:[ ,-]+cholesterol)?|high[- ]density lipoprotein(?:\s+cholesterol)?|good cholesterol"),
    ("trig", "TRIGLYCERIDE", r"triglycerides?"),
    ("chol", "CHOLESTEROL", r"(?:total\s+)?cholesterol"),
    ("egfr", "FILTRATION", r"\begfr\b|glomerular filtration rate"),
    ("bun", "UREA", r"\bbun\b|(?:blood\s+)?urea nitrogen"),
    ("sodium", "SODIUM", r"\bsodium\b"), ("potassium", "POTASSIUM", r"\bpotassium\b"),
    ("chloride", "CHLORIDE", r"\bchloride\b"), ("co2", "CO2", r"\bco2\b(?:\s+content)?|carbon dioxide|bicarbonate"),
    ("glucose", "GLUCOSE", r"\bglucose\b"), ("calcium", "CALCIUM", r"\bcalcium\b"),
    ("creatinine", "CREATININE", r"\bcreatinine\b"), ("protein", "TOTAL PROTEIN", r"total protein"),
    ("albumin", "ALBUMIN", r"\balbumin\b"), ("alkp", "ALK PHOS", r"alk(?:aline)?[ -]?phos(?:phatase)?|\balk-?p\b"),
    ("alt", "ALT", r"\balt\b"), ("ast", "AST", r"\bast\b"), ("bili", "BILIRUBIN", r"bilirubin"),
    ("aniongap", "ANION GAP", r"anion gap"),
]
_ANALYTE_RES = [(k, kw, re.compile(pat, re.I)) for k, kw, pat in ANALYTES]
A6B_CLAIMS = [   # (claim, pattern) — searched in the answer with analyte names masked out
    ("POS_LOW", r"\b(?:lower|low)\s+end\b|\blower\s+(?:limit|bound)\b|bottom of the (?:normal |reference )?range|\blow[- ]normal\b"),
    ("POS_HIGH", r"\bnormal[- ]to[- ]high\b|\b(?:upper|higher|high)\s+end\b|\bupper\s+(?:limit|bound)\b|top of the (?:normal |reference )?range|\bhigh[- ]normal\b"),
    ("ABNORMAL", r"out of (?:the )?(?:normal |reference )?range|outside (?:the |of the )?(?:normal |reference )?range|\babnormal\b|\bflagged\b"),
    ("NORMAL", r"\b(?:within|in|inside)\s+(?:the\s+)?(?:normal|reference|expected)\b|\bnormal\s+(?:limits|levels?|values?|results?)\b|\b(?:is|are|was|were|remains?|looks?|appears?)\s+(?:all\s+|completely\s+|entirely\s+)?normal\b|[—–:-]\s*normal\b|\bin range\b"),
    ("HIGH", r"\b(?:elevated|exceeds?|exceeding)\b|\bhigh\b(?![- ](?:end|normal|side))|\babove\b|\bhigher than\b"),
    ("LOW", r"\b(?:decreased|reduced|deficient)\b|\blow\b(?![- ](?:end|normal|side|density))|\bbelow\b|\blower than\b"),
]
_A6B_CLAIM_RES = [(c, re.compile(p, re.I)) for c, p in A6B_CLAIMS]
_NEGATION_RE = re.compile(r"\b(?:not|no|isn't|aren't|wasn't|weren't|never|nor|without)\b[^.;:\n]{0,45}$", re.I)
# an EXAMPLE or a HYPOTHETICAL is not a claim about this value ("(e.g., low testosterone)", "may indicate … reduced …")
_HYPOTHETICAL_RE = re.compile(r"(?:e\.g\.,?|i\.e\.,?|such as|for example|like|if|whether|risk of|signs? of|symptoms? of)\s*[^.;:\n]{0,25}$"
                              # a modal is a hedge or a general statement ("immunoassays can be imprecise at low levels")
                              r"|\b(?:may|might|could|can|would)\b[^.;\n]{0,45}$"
                              # medical HISTORY, not a label of this result ("you were treated for low testosterone")
                              r"|\b(?:treated for|treatment for|history of|diagnosed with|prescribed for|was|were)\s+[^.;:\n]{0,15}$", re.I)


def lab_reference(packet):
    """{analyte key: [(value, lo, hi, flag, row text), …]} parsed from the entry's own result rows
    (`NAME value range UNIT FLAG`, name possibly on earlier lines). Several rows per analyte when the packet
    holds more than one lab report. Empty when the packet has no lab table."""
    flat = re.sub(r"\s+", " ", packet or "")
    out = {}
    for m in LAB_ROW_RE.finditer(flat):
        name, val, rng, flag = m.group(1).upper(), float(m.group(2)), m.group(3).replace(" ", ""), m.group(4)
        hit = None   # the keyword that ENDS latest in the row name wins; on a tie the longer ("PERCENTAGE FREE" > "FREE")
        for k, kw, _ in _ANALYTE_RES:
            pos = name.rfind(kw)
            if pos >= 0 and (hit is None or (pos + len(kw), len(kw)) > hit[1]):
                hit = (k, (pos + len(kw), len(kw)))
        if not hit:
            continue
        if "-" in rng and not rng.startswith(("<", ">")):
            lo, hi = (float(x) for x in rng.split("-"))
        elif rng.startswith("<"):
            lo, hi = None, float(rng.lstrip("<="))
        else:
            lo, hi = float(rng.lstrip(">=")), None
        out.setdefault(hit[0], []).append((val, lo, hi, flag, m.group(0).strip()[-60:]))
    return out


def _truth(claim, ref):
    v, lo, hi, _, _ = ref
    normal = (lo is None or v >= lo) and (hi is None or v <= hi)
    if claim == "NORMAL":
        return normal
    if claim == "ABNORMAL":
        return not normal
    if claim == "HIGH":     # above the upper bound; on a lower-bound-only range (">40") "above" is just true
        return (hi is not None and v > hi) or (hi is None and v > lo)
    if claim == "LOW":
        return (lo is not None and v < lo) or (lo is None and v < hi)
    if lo is None or hi is None or hi <= lo:
        return True         # position claims are judged only on a bounded range
    pos = (v - lo) / (hi - lo)
    return pos <= 0.5 if claim == "POS_LOW" else pos >= 0.5


def a6b_violations(answer, ref):
    """→ list of human-readable mislabels. Each claim is attributed to ONE analyte mention in its segment:
    the next mention if the claim word sits right before it ("elevated LDL"), else the previous one."""
    if sum(len(v) for v in ref.values()) < 3:
        return None
    text = strip_markers(answer or "").replace("\u2019", "'")
    text = re.sub(r"[*_`#>|~]", "", text)
    bad = []
    truly_out = sorted(k for k, rows in ref.items() if all(not _truth("NORMAL", r) for r in rows))
    recent = []   # analytes named by the last segments that named any (for "This is the only value…" lines)
    for seg in re.split(r"\n+|(?<=[.!?])\s+(?=[A-Z(])", text):
        # "None of your values are out of range" / "no lab values are outside the reference range" — while some ARE
        if truly_out and re.search(r"\b(?:none of (?:your|the|these)|no (?:lab |other )?(?:values?|results?|lab results?|lab values?)|nothing)\b[^.\n]{0,50}"
                                   r"(?:out of (?:the )?(?:normal |reference )?range|outside (?:of )?(?:the |their )?(?:official |normal |reference )?(?:reference )?(?:range|limits)|abnormal)", seg, re.I) \
                and not re.search(r"\b(?:other|else|besides|apart|except|aside)\b", seg, re.I) \
                and not re.search(r"\b(?:panel|testing|tests|section|category|hormones?|hormonal|metabolic|electrolytes?|liver|kidney|lipids?)\b", seg, re.I):
            # (a scoped "no values are out of range in hormone testing" is true — only an UNSCOPED "none" is judged)
            bad.append(f"says no value is out of range; out of range per the entry: {truly_out}: \"{seg[:90].strip()}\"")
        # analyte mentions: most-specific pattern wins; masked so 'LDL cholesterol' is never also 'cholesterol'
        mask, mentions = list(seg), []
        for k, _, rx in _ANALYTE_RES:
            for m in rx.finditer("".join(mask)):
                mentions.append((m.start(), m.end(), k))   # every analyte attributes; only those in `ref` are judged
                for i in range(m.start(), m.end()):
                    mask[i] = "\0"
        if not any(k in ref for _, _, k in mentions):
            # "This is the only value that is out of range." under an analyte's bullet → that analyte (look back ≤4 lines)
            if recent and re.search(r"\bonly\b[^.\n]{0,40}(?:out of (?:the )?(?:normal |reference )?range|abnormal)", seg, re.I) \
                    and not re.search(r"\b(?:not|no)\b", seg, re.I):
                named = recent[-1][1]
                missing = [k for k in truly_out if k not in named]
                if missing:
                    bad.append(f"says only {sorted(named)} out of range; also out of range: {missing}: \"{seg[:90].strip()}\"")
            recent = [(age + 1, n) for age, n in recent if age < 4]
            continue
        recent = [(0, {k for _, _, k in mentions if k in ref})]
        mentions.sort()
        masked = "".join(mask)
        claims = []   # (pos, end, claim)
        for c, rx in _A6B_CLAIM_RES:
            for m in rx.finditer(masked):
                if any(s <= m.start() < e for s, e, _ in claims):
                    continue
                if _NEGATION_RE.search(masked[:m.start()]) or _HYPOTHETICAL_RE.search(masked[:m.start()]):
                    continue
                # about OTHER values ("…even if other values are normal", "the rest are within range") → not this analyte
                if re.search(r"\b(?:other|others|rest|remaining)\b[^.;:\n]{0,30}$", masked[:m.start()], re.I):
                    continue
                # a range QUOTE ("the normal range is below 200", "above 40 mg/dL") is not a claim
                if c in ("HIGH", "LOW") and re.match(r"\s*(?:the\s+)?[<>≥≤]?\s*\d", masked[m.end():]):
                    continue
                # the label modifies some OTHER noun ("elevated estrogen", "reduced libido") → not this analyte
                nxt = re.match(r"\s+([A-Za-z]+)", masked[m.end():])
                if c in ("HIGH", "LOW") and nxt and not masked[m.end():].lstrip().startswith("\0") and nxt.group(1).lower() not in (
                        "levels", "level", "values", "value", "at", "in", "by", "for", "and", "or", "than", "the", "range",
                        "limit", "limits", "but", "which", "with", "compared", "relative", "normal", "reference", "recommended",
                        "target", "ideal", "optimal", "upper", "lower", "its", "their", "your", "his", "her", "a", "an", "to",
                        "according", "per", "is", "are", "as", "so", "this", "that", "though", "although", "side"):
                    continue
                # a range QUOTE ("normal range 0.50-1.50", "(normal <200)") is not a claim — unless "within the normal range"
                if c == "NORMAL" and re.match(r"\s*(?:range\s*)?[:(]?\s*[<>≥≤]?\s*\d", masked[m.end():]) and not re.match(r"(?:within|in|inside)\b", m.group(0), re.I):
                    continue
                claims.append((m.start(), m.end(), c))
        # "with the exception of X" / "except X" after a NORMAL claim → X is claimed abnormal
        for m in re.finditer(r"\b(?:with the exception of|except(?: for)?|apart from|other than)\b", seg, re.I):
            if any(c == "NORMAL" and p < m.start() for p, _, c in claims):
                nxt = [mm for mm in mentions if mm[0] >= m.end()][:1]
                if nxt:
                    claims.append((nxt[0][0] - 1, nxt[0][0] - 1, "ABNORMAL@" + nxt[0][2]))
        for p, e, c in claims:
            if c.startswith("ABNORMAL@"):
                k, c = c.split("@")[1], "ABNORMAL"
            else:
                after = [mm for mm in mentions if mm[0] >= e and re.fullmatch(r"[\sA-Za-z'-]{0,25}", seg[e:mm[0]])]
                before = [mm for mm in mentions if mm[1] <= p]
                pick = after[0] if after and (c in ("HIGH", "LOW", "ABNORMAL") and len(seg[e:after[0][0]].split()) <= 3) else (before[-1] if before else (after[0] if after else None))
                if not pick:
                    continue
                k = pick[2]
            if k not in ref:
                continue
            if not any(_truth(c, r) for r in ref[k]):   # false for EVERY row of this analyte in the packet
                v, lo, hi, flag, row = ref[k][0]
                rng = f"{lo}-{hi}" if lo is not None and hi is not None else (f"<{hi}" if lo is None else f">{lo}")
                msg = f"{k} {v} ({rng}, lab flag {flag}) labelled {c}"
                if not any(b.startswith(msg) for b in bad):
                    bad.append(f"{msg}: \"{seg[max(0, p - 50):e + 10].strip()}\"")
        # "the only value out of range is X" → every truly out-of-range analyte must be among those named
        if re.search(r"\bonly\b", seg, re.I) and any(c in ("ABNORMAL", "HIGH", "LOW") for _, _, c in claims):
            named = {k for _, _, k in mentions}
            missing = [k for k in truly_out if k not in named]
            if missing and named:
                bad.append(f"says only {sorted(named)} out of range; also out of range: {missing}: \"{seg[:90].strip()}\"")
    return bad


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
        # `name@digest[@size_vram@context_length]` (size/ctx added for test 4's resident-memory read)
        loaded = [x.split("@") for x in (parts[1].split(",") if len(parts) > 1 and parts[1] else [])]
        rows.append((ts, [(f[0], f[1]) for f in loaded if len(f) >= 2]))
    return rows

def resident_sizes(path):
    """{model: (max size_vram bytes, context_length)} seen in ps.log — test 4's resident-memory read."""
    out = {}
    if not path or not os.path.exists(path):
        return out
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        for x in (parts[1].split(",") if len(parts) > 1 and parts[1] else []):
            f = x.split("@")
            if len(f) >= 4:
                size, ctx = int(f[2] or 0), int(f[3] or 0)
                if size > out.get(f[0], (0, 0))[0]:
                    out[f[0]] = (size, ctx)
    return out


def iso_epoch(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


# ─────────────────────────── grading ───────────────────────────

def grade_row(exp, turn, ui, prev_turn, host, ps, versions, cases_meta, store=False):
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
    stats["fullTextHunts"] = len(re.findall(r"full text|read in full|don'?t have the (?:full|complete)|we don'?t have", (thinking or "").lower()))
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
    if exp.get("cold") and not replay and not store:
        ej = ui.get("ejectedAtEpoch")
        t0 = iso_epoch(turn.get("startedAt", "")) or 0
        between = [loaded for ts, loaded in ps if ej and ej + 1 <= ts <= t0]
        res("V7", bool(ej) and any(not l for l in between),
            f"ejected={'yes' if ej else 'NO'} empty-samples-before-turn={sum(1 for l in between if not l)}/{len(between)}",
            abort=True)
    else:
        na("V7")

    # ── F* stream (store pre-screen has no UI → no frames: N/A, not PASS)
    if store:
        frames = []
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
    if store:
        for g in ("F1", "F2", "F3", "F4"):
            na(g, "store pre-screen (no UI frames)")

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
    if store:
        na("A7", "store pre-screen (no screen)")
    elif shown or final:
        # Letters only: the on-screen label joins blocks with ", ", renders [n] as bare superscript
        # digits and drops markdown — none of which is a content difference.
        letters = lambda x: re.sub(r"[^a-z]", "", (x or "").lower())
        ratio = difflib.SequenceMatcher(None, letters(shown), letters(final), autojunk=False).ratio()
        res("A7", ratio >= 0.9, f"similarity {ratio:.2f}")
    else:
        na("A7")

    ref = turn.get("refRanges")   # known-bad items carry the parsed ranges instead of the (redacted) packet
    ref = {k: [tuple(r) for r in rows] for k, rows in ref.items()} if ref else lab_reference(turn.get("userContent") or "")
    v6b = a6b_violations(final, ref) if norm_ws(final) else None
    if v6b is None:
        na("A6b", "no lab table in the packet" if norm_ws(final) else "no answer")
    else:
        res("A6b", not v6b, "; ".join(v6b[:3]) or f"{sum(len(r) for r in ref.values())} reference rows")

    gap = turn.get("maxMainThreadGapMs")
    if gap is not None:
        res("A8", gap <= 5000, f"longest main-thread stall {gap} ms")
    else:
        na("A8", "no heartbeat recorded")

    # ── W* voice (Brief CH-A1b) — graded on the committed answer (what the model said)
    if norm_ws(final):
        op = sycophantic_opener(final)
        res("W1", not op, f"opens \"{op}…\"" if op else "")
        wc, lc = word_count(final), length_class(exp)
        stats.update(words=wc, endsWithQuestion=ends_with_question(final))
        if lc == "short":
            R["W3"] = ("PASS" if wc <= W3_SHORT_MAX else "FLAG", f"{wc} words on a fact/read question (≤{W3_SHORT_MAX})")
        elif lc == "broad":
            R["W3"] = ("PASS" if wc >= W3_BROAD_MIN else "FLAG", f"{wc} words on a broad question (≥{W3_BROAD_MIN})")
        else:
            na("W3", "length not judged for this case")
    else:
        na("W1", "no answer"); na("W3", "no answer")
    na("W2", "run-level (see the table footer)")

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
        prev_end = 0
        for m in re.finditer(r"\[(\d+)(?:\s*[–-]\s*\d+)?\]", sent):
            n = int(m.group(1))
            seg_start, prev_end = prev_end, m.end()   # only the text since the PREVIOUS marker is "beside" this one
            target = cite_by_idx.get(n)
            if not target:
                continue
            tnode = target.get("nodeID")
            if any(c.get("nodeID") == tnode for c in titled):
                continue
            # The cited entry is itself what the sentence talks about (≥2 shared title words, e.g. a heading
            # "Self-Knowledge Through Relationships [1][2][3]" grouping the near-duplicate "Self-awareness
            # Through Relationships" [2]) → a legitimate grouped citation, not a label mismatch. Found as a
            # false FAIL on qwen3:8b in CH-A A1; a false FAIL costs as much as a false PASS.
            tt = content_tokens(target.get("title", ""))
            if len(tt & content_tokens(strip_markers(sent))) >= min(2, len(tt)):
                continue
            pre = sent[seg_start:m.start()]
            near = [c for c in titled if title_mentioned(c["title"], pre)]
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
    # Narrowed after CH-A A1 (two false FAILs on qwen3:8b — a paraphrase of an entry's content can't be
    # judged from its title + an 80-char snippet). C4 now fires only on clear evidence; paraphrase quality
    # is CC's per-row read: (a) a phantom chip — never cited inline, never named, not read; or (b) cited
    # ONLY in sentences that name a DIFFERENT entry and share nothing with this entry's title or snippet.
    def discussed(c):
        if title_mentioned(c.get("title", ""), final) or c.get("nodeID") in read_nodes:
            return True
        citing = [s for s in sentences if f"[{c['index']}]" in s]
        if not citing:
            return False                                   # (a) phantom
        tt, st = content_tokens(c.get("title", "")), content_tokens(c.get("snippet", ""))
        for sent in citing:
            ws = content_tokens(strip_markers(sent))
            names_other = any(o.get("nodeID") != c.get("nodeID") and title_mentioned(o.get("title", ""), sent) for o in cand)
            if not names_other or (tt | st) & ws:
                return True
        return False                                       # (b) only beside another named entry, nothing shared
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
    mism = (not store) and (len(screen_chips) != len(dedup_titles) or any(t and t not in s for t, s in zip(dedup_titles, screen_chips)))
    res("C5", not outside and not mism,
        ("chip outside packet: " + ", ".join(c.get("title", "")[:24] for c in outside) + "; " if outside else "")
        + (f"on-screen chips {len(screen_chips)} ≠ committed {len(dedup_titles)}" if mism else ""))
    stats.update(nativeMarkers=len(inline), titleRescue=bool(cites) and not inline and not (set(c["index"] for c in cites) <= always))

    # ── T1 thinking OFF honesty
    raw_think = sum(len(d.get("s", "")) for d in raw if d.get("ch") == "thinking")
    if not exp["think"]:
        res("T1", not thinking and raw_think == 0 and not (ui.get("thoughtHeaderPresent") and not store),
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


def run_level(out):
    """Run-level graders → {grader: (status, detail)}. W2: the question tic, across every answered row."""
    ans = [g["stats"].get("endsWithQuestion") for g in out.values() if "endsWithQuestion" in g.get("stats", {})]
    if len(ans) < 2:
        return {"W2": ("N/A", f"{len(ans)} answer(s) — too few to judge a tic")}
    q = sum(1 for a in ans if a)
    return {"W2": ("FLAG" if q / len(ans) > W2_MAX_SHARE else "PASS", f"{q}/{len(ans)} answers end with a question")}


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
    lines = ["| row | case | think | status | route | chips (native/rescue) | TTFT | load | eval tok | think chars | full-text hunts | words | red graders | flags (CC reads) |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for row in sorted(out):
        g, e, s = out[row], exp["rows"][row], out[row]["stats"]
        reds = [f"{k}:{d}" for k, (st, d) in g["results"].items() if st in ("FAIL", "ABORT")]
        flags = [f"{k}:{d}" for k, (st, d) in g["results"].items() if st == "FLAG"]
        lines.append(f"| {row} | {e['case']} | {'on' if e['think'] else 'off'} | {g['status']} | {s.get('route','')} | "
                     f"{s.get('chips','')} ({s.get('nativeMarkers','')}/{'Y' if s.get('titleRescue') else 'n'}) | "
                     f"{s.get('ttftMs','')} | {s.get('loadMs','')} | {s.get('evalTokens','')} | {s.get('thinkingChars','')} | {s.get('fullTextHunts','')} | "
                     f"{s.get('words','')} | {'<br>'.join(reds) if reds else '—'} | {'<br>'.join(flags) if flags else '—'} |")
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
    lines += ["", "**Run-level:** " + "; ".join(f"{k} {st} ({d})" for k, (st, d) in run_level(out).items())]
    open(os.path.join(run_dir, "table.md"), "w").write("\n".join(lines) + "\n")


def grade_store(pass_dir, model, digest):
    """Store-level PRE-SCREEN (`-LibrarianGauntlet` + render tap, no UI): grade every case's turn with the
    same graders; UI-only graders (F*, A7, on-screen half of C5, the Thought-process header) are N/A."""
    cm = json.load(open(os.path.join(HERE, "cases.json")))
    meta = {c["id"]: c for chat in cm["chats"] for c in chat["cases"]}
    sr = load_json(os.path.join(pass_dir, "store-rows.json"), {"rows": [], "think": False})
    think = bool(sr.get("think"))
    host = parse_host_log(os.path.join(pass_dir, "host.log"))
    ps = parse_ps_log(os.path.join(pass_dir, "ps.log"))
    versions = load_json(os.path.join(pass_dir, "versions.json"), {})
    verdicts = load_json(os.path.join(pass_dir, "verdicts.json"), {})
    turns = {}
    for p in glob.glob(os.path.join(pass_dir, "turn-*.json")):
        t = load_json(p)
        if t:
            turns[t["seq"]] = t
    exp_rows, out = {}, {}
    for r in sr["rows"]:
        c = meta.get(r["case"], {"id": r["case"]})
        row = f"{r['case']}.{'on' if think else 'off'}.store"
        e = {k: v for k, v in c.items() if k != "what"}
        if c.get("facts") == "panel":
            e["mustContain"] = cm["panel"]
        e.update(case=r["case"], think=think, run="store", model=model, digest=digest, replay=False)
        exp_rows[row] = e
        turn = turns.get(r["seq"])
        prev = turns.get(r["seq"] - 1) if (not r.get("newChat") or c.get("reask")) else None
        ui = {"turnCompleted": turn is not None, "onScreenAnswer": (turn or {}).get("finalText"),
              "errorBanner": bool((turn or {}).get("lastError"))}
        g = grade_row(e, turn, ui, prev, host, ps, versions, cm, store=True)
        g["status"] = row_status(g, verdicts.get(row))
        g["verdict"] = verdicts.get(row)
        g["answer"] = (turn or {}).get("finalText")
        out[row] = g
    exp = {"model": model, "digest": digest, "runs": 1, "rows": exp_rows}
    json.dump(exp, open(os.path.join(pass_dir, "expected.json"), "w"), indent=2, ensure_ascii=False)
    json.dump(out, open(os.path.join(pass_dir, "grades.json"), "w"), indent=2, ensure_ascii=False)
    write_table(pass_dir, exp, out)
    return out


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
                if chat.get("_lab"):
                    continue   # lab-only chats run only when a replay variant names them
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
        if item.get("store"):   # a store pre-screen capture (no UI) — graded the way it was produced
            v = load_json(os.path.join(run_dir, "versions.json"), {})
            grades = grade_store(run_dir, v.get("model"), v.get("digest"))
        else:
            grades = grade_dir(run_dir, quiet=True)
        for row, want_red in item.get("expectRed", {}).items():
            g = grades.get(row)
            if not g:
                problems.append(f"{item['id']}: row {row} not graded (missing capture?)"); continue
            red = {k for k, (st, _) in g["results"].items() if st in ("FAIL", "ABORT", "FLAG")}
            for w in want_red:
                if w in red:
                    proven[w].append(item["id"])
                else:
                    st, d = g["results"].get(w, ("MISSING", ""))
                    problems.append(f"{item['id']} {row}: grader {w} should be RED but is {st} ({d})")
            matrix.append((item["id"], row, sorted(red), g["results"]))
        for row in item.get("expectGreen", []):
            g = grades.get(row)
            red = {k: d for k, (st, d) in (g or {"results": {}})["results"].items() if st in ("FAIL", "ABORT", "FLAG")}
            if not g or red:
                problems.append(f"{item['id']} {row}: positive control is not green: {red or 'not graded'}")
            matrix.append((item["id"], row, sorted(red), (g or {}).get("results", {})))
        # named graders that must stay GREEN on a row (a control that is not all-green for unrelated reasons)
        for row, want_green in item.get("expectGreenOn", {}).items():
            g = grades.get(row)
            for w in want_green:
                st = (g or {"results": {}})["results"].get(w, ("MISSING", ""))
                if st[0] != "PASS":
                    problems.append(f"{item['id']} {row}: control grader {w} is not green: {st}")
            matrix.append((item["id"], row, sorted(k for k, (st, _) in (g or {"results": {}})["results"].items() if st in ("FAIL", "ABORT", "FLAG")), (g or {}).get("results", {})))
        # run-level graders (W2): RED (or FLAG) on a known-bad run, green on its control
        rl = run_level(grades)
        for w in item.get("expectRunRed", []):
            if rl.get(w, ("MISSING",))[0] in ("FAIL", "FLAG"):
                proven[w].append(item["id"])
            else:
                problems.append(f"{item['id']}: run-level {w} should be RED but is {rl.get(w)}")
        for w in item.get("expectRunGreen", []):
            if rl.get(w, ("MISSING",))[0] != "PASS":
                problems.append(f"{item['id']}: run-level control {w} is not green: {rl.get(w)}")
        if item.get("expectRunRed") or item.get("expectRunGreen"):
            matrix.append((item["id"], "(run)", sorted(k for k, (st, _) in rl.items() if st in ("FAIL", "FLAG")), rl))
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
    for chat in (c for c in cm["chats"] if not c.get("_lab")):
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
        L.append(f"| {g} | {d} | {'ABORT (row invalid)' if g.startswith('V') else ('FLAG for CC’s read' + (' (run-level)' if g == 'W2' else '') if g in FLAG_ONLY else ('FAIL the case' if g != 'R1' else 'FAIL the case (aggregate)'))} |")
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
    gs = sub.add_parser("grade-store"); gs.add_argument("pass_dir"); gs.add_argument("--model"); gs.add_argument("--digest")
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
    elif a.cmd == "grade-store":
        v = load_json(os.path.join(a.pass_dir, "versions.json"), {})   # the run's own record, unless overridden
        grade_store(a.pass_dir, a.model or v.get("model"), a.digest or v.get("digest"))
        print(open(os.path.join(a.pass_dir, "table.md")).read())
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
