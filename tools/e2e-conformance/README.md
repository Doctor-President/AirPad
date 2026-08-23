# Stage 4 — iOS E2E client (ws-ios-e2e)

Phone-side half of the AirPad Host E2E. **HELD-STACK** (off `main`; does NOT merge until T's
device pass). Built in a **separate git worktree** so the concurrent `spike-entry-spine` work
is untouched — this branch does **not** touch EntryCard / NodeDetailView / GalleryBody /
TextEntryBody or any detail-view rendering file (per the Stage-4 constraint).

## Done + PROVEN this increment
- **`AirPad/Services/HostE2E.swift`** — CryptoKit mirror of the Host's Go `internal/e2e`
  (X25519 + HKDF-SHA256 + AES-256-GCM), matching the frozen key schedule byte-for-byte.
- **`AirPad/Services/HostPairing.swift`** (+ `HostPairingStore.swift`) — parse the QR payload
  `{tunnelURL, protocolVersion, s, hpk}`, derive bearer + E2E master, Keychain persistence.
- **`tools/e2e-conformance/main.swift`** — standalone conformance client compiled with the app's
  real `HostE2E.swift`, run against the **packaged notarized Host `.app`**:
  **ALL GREEN** (E0 e2e=required · E1 request ciphertext · E4 response ciphertext · E3 keyed
  round-trip of a real llama3.2 answer · E2/FS transcript+secret can't open a frame). The
  HostPairing-derived bearer matches the Host's `--print-token` exactly.

## Run the conformance
```bash
# start the packaged Host (production, E2E mandatory):
HOST_SECRET=xxx "…/AirPad Host.app/Contents/MacOS/airpad-host" --headless --listen 127.0.0.1:8844 &
TOKEN=$(HOST_SECRET=xxx "…/airpad-host" --print-token)   # sanity
swiftc -O AirPad/Services/HostE2E.swift tools/e2e-conformance/main.swift -o /tmp/ios-conform
E2E_BASE=http://127.0.0.1:8844 HOST_SECRET=xxx /tmp/ios-conform
```

## Next increment (needs the app build + TF + T device passes; will ship a STAGE-4 TF build)
- **QR scanner UI** ("Connect to your computer" → camera scan → HostPairing) + a Settings entry.
- **ModelRouter E2E integration** — when a HostPairing exists, route chat through the sealed
  envelope path (seal → POST tunnelURL with bearer + pinned UA → open sealed SSE frames).
- **BUG 36 result-hold-and-resume** — assume the stream survives ZERO backgroundings: persist
  streamed deltas incrementally (no loss on drop), detect premature end, reconnect on foreground.
- `xcodegen generate` (adds the new Services files to the target) then a STAGE-4 TF build.
