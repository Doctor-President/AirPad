# CLAUDE.md — AirPad

Rules Claude can't infer from the code and must not get wrong. Each one has already cost a build or a session. If
auto-memory contradicts this file, this file wins. Procedures live in skills (`.claude/skills/`); live state lives in Ops.

## Where things live
- Project state: the **Ops repo** (`~/Developer/Ops`), not Notion. Directives arrive in `Ops/meta/relay/directive.md`;
  how every session works is `Ops/meta/working-rules.md` (read it when a directive says so).
- Companion (the planning Claude) writes directives; CC implements AND verifies them; T rules on taste, feel, his own
  data and accounts.

## Verification (who proves what)
- **A green build is not a verified change.** Never write "fixed", "working" or "done" because it compiled.
- **CC owns verification** (working-rules §3): reproduce before fixing, then prove with real events on the Release build,
  before and after, with the evidence written down. Tests that only check what you just wrote are not proof on their
  own; for high-stakes work a fresh subagent that didn't write the code reviews it (`verifier`).
- **T judges** taste and feel, his own library, his device, and anything CC genuinely can't drive. Say which items are
  CC-proven and which wait for T; never present a T item as done.
- Skills: `real-click-test`, `speed-gate`, `perf-recording`, `librarian-gauntlet` (any Librarian Ask / delivery change
  goes through the Host path and the gauntlet — read the skill first), `stash-safe-switch`, `cc-report`.

## Done / authorship path (naming, summarising, enrichment gate, proposals)
- Verify end-to-end in the Simulator with `-StubAuthorModel` and the matrices `-BMDoneMatrix` (every capture path) and
  `-BODoneMatrix` (the four async OG/eager/Done orders + the scaffold Note variant). A new Done bug is first reproduced
  as a failing matrix row. Fill deterministic facts (a link's title = its page title) upstream in `applyOGFetch`, not on
  the model/promote chain. Emptiness is whitespace-trimmed (`AIService.meaningfulText`).
- The iOS 27 Simulator runs Foundation Models through the Mac's Apple Intelligence; the stub is for deterministic rows.

## Git
- Work on the branch the directive names; **`main` is untouched unless a directive says merge** (1.0 is in App Review
  from main `34e90827`). New branches come from what the directive names (else `main`) — check
  `git branch --show-current` first.
- Commit and push per item (a commit is "committed, pending T" for anything T must judge). Never rewrite history,
  never `--force`, never bare `git stash` (shared across worktrees; see `stash-safe-switch`).
- Before a build, `git diff --stat` to confirm the edits are on disk on the right branch.
- Never commit the scheme Xcode rewrites on a Release build (`AirPad.xcodeproj/xcshareddata/xcschemes/AirPad.xcscheme`;
  the kit scripts restore it).

## Project (XcodeGen)
- `project.yml` is the source of truth; `project.pbxproj` is generated — never hand-edit it. Adding/removing/renaming a
  file: edit `project.yml`, `xcodegen generate`, then `scripts/check_project_yml.sh`.

## Build
- Xcode 27 at `/Applications/Xcode.app`; prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, never flip `xcode-select`.
- Always pass `-configuration` (a bare `build` here built Release, where every DEBUG hook is inert).
- Mac (Catalyst): `scripts/mac/kit/` (build → isolated copy → launch → real events). iPhone TestFlight:
  `AIRPAD_APP_STORE_BUILD=1 bash scripts/testflight_upload.sh` (bash, not zsh). A Mac-only symbol in shared view code
  breaks the iOS build: build both and gate on each exit code.

## Data and privacy
- **Never show, quote or commit T's library** (titles, text, Gauntlet case details): the Ops `fpscan` hook blocks it.
  Report IDs and numbers. Tests run on the Sample Library / synthetic libraries in a scratch or the isolated Mac copy.
- DEBUG launch arguments and test hooks must be **Release-inert**. Never leave test files in T's folders. Don't change
  T's Ollama / LM Studio models or settings. No App Store Connect actions beyond a TestFlight upload; T submits.

## Dev tuners
- Every tuner panel has a **Copy values** button (a TestFlight reinstall wipes the UserDefaults it saves to). Bake T's
  pasted values, never values read back from a running build. Mac taste switches live under About › Version ×5 ›
  "Mac feel (testing)" (DEVSWITCHES; compiled out of App Store builds).

## SwiftUI and performance
- Nothing blocking in `body`: no system-enumeration or XPC-backed call (speech voices, capture devices, fonts, photo
  library, file probes). Resolve once into a `static let` or prefetch off-main. When you cache "X doesn't change", check
  every neighbour that reads X.
- Time Profiler is blind to blocked threads (use the `thread-state` schema) and to render-server cost. Prefer
  `xcrun xctrace export` + xpath to the GUI. A tall frame is what's running, not what's causal: diff a good case against
  a bad one.

## Colours (T is colourblind)
- Hex literals in code. Never choose or describe a colour by how it looks, and never ask T to confirm a colour visually.

## Environment
- T's phone: iPhone 17 Pro Max, iOS 27. Team `8XM4B5F42Y`, bundle `com.doctorpresident.airpad`. Deployment floor iOS
  26.0: no `#available` checks at or below it.
