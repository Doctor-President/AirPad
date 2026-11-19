---
name: stash-safe-switch
description: Set work aside or switch commits in an AirPad worktree without losing anything — the stash stack is shared by every worktree and session. Use before any checkout, rebase, A/B build of an older commit, or "park this".
---
# Stash-safe switch

The stash stack is shared by all ~20 AirPad worktrees and any concurrent session. A bare `git stash` / `git stash pop`
can take someone else's entry.

1. Prefer a WIP commit: `git add -A -- <paths> && git commit -m "WIP <tag> (do not push)"`; come back with
   `git reset --soft HEAD~1` when you return. Only on the working branch, never on `main`.
2. If you must stash: `git stash push -u -m "<unique-tag>"`, then immediately
   `git stash list --format='%H %gs' | grep <unique-tag>` and note the SHA. Restore with `git stash apply <sha>`
   (never `pop`), then find the entry's current `stash@{n}` by its tag and `git stash drop stash@{n}`.
3. To build an older commit, don't switch this worktree: `git worktree add --detach build/wt-<tag> <commit>` and
   build there; remove it after (`git worktree remove build/wt-<tag>`).
4. `cd X && git checkout Y` — if `cd` fails the checkout runs in the CURRENT worktree. Use `git -C X checkout Y`.
5. After any switch: `git status --short`, `git log --oneline -1`, `git branch --show-current`.
