#!/bin/zsh
# E fix-up 4 · K1 — lost clicks: each toolbar/sidebar control pressed 0.12 s after the pointer arrives, right after a
# large part of the window swapped (Settings in/out, the content view, a sidebar place). Real events (h1-seq.sh).
#   k1.sh <isolated .app> <out dir> [reps=50]
A=${1:?app}; O=${2:?out}; N=${3:-50}; S=${0:A:h}/h1-seq.sh
zsh $S $A $O $N \
  "L:open K:43 S:toolbar.librarian:toolbar.librarian:AXValue" \
  "L:open c:toolbar.view.List K:43 c:sidebar.settings S:toolbar.librarian:toolbar.librarian:AXValue" \
  "L:open K:37 S:sidebar.settings:sidebar.settings:AXValue c:sidebar.settings" \
  "L:open c:toolbar.newEntry S:toolbar.back:toolbar.back:AXEnabled" \
  "L:open c:toolbar.newEntry c:toolbar.back S:toolbar.forward:toolbar.forward:AXEnabled" \
  "L:open c:toolbar.view.List K:43 T:Cards" \
  "L:open c:toolbar.view.Map K:43 T:List" \
  "B:on L:open c:toolbar.view.List K:43 S:toolbar.sidebar:toolbar.sidebar:AXDescription c:toolbar.sidebar" \
  "L:open c:toolbar.newEntry K:43 S:toolbar.back:toolbar.back:AXEnabled" \
  "L:closed c:toolbar.view.Map w:1.5 c:toolbar.view.List w:1 c:toolbar.librarian T:Map"
