# Two-device harness — Mac batch B1e / B2

Scratch only. Nothing here can reach a real library: every root is a folder under `build/`, the Simulators have no
iCloud, and the DEBUG flags refuse a path inside `Mobile Documents` / `CloudDocs`.

| script | what |
|---|---|
| `matrix.py <debug.app> <udidA> <udidB> <out>` | the matrix: two Simulators (A = "iPhone", B = "Mac"), one library, `fakecloud.py` between them. Scenarios S1–S7; writes `<out>/matrix.{json,md}` |
| `fakecloud.py <H> A B` | stand-in for iCloud between the replicas `H/A/library`, `H/B/library` (and `H/cloud`): uploads/downloads by who changed what; a file changed on both keeps the cloud's version current and stores the other as a conflict version (`nodes/<id>/.conflicts/…`, `.conflicts/<file>/…`); `H/<R>/offline` takes a replica offline |
| `upgrade.sh <old.app> <new-release.app> <new-debug.app> <udid> <out>` | an older build's library → 1.0.2: nothing lost, stamps appear, an edit after the update merges with one saved before it |
| `compare_upgrade.py <out>` | the upgrade check (run by upgrade.sh) |

App flags (DEBUG only):
- `-TwoDeviceRoot <abs path>` — the library root, used in place (no copy). Comes before `-UITestLibrary`, which the
  harness passes only to skip the Sample Library seed.
- `-TwoDeviceCommands <dir>` — the command channel (`cmd-*.json` → `done-*.json`; ops in `TwoDeviceHarness.swift`).
  Commands go through the same store calls as the UI. `type` mirrors unsaved typing the way the open editor does.
- `-SyncDeviceID` / `-SyncDeviceName` — who this instance is; `-SyncPollSeconds 1` — rescan by modification dates
  (the stand-in's writes aren't file-coordinated, so no `NSFilePresenter` callbacks).
- `-TwoDeviceSelfTest` — the pure merge/funnel self-test (`selftests.tsv`).

Stand-ins for iCloud states the Simulator can't produce: `nodes/<id>/.conflicts/*.json` (= NSFileVersion conflict
versions), `nodes/<id>/.node.json.icloud` (= a placeholder), `nodes/<id>/.harness-not-current` (= a newer version
still downloading).

What only a real two-device pass shows (T's pass, `Ops/design-refs/mac-b/two-device-pass.md`): iCloud's timing and
its real choice in conflicts and edit-vs-delete, `NSFilePresenter` callbacks, placeholders and download states.
