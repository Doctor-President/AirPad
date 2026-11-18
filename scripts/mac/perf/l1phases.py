#!/usr/bin/env python3
"""E fix-up 5 · L1 — main-thread stall samples of one step label sorted into phases (first match wins, in order):
harness AX lookups, the menu bar's rebuild, the UINavigationController transition, the List's body, the entry detail's
body, text layout, SwiftUI layout, SwiftUI graph update, Core Animation commit, other.
  l1phases.py <session.trace> <rperf.txt> <label> [min ms = 50]"""
import os, re, subprocess, sys
from collections import Counter
sys.argv = [sys.argv[0], sys.argv[1], sys.argv[2], sys.argv[4] if len(sys.argv) > 4 else '50'] + [sys.argv[3]]
want = sys.argv.pop()
src = open(os.path.join(os.path.dirname(__file__), 'k3stalls.py')).read()
src = src.split("print(f'main thread:")[0]          # reuse the parser + stall finder, skip its report
exec(src)
PH = [('harness AX', r'NSAccessibility|AXRuntime|_accessibility'),
      ('menu bar rebuild', r'UIMenuSystem|_UIMenuBarController|UIMainMenuSystem'),
      ('nav transition', r'_UIViewControllerTransitionConductor|_UINavigationParallaxTransition|UINavigationController'),
      ('List body', r'NodeListView|MacListRow'),
      ('Cards body', r'NodeGridView|NodeGridTile|NodeCardView'),
      ('entry body', r'NodeDetailView|CaptureHeader|EntryCard|RichTextEditor'),
      ('text layout', r'NSCoreTypesetter|TTypesetter|NSTextLayout|NSLayoutManager|CTLine|CoreText'),
      ('SwiftUI layout', r'sizeThatFits|placeSubviews|LayoutEngine|layoutSubviews'),
      ('graph update', r'AG::|AttributeGraph'),
      ('CA commit', r'CA::Transaction|CA::Context')]
c = Counter(); n = 0
for r in stalls:
    if step_at(start + r[0][0]) != want: continue
    for s in r:
        n += 1
        names = ' '.join(f'{b} {f}' for f, b in s[2])
        c[next((p for p, rx in PH if re.search(rx, names)), 'other')] += 1
print(f'{want}: {n} stall ms')
for p, _ in PH + [('other', '')]:
    if c[p]: print(f'  {c[p]:6d} ms {c[p] / max(n, 1):4.0%}  {p}')
