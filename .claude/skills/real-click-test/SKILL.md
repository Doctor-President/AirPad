---
name: real-click-test
description: Prove a Mac (Catalyst) change with REAL clicks, keys, scrolls and drags on the isolated Release copy — rclick and friends, the unlock check, caffeinate, one agent on the mouse, evidence in the self-pruning folder. Use for any Mac UI fix or before claiming a Mac behaviour works.
---
# Real-click test (Mac)

Tools: `scripts/mac/kit/` (README there) and `scripts/mac/realclick/*.swift` (compiled into `build/kit/` by
`scripts/mac/kit/tools.sh`). Real events go through the window server (CGEvent), located via Accessibility from
outside the app, so they work on Release with no hooks.

## Every time
1. `zsh scripts/mac/kit/unlocked.sh` must print `locked 0 ax 1 post 1`. Locked → stop real-event steps, do other work,
   re-check later. Never read "nothing printed" as unlocked.
2. Hold `caffeinate -d -u` (background) for the whole phase: the Mac locks on display sleep.
3. **One agent owns the mouse.** Never run two real-event scripts or agents at once.
4. Build: `zsh scripts/mac/kit/build1.sh Release <tag>` → `build/runs/<tag>/AirPadMacA.app` (isolated copy: own bundle
   id + sandbox, never T's library). Launch: `P=$(EXTRA="-appearance.override dark" zsh scripts/mac/kit/launch.sh <app> <out>)`.
5. Reproduce BEFORE the fix on the old build, then the same script after; N trials each; write the counts.

## rclick verbs (build/kit/rclick)
`find|click|has|get|hover <pid> <ax-id-or-title>`, `clickat|dclickat <pid> x y`, `drag <pid> x y dx dy`,
`type <pid> text`, `key <pid> code` (53 Esc, 36 Return, 49 Space), `cmdkey <pid> code`, `menu <pid> <menu> <item>`,
`winsize|winmove|winpos`. A press another app covers is refused ("COVERED", exit 3) — move the window clear of banners.
Others: `rscroll x y trackpad <dy> <steps>` (two-finger swipe with phases) / wheel; `rdraghold`; `rfinder` (real Finder
drags — click empty Finder space first, Finder keeps multi-selection); `rraw` (other apps' windows); `rrec pid secs out.mov`
(60 fps recording); `rperf` (scripted session timing visible/settled from screen frames); `mods` (check no modifier is stuck).

## Traps
- A flag-only ⌘ key leaves ⌘ stuck → check `build/kit/mods` after any modifier use.
- First-run callouts eat the first click and hide AX: mark `com.airpad.callouts.*` shown (selftests.sh does).
- Persisted window state (sidebar hidden, Librarian closed) leaks between runs; set it explicitly at the start.
- Catalyst sheets are separate windows; `-ApplePersistenceIgnoreState YES` after a crash (launch.sh passes it).
- A notification banner top-right can cover controls (and a click opens its app).
- Release prints are buffered: use the recorder or screen frames, not logs.
- The appearance switch is `-appearance.override dark|light`, not AppleInterfaceStyle.

## Evidence
Raw output stays in `build/runs/<tag>/` (newest 12 kept; `touch .keep` to pin). Copy only the small proof (counts
table, a few stills) to `Ops/design-refs/<round>/`.
