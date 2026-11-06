# Mac (Catalyst) harness — batch A

Every automated Mac run uses the **isolated copy**, never the signed build: its own bundle ID
(`com.doctorpresident.airpad.macA` → its own sandbox container), ad-hoc signed with App Sandbox and the non-restricted
Mac keys only. **No iCloud, no App Group, no extensions**, so it can never open T's library.

| script | what |
|---|---|
| `isolate.sh <AirPad.app> <out.app>` | make the isolated copy from a Catalyst build (Debug, -O Debug or Release) |
| `shoot_mac.sh <isolated.app> <out>` | stills, light + dark: dashboard map list cards entry chats settings models librarian (`VIEWS="…"` to pick). Drawn in-process by DEBUG `-MacSnapshot`, so it works with the screen locked (`screencapture` returns black then). Catalyst puts sheets in their own window: they land as `<view>-<look>-sheet1.png` |
| `restcpu.sh <app> <label> <settle> <window> <args…>` | CPU% = Δ cpu-time / Δ wall over the window, + RSS |
| `shoot_ios.sh`, `imgdiff.py` | iPhone stills of 6 screens and the mean-|Δ| diff (≤ 1/255) for "iOS unchanged" |
| `sheet.py` | labelled contact sheet |
| `winid.swift` | CGWindowID of a pid's window (for `screencapture -l`, unlocked screen only) |

Gotchas
- Launch the isolated copy with `-ApplePersistenceIgnoreState YES`: after any crash macOS otherwise blocks the next
  launch on a modal "reopen windows?" alert (invisible with the screen locked; the app sits at 0% CPU).
- Release has no DEBUG hooks, and `entryMode` isn't persisted, so Release can't open the Map headlessly: use an -O Debug
  build (`SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s`) for rest-CPU numbers.
- First launch of a fresh scratch embeds the Sample Library for ~30–60 s: settle ≥ 60 s before measuring rest CPU.
- `-MacReport` logs the Mac-sensitive answers (device noun, camera, motion/tilt, DisplaySize vs screen, lock labels,
  local model, min window).
