# 1.1 store assets: raw stills and preview clips

Directive `2026-11-01-companion-1.1-closeout-A-assets`, items 1, 2 and 4. Raw material for T to compose: no captions,
no frames, no overlays. Everything is the Sample Library (plus two synthetic entries, below) on the bench build of the
1.1 candidate (AirPad `ws-1.1d` 50021d9 + harness `ws-1.1-store` 7f015e4: Release, the shipping UI, no DEBUG chrome).

**What's in git and what isn't:** `stills/` and `clips/` (about 1 GB) stay on this Mac (`.gitignore` here; GitHub refuses
files over 100 MB and Ops holds no media this size). Committed: this README, `manifest.md`, `fps.md` and the contact sheets.

## Apple's current specs (checked 2026-11-01)

- **Screenshots** ([Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)):
  the one required iPhone size today is **"iPhone with Dynamic Island (medium display)"**: 1206 × 2622 or 1179 × 2556
  portrait (iPhone 17 Pro / 16 Pro / 15 Pro). The larger sizes (Dynamic Island large: 1320 × 2868, 1290 × 2796,
  1260 × 2736) are optional. 1–10 per size; PNG or JPEG, no alpha. AirPad is iPhone-only (`TARGETED_DEVICE_FAMILY "1"`),
  so no iPad sizes are needed.
  → Shot on **iPhone 17 Pro (1206 × 2622, the required size)** and also **iPhone 17 Pro Max (1320 × 2868, optional,
  the largest)**. The PNGs are opaque.
- **App previews** ([App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/)):
  15–30 s, **at most 30 fps**, H.264 (up to High Profile 4.0) in .mov/.m4v/.mp4, 10–12 Mbps target, ≤ 500 MB, up to 3 per
  size; portrait **886 × 1920** for every Face ID / Dynamic Island iPhone. Audio optional (none recorded).
  → Clips are recorded raw at **1206 × 2622** (iPhone 17 Pro), H.264. T scales to 886 × 1920 and exports at 30 fps.

## Measured clip frame rate (not the setting)

`simctl io recordVideo` writes a frame only when the screen changes, so the average over a clip with still handles is low.
`fps.md` lists, per clip, the frames in each whole second: the **median while moving** and the **busiest second**.
Measured on this Mac: Map pans 63–108 frames in the busiest second; the Map at rest redraws about 14–15 frames/s
(its idle rate); the Librarian's streaming text up to 109. Every clip has more than the 30 fps a preview can use.

## The shots (file names: `<shot>-<what>-<appearance>.png`)

1. **Map in a Pro look on a custom background** (`01-map-…`): Aura dark on navy→violet and on deep teal · Wash light on
   sand and on sky→cream · Glass dark on ink blue and on plum · Riso light on cream · Riso dark on forest · Gradient dark on
   midnight · Outline light on paper. Each launch frames the Map's opening view (one territory fills most of it); a
   pinched-out variant wasn't possible headlessly (an XCUITest pinch panned the Map and lifted the Librarian instead).
2. **Librarian** (`02-…`): empty, typed, the answer streaming (every third second: `-t00`, `-t03`, …), finished with
   superscript citations, and with its numbered sources open. The answer is Apple's on-device model (Apple Intelligence)
   answering from the Sample Library; it varies a little per run.
3. **Share sheet over Safari** (`03-…`): a neutral article page ("Five rules for a slower cup", written for this, CC0
   photo), the system share sheet, AirPad's sheet over Safari. The page is served from this Mac as `brewing-notes.local`.
4. **Entry with text, a table and an image** (`04-…`): a synthetic coffee entry: top (cover photo), body (text, photo
   and table together: `04-entry-table`), further down.
5. **Every look for the grid** (`05-look-…`): Flat, Glass, Aura / Wash, Riso, Gradient, Outline × dark / light, default
   backgrounds.
6. **Private** (`06-…`): List with the private entry hidden, ≡ menu "Show private" (before), the Face ID prompt, the
   menu after Face ID ("Hide private"), the List with it showing; and the Face ID lock on open with its prompt.
7. **Export** (`07-…`): entry menu, the Export sheet with "Save to folder…", the system folder picker, saved, and Files
   showing `Pour-over, dialled in.md` + `attachments/`.
8. **Bring your own model** (`08-…`): Settings, Your own models showing "Ollama 0.13.2", the Models list (Qwen3 8B
   in memory; Qwen3 4B and Qwen3 30B-A3B to download). A fake server, never T's: the field reads **http://127.0.0.1:11435**
   (T chose this over a sudo loopback alias for 192.168.1.20); retype or crop when composing.

Extras: everything above in both appearances where it makes sense, on both devices.

## Clips (`clips/`, iPhone 17 Pro, 2–3 s still handle before and after each beat)

- `clip-map-glide-slow-*` / `clip-map-glide-normal-*`: two long pans (120 and 600 pt/s), Aura dark and Wash light.
- `clip-open-entry-*`: Map → List → the coffee entry → scroll to the table.
- `clip-share-from-safari-*`: Safari → Share → AirPad → its sheet.
- `clip-librarian-stream-*`: open the Librarian, ask, the answer streams to the end.
- `clip-look-<look>-<appearance>-<background>`: one per look / background cut (the shot-1 pairings and every look on its
  default background), the Map settling then a gentle drift.

## Content notes

- **Synthetic entries** added to the Sample scratch library: "Pour-over, dialled in" (text, a 4 × 3 table, two photos)
  and "Birthday ideas for Sam" (private). Photos: Wikimedia Commons "Manual drip (pour-over) coffee.jpg" and "Drip brewing
  (Unsplash).jpg", both **CC0**. No T entries, server addresses or machine names anywhere.
- **Territory colours change per launch** of the Sample Library (a known property of the sample seed), so the same
  look can wear a different colour in two stills. Pick per still.
- **Clips show the Dynamic Island as a black pill** at the top: the Simulator draws it into the recording even with the
  mask off (`--mask ignored`). The stills don't have it. Mask or crop it when editing.
- The status bar is overridden to 9:41, full signal and battery. The Files stills show "◀ AirPad" (the system's back
  link after Save to folder); that's real.
