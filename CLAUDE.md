# CLAUDE.md — AirPad working conventions

Authoritative operating conventions for any Claude Code session in this repo. Read fully before acting. These are deterministic rules, not suggestions — each one exists because it has already bitten us. If anything in auto-memory contradicts this file, this file wins.

## Where project state lives
- Live project state is in the **Ops repo** (`~/Developer/Ops`: `status.md`, `today.md`, `queue.md`), **not Notion.** Notion was abandoned 2026-06; ignore any memory note pointing at Notion entry points for orientation.
- Companion (the planning Claude) writes briefs; you implement them. T verifies on device.

## Build & run
- **You can build.** Toolchain is stable **Xcode 27.0 (GA)** at `/Applications/Xcode.app` (iOS 27.0
  runtime `24A434`; T moved to macOS 27 on 2026-09-16 — was Xcode 26.6). Use a
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

## Librarian changes — verify THROUGH THE HOST, not direct Ollama (standing rule, Brief BR)
- **Any change to the Librarian Ask/delivery path (retrieval, packet building, prompt shape,
  `ModelRouter` streaming, `ChatSession.send`) MUST be verified on T's REAL path: iOS/Sim app →
  AirPad Host (Mac) → Ollama — NOT by feeding a packet straight to localhost Ollama.** BN's case-1
  "PASS" fed the read packet directly to `localhost:11434` and shipped a build that failed on
  device: the app FOLDED system + a `User:/Assistant:` transcript into ONE user message (Qwen3
  continued the transcript, leaking "Assistant:") **and** never set `options.num_ctx`, so Ollama
  served qwen3:8b's DEFAULT 4096 window and silently TRUNCATED the ~6k-token entry — the footer said
  "Read 1 entry in full" while the model saw only the tail. Direct-Ollama hid both (it got a clean
  2-message chat at num_ctx 32768). The Host relays `messages` + `options` RAW to `/api/chat`
  (`internal/host/chat_translate.go`); the app sends real roles + `options.num_ctx =
  ModelRouter.contextWindowTokens`. **A model's served window is its request `num_ctx`, not its
  architecture max** — check `ollama ps` (the `ctx=` column) and the Host `--observe` line
  (`chat→ollama … num_ctx=… totalChars=…`, presence-only, no content). `prompt_eval_count` ≈ packet
  size ⇒ delivered; a few thousand clamped ⇒ truncated.

## Librarian changes — RUN THE GAUNTLET and paste the table (standing rule, Brief BU)
- **Every Librarian brief runs `-LibrarianGauntlet` end-to-end and pastes the table in its CC
  report. Nothing goes back to T until the table is green.** The gauntlet drives the REAL turn path
  — `LibrarianState.groundedSend` → `ChatSession.send` → `ModelRouter.streamHost` → sealed E2E → a
  locally-run `airpad-host` → Ollama — over the fixture clone, and grades the **delivered answer**
  (required facts present, forbidden claims absent), not an internal decision. Every prior brief
  (BN, BR, BS, BT) verified a decision, passed, and failed on T's device.
