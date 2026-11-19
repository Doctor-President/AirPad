---
name: librarian-gauntlet
description: Verify any Librarian Ask / delivery change (retrieval, packet building, prompt shape, ModelRouter streaming, ChatSession.send, tool choice / web) through T's REAL path (app → AirPad Host → Ollama, or the own-server route) and run the -LibrarianGauntlet table. Read before touching the Librarian.
---
# Librarian: the Host path and the gauntlet (standing rules, Briefs BR + BU)

Nothing goes back to T until the table is green, and the table goes in the CC report. Never change T's Ollama /
LM Studio models or settings; run a scratch Host from source, never T's installed .app. Gauntlet case notes contain
T's titles: report case IDs only.

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

## Scripts
- `scripts/gauntlet/` (cases.json, gauntlet.py, drive.zsh, compare_runs.py). `scripts/gauntlet/run.sh` can't find /
  quit / restore T's Host when it runs from an AppTranslocation path — check before using it.
- Own-server route (Ollama / LM Studio as a "server"): `zsh scripts/server/gauntlet_routes.sh <host|server> <model> <sim>
  <app> <out> [extra args]` (no +x; run via zsh), DEBUG `-GauntletRoute endpoint`.
- A launch-arg `-Key` outranks `UserDefaults.set` and `set(string(forKey:))` persists it into the app domain — clean
  the app-container plist after a run that set endpoints.
