# CLAUDE.md — AirPad working conventions

Authoritative operating conventions for any Claude Code session in this repo. Read fully before acting. These are deterministic rules, not suggestions — each one exists because it has already bitten us. If anything in auto-memory contradicts this file, this file wins.

## Where project state lives
- Live project state is in the **Ops repo** (`~/Developer/Ops`: `status.md`, `today.md`, `queue.md`), **not Notion.** Notion was abandoned 2026-06; ignore any memory note pointing at Notion entry points for orientation.
- Companion (the planning Claude) writes briefs; you implement them. T verifies on device.

## Build & run
- **You can build.** Toolchain is stable Xcode 26.6 (GA) at `/Applications/Xcode.app`. Use a
  per-command `DEVELOPER_DIR` prefix — never a global `xcode-select` flip:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirPad.xcodeproj -scheme AirPad -destination 'generic/platform=iOS' -configuration Release build 2>&1 | grep -E "error:|BUILD"`
- TestFlight: `scripts/testflight_upload.sh` (archives Release, exports, uploads via altool;
  build number auto-uniqued from the timestamp).
- **A green build is NOT a verified change. This is the rule that matters.** Never write
  "shipped", "working", "fixed", or "done" because a build succeeded. A build proves it
  compiles — nothing more. T verifies on device; only T's explicit confirmation makes a change
  verified. (This file previously said "you cannot build, so you cannot know." The toolchain
  claim was true of the 26.5 beta only. The epistemics survive the toolchain: compiling is not
  knowing.)

## Project structure (XcodeGen)
- `project.yml` is the source of truth. `AirPad.xcodeproj/project.pbxproj` is **generated**.
- Adding, removing, or renaming a source file: edit `project.yml`, then run `xcodegen generate`. Tell T so he regenerates/reopens in Xcode.
- **Never hand-edit `project.pbxproj`.** It will be overwritten, and manual edits corrupt the project.

## Verify-on-disk gate (non-negotiable)
- Before every build, paste the `git diff` of your changes. Reported edits have silently failed to land on disk more than once — the diff is the proof the change is real and on the right branch.
- After any edit, re-read the file you changed to confirm it landed before moving on. "I edited it" is not evidence; the file on disk is.

## Commit / verify handshake
- You manage git yourself, via the **CLI** (not Xcode's git UI), proactively — **but hold every commit until T has device-verified that change/phase.** Committing ahead of verification is the standing failure mode; don't.
- Flow: implement → paste `git diff` → build (you headlessly, or T via Xcode GUI, or TestFlight) → **T verifies on device** → T confirms → **then** you commit via CLI, **then you push** (`git push`). One commit per task/phase. Who runs the build is incidental; T's device verification is not.
- A landed commit is "committed, pending verification" — never "shipped" or "working" until T says so. Push only follows a verified, committed change.

## Branch topology (non-negotiable)
- A device-verified arc **merges to `main` when it closes.** "Pushed to its own branch" is **not** done — an unmerged branch means the next arc, if branched from `main`, silently lacks it (this is exactly how the chat arc went missing from the whole card-catalog line for a weekend).
- **New branches are created FROM `main`.** Before `git checkout -b`, run `git branch --show-current` and confirm you're on `main` (or pass `main` explicitly *and* know why). Branching off `main` while another feature branch is checked out is the trap: you inherit `main`, not the branch you're looking at.

## Scope discipline
- Smallest reversible change that satisfies the task. One commit per task/brief.
- Don't refactor or "improve" adjacent code unless asked.

## SwiftUI body discipline — nothing blocking in `body`
- **Never call a system-enumeration or XPC-backed API from inside a SwiftUI `body`.** They
  **block rather than spin**, so a default Time Profiler cannot see them, and they cost whole
  seconds of dropped frames. Suspects: `AVSpeechSynthesisVoice.speechVoices()`,
  `AVCaptureDevice.devices()`, font enumeration, photo-library queries, file-system probes —
  anything crossing an XPC boundary.
- Resolve once into a `static let`, or prefetch off-main at service init, and read the cache
  from `body`. BUG 5 (2026-07-14): `SpeechSynthesisService.availableVoices` was a computed
  `static var` read once per message per body eval → 782ms of main-thread `semaphore_wait`
  per panel resize.
- **When you cache something because "X doesn't change at runtime," check every neighbour that
  depends on the same X.** In BUG 5, `bestVoice` was correctly cached as a `static let` with
  exactly that comment — thirty lines below the uncached property that caused the bug.

## Profiling (Instruments)
- **Time Profiler has TWO blind spots. Both have already cost a full session.**
  1. **Blocked threads.** It samples RUNNING threads only. With `record-waiting-threads="0"`
     (the default) a main thread blocked 782ms produces **zero samples**. An innocent-looking
     Time Profiler is NOT an exoneration — it is a fork: spinning → Time Profiler has it;
     blocked → only the `thread-state` schema has it.
  2. **Render-server cost.** Offscreen composites run in another process; they are not in your
     app's samples at all.
- **Prefer the CLI over the Instruments GUI.** `xcrun xctrace export --input <trace> --toc`,
  then xpath the schemas. Confirmed present and useful: `thread-state`, `context-switch`,
  `hitches`, `potential-hangs`, `time-profile` (symbolicated), `syscall`. BUG 5 was found this
  way in one pass, after the GUI produced nothing across an evening.
- **A tall frame is what is RUNNING, not what is CAUSAL.** Always diff a working case against
  a broken case. Never name the tallest symbol in a single window.

## Colors (T is colorblind)
- Use hex literals only in code (e.g. Klein Blue `#1B59C2`, Mango `#E8820A`, Electric Cyan `#00BFFF`). Hex exists for code verifiability.
- Never choose or describe a color by how it looks, and never ask T to confirm a color visually.

## Environment
- Repo: `~/Developer/AirPad`. Test device: iPhone 17 Pro Max, iOS 26.x. Team ID `8XM4B5F42Y`. Bundle ID `com.doctorpresident.airpad`.

---
This file is the authoritative convention source. Incidental code-facts (canonical helpers like `MediaThumbnailLoader.shared`, framework quirks found in passing) belong in CC's auto-memory; durable rules belong here; live state belongs in the Ops repo.
