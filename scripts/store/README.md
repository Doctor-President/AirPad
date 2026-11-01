# 1.1 store stills and preview clips (directive 2026-11-01-companion-1.1-closeout-A-assets)

Harness only, on branch `ws-1.1-store`; nothing here ships. Run from a copy of this folder (it writes `out/`, `assets/`).

1. Build the bench app (Release + `-D PANBENCH`: the shipping UI, plus the Sample scratch library, `-ProUnlocked` and
   `-MapGroundDebug`) with the UI tests:
   `xcodebuild -scheme AirPad -configuration Release -destination 'platform=iOS Simulator,id=<sim>' -derivedDataPath build/DD-store-rel OTHER_SWIFT_FLAGS='$(inherited) -D PANBENCH' ENABLE_TESTABILITY=YES build-for-testing`
   (testability only so the hosted unit-test target compiles), then restore `AirPad.xcscheme`.
2. `fetch_assets.sh`; `python3 -m http.server 8765 --bind 127.0.0.1` in `web/`; `dns-sd -P "AirPad store page" _http._tcp local 8765 brewing-notes.local 127.0.0.1`
   (the Safari page's name); the Ollama fake: `FAKE_OLLAMA_VERSION=0.13.2 python3 scripts/gauntlet/restore_fake.py ollama 11435 <dir>`.
3. `setup_sim.sh <sim>` (Sample Library + the two synthetic entries + Face ID enrolled + a Files folder),
   `shoot_map.sh` (shots 1, 5), `batch.sh` (shots 2–4, 6–8, light and dark), `zoomed.sh`, `clips.sh`, then
   `assemble.sh <Ops>/design-refs/1.1-store`.

Gotchas: a failed UI test makes xcodebuild run `simctl diagnose` for up to 10 min (`-collect-test-diagnostics never`);
editing a zsh script while it runs breaks the running copy; the system Face ID panel is in `simctl io screenshot` but not
in `XCUIScreen` grabs; after Safari or Files was in front, AirPad's status bar shows "◀ Safari" until they're closed;
the endpoint field is kept in the Simulator's Keychain (`simctl keychain <sim> reset`); a `.local` name made with
`dns-sd -P` loads in Safari but times out in the app's 5 s detection (so shot 8 uses 127.0.0.1).
