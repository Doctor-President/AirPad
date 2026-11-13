#!/usr/bin/env python3
"""Mac D0.10 harness — check AirPad's written Markdown against a CommonMark parser (markdown-it-py, CommonMark mode).
   commonmark_check.py <boldmarkup.json>   (written by DEBUG -BoldMarkupSelfTest)
For each case: the parsed text equals the entry's text (no literal `*` left over) and every non-space character is
bold / italic exactly as in the entry."""
import json, sys
from markdown_it import MarkdownIt

md = MarkdownIt("commonmark")
cases = json.load(open(sys.argv[1]))
fails = 0
for c in cases:
    toks = md.parseInline(c["md"])[0].children
    text, b, i = "", [], []
    strong = em = 0
    for t in toks:
        if t.type == "strong_open": strong += 1
        elif t.type == "strong_close": strong -= 1
        elif t.type == "em_open": em += 1
        elif t.type == "em_close": em -= 1
        elif t.type in ("text", "softbreak"):
            s = t.content if t.type == "text" else "\n"
            text += s; b += [strong > 0] * len(s); i += [em > 0] * len(s)
        elif t.type in ("html_inline",):
            pass
    ok = text == c["text"] and all(ch.isspace() or (b[k] == bool(c["bold"][k]) and i[k] == bool(c["italic"][k]))
                                   for k, ch in enumerate(c["text"]))
    fails += not ok
    print(("PASS" if ok else "FAIL"), c["name"], "—", c["md"], "" if ok else f"→ parsed text {text!r}")
print(f"[commonmark_check] {'PASS' if fails == 0 else 'FAIL'} — {len(cases) - fails}/{len(cases)} (markdown-it {__import__('markdown_it').__version__}, CommonMark)")
sys.exit(1 if fails else 0)
