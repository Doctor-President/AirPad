---
name: cc-report
description: Write the CC report for a relay round — top of Ops/meta/cc-report-latest.md, plain language for T, ending with the RELAY line; commit and push Ops. Use at the end of every directive round (and update the turn status every turn).
---
# CC report

- Prepend a section to `~/Developer/Ops/meta/cc-report-latest.md` (newest on top; never delete older ones).
- Title line: `## <round> · <one-line outcome> · <RELAY state> (<date>)`.
- First paragraph: branch + final commit (and that main 34e90827 is untouched), TestFlight build or why none, where the
  evidence and the T-check are. Then what needs T, numbered, recommendation first, one ruling at a time.
- Body: one section per phase/item: what was wrong (cause, not symptom), what changed, the proof (real-event counts,
  before → after numbers), and anything parked with its sheet. Plain language; numbers over adjectives; no "Claude
  slop" (no hype, no "robust/seamless", no unlabelled guesses).
- A "Considered" block for each non-trivial decision (alternatives, why this one, what would change our mind).
- Never quote T's library (fpscan blocks it): IDs and numbers only.
- End with the exact line `CC REPORT` summary bullets, then `RELAY: <AWAITING-REVIEW|HOLD-FOR-T> · <step id> · <commits>`.
- Commit Ops with explicit paths (never `git add -A`; Companion co-edits the tree), fold the report into the same
  commit as the round's other Ops changes, push.
