---
name: perf-recording
description: Read a performance recording (Settings › About › Performance recorder; Mac ⌃⌥⌘P, iPhone three-finger long-press) — T's "it lagged" turned into data with scripts/perf/explain.py. Use whenever T or Companion sends a perf-*.json.
---
# Performance recording

- A recording holds timings, view type names and code symbols only, nothing from the library — safe to read; still
  never copy entry names from it into Ops.
- Where they land: the app's Documents/Caches (`perf-<date>-<time>-<place>-<n>-entries.json`); T's arrive via
  Companion (path in the T-check results file). Find with `mdfind -name perf-2026` or under
  `~/Library/Containers/com.doctorpresident.airpad*/Data`.
- `python3 scripts/perf/explain.py <file> [--from S --to S] [--detail] [--json]` → plain-language summary: window fps vs
  each surface's own frame rate (Map, lists), main-thread busy %, stalls with their families (hover/hit-testing, text
  layout, image decode, SwiftUI layout/updates, Map, Core Animation …), views rebuilt most.
- `scripts/perf/why.py` / `phases.py` for deeper slicing; `steps.py` aligns a scripted run's steps.
- Reading it: low surface fps with low own-work and a mostly idle main thread = something PACES the surface (a cap, a
  rest state), not overload. High main-thread % with a family = overload: fix that family.
- Reproduce the recording's situation on the isolated copy with real events (`real-click-test`) and record again
  before and after the fix; the before/after pair is the proof.