- Run it:
  1. Host from source (NEVER T's installed .app): `HOST_SECRET=<S> <bin> --headless --observe
     --listen 127.0.0.1:8799 --ollama 127.0.0.1:11434 --identity <scratch>/identity.key
     --secret-file <scratch>/secret` (a scratch `--secret-file` dir isolates residency/capability
     state from T's real Host).
  2. `hpk` = `curl -s :8799/health -H "Authorization: Bearer $(<bin> --print-token …)"` →
     `hostPublicKey`.
  3. `xcrun simctl launch --console-pty <dev> com.doctorpresident.airpad -CorpusFixture <clone>
     -EmbedCPUOnly -LibrarianGauntlet -DebugHostURL http://127.0.0.1:8799 -DebugHostSecret <S>
     -DebugHostPubKey <hpk>` (the `-DebugHost*` keystone bypasses `parse`'s https/QR requirement —
     DEBUG-only, Release-inert).
- **Read the Host's `--observe` log alongside the app table; it is the authority on what actually
  happened.** `chat→ollama … roles=[system user] lens=[…] num_ctx=…` proves the packet was
  delivered with real roles; `chat done model=… prompt_eval=… truncated=…` names **which model
  answered** and whether Ollama clamped the window.
- **WHICH MODEL ANSWERED is part of every result.** A table can read as "the Librarian is broken"
  when routing, packet and delivery were all perfect and the fault was the model picked: with
  nothing resident the phone fell back to `.first of /v1/models` = install order =
  `llama3.2:latest`, an uncurated dev fixture. Model resolution is now curated-only
  (`ModelRouter.resolveHostModel`); if a facts case fails, check `chat done model=` FIRST.
- New bugs T reports become new cases. A forbidden-phrase list must stay NARROW — "not provided" is
  an honest answer when the fact genuinely isn't in any block (BJ: the Hgb range never extracted), so
  a false FAIL costs as much as a false PASS.

## Done / authorship changes — verify with `-StubAuthorModel` (standing rule, Brief BM)
- **Any change to the Done → model → write path (naming, summarising, the enrichment gate,
  proposals) MUST be verified end-to-end in the Simulator with `-StubAuthorModel` before merge.**
  Foundation Models / Apple Intelligence is **absent in the Simulator**, so the real Done pass
  never runs there — which is exactly why BI, BL, and BM each passed the sim gate and still
  failed on device. The `-StubAuthorModel` stub (in `AIService.processNode`/`processSubstrate`,
  `#if DEBUG`) stands in for FM with a deterministic result and **faithfully reproduces the FM's
  failure mode** (empty title on a derived-only entry), so the write/promote/gate wiring is
  testable headlessly.
- Drive every capture path with `-BMDoneMatrix` (Quick Capture · capture sheet · Link button ·
  link block · share extension) and assert WHICH fields Done wrote, with which provenance. A new
  Done/authorship bug should first be **reproduced as a failing matrix row**, then fixed.
- **TIMING matters more than the path (Brief BO).** BM's matrix injected OG synchronously and
  passed 20/20 while the device still failed — because the real flow is async: a link is appended
  BARE, OG lands later (when `LinkEntryBody` renders), and a debounced eager pass runs in between.
  `-BODoneMatrix` replays the real store sequence across the four timing variants — (a) Done
  before OG, (b) OG then Done, (c) OG → eager → Done, (d) eager-on-bare → OG → Done — and reads
  AFTER the async tail settles. Any Done/link fix must pass ALL FOUR. Corollary: don't hang a
  deterministic outcome (a link's title IS its page title) on the FM/promote/gate chain, which the
  promote-only and late-OG paths bypass — fill it UPSTREAM where every path converges
  (`applyOGFetch`, i.e. the moment the fact is knowable).
- **The matrix must build what the REAL capture builds (Brief BQ).** BM/BO/BP1 each passed their
  store matrix and still failed on device a fourth time — because Quick Capture and the Capture
  screen start with a blank **scaffold Note** item, and the matrices built link nodes WITHOUT it.
  On device the (whitespace) scaffold read as authored content → the link stopped being
  link-dominant → the page-title ghost was skipped → title empty. `-BODoneMatrix` variant (e) now
  includes the scaffold Note. Rule: when a store-level matrix keeps passing while the device fails,
  the matrix is missing something the real screen creates — add it (the scaffold Note here), and
  prefer an **XCUITest that drives the real screen** for anything the store shape can't capture.
  Emptiness is whitespace-trimmed everywhere (`AIService.meaningfulText`) so a blank note never
  counts as content.

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

## Dev tuners (standing rule, T 2026-08-16)
- **Every dev tuner panel MUST have a "Copy values" button** that copies the current settled
  values to the clipboard (a labelled list, ready to paste). T dials on device/TestFlight, and a
  TestFlight reinstall WIPES the UserDefaults the tuner persists to — without a copy button the
  only way back is re-typing from screenshots (which also failed to transfer once). The copy
  button is what makes "T dials, then CC bakes" reliable.
- When baking settled values, use T's pasted/copied list — NEVER read them from a running build.

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
