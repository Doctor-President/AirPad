# CLAUDE.md — AirPad working conventions

Authoritative operating conventions for any Claude Code session in this repo. Read fully before acting. These are deterministic rules, not suggestions — each one exists because it has already bitten us. If anything in auto-memory contradicts this file, this file wins.

## Where project state lives
- Live project state is in the **Ops repo** (`~/Developer/Ops`: `status.md`, `today.md`, `queue.md`), **not Notion.** Notion was abandoned 2026-06; ignore any memory note pointing at Notion entry points for orientation.
- Companion (the planning Claude) writes briefs; you implement them. T verifies on device.

## Build & run
- `xcodebuild` is **broken** on the current toolchain (Xcode 26.5 beta). Do not use it to build or to judge success — its output is unreliable.
- The only valid build is **Build & Run from the Xcode GUI**, run by T. You implement; T builds. Never claim a build "passes" or "compiles" — you cannot build, so you cannot know.

## Project structure (XcodeGen)
- `project.yml` is the source of truth. `AirPad.xcodeproj/project.pbxproj` is **generated**.
- Adding, removing, or renaming a source file: edit `project.yml`, then run `xcodegen generate`. Tell T so he regenerates/reopens in Xcode.
- **Never hand-edit `project.pbxproj`.** It will be overwritten, and manual edits corrupt the project.

## Verify-on-disk gate (non-negotiable)
- Before every build, paste the `git diff` of your changes. Reported edits have silently failed to land on disk more than once — the diff is the proof the change is real and on the right branch.
- After any edit, re-read the file you changed to confirm it landed before moving on. "I edited it" is not evidence; the file on disk is.

## Commit / verify handshake
- You manage git yourself, via the **CLI** (not Xcode's git UI), proactively — **but hold every commit until T has device-verified that change/phase.** Committing ahead of verification is the standing failure mode; don't.
- Flow: implement → paste `git diff` → T builds via Xcode GUI and verifies on device → T confirms → **then** you commit via CLI, **then you push** (`git push`). One commit per task/phase.
- A landed commit is "committed, pending verification" — never "shipped" or "working" until T says so. Push only follows a verified, committed change.

## Branch topology (non-negotiable)
- A device-verified arc **merges to `main` when it closes.** "Pushed to its own branch" is **not** done — an unmerged branch means the next arc, if branched from `main`, silently lacks it (this is exactly how the chat arc went missing from the whole card-catalog line for a weekend).
- **New branches are created FROM `main`.** Before `git checkout -b`, run `git branch --show-current` and confirm you're on `main` (or pass `main` explicitly *and* know why). Branching off `main` while another feature branch is checked out is the trap: you inherit `main`, not the branch you're looking at.

## Scope discipline
- Smallest reversible change that satisfies the task. One commit per task/brief.
- Don't refactor or "improve" adjacent code unless asked.

## Colors (T is colorblind)
- Use hex literals only in code (e.g. Klein Blue `#1B59C2`, Mango `#E8820A`, Electric Cyan `#00BFFF`). Hex exists for code verifiability.
- Never choose or describe a color by how it looks, and never ask T to confirm a color visually.

## Environment
- Repo: `~/Developer/AirPad`. Test device: iPhone 17 Pro Max, iOS 26.x. Team ID `8XM4B5F42Y`. Bundle ID `com.doctorpresident.airpad`.

---
This file is the authoritative convention source. Incidental code-facts (canonical helpers like `MediaThumbnailLoader.shared`, framework quirks found in passing) belong in CC's auto-memory; durable rules belong here; live state belongs in the Ops repo.
