# Font sources for MSDF atlas baking

These files are **build-time inputs, not app resources** — they live outside `AirPad/` so
XcodeGen's `sources: - path: AirPad` glob never bundles them. An unregistered bundled `.ttf`
would be dead weight in the `.app`.

Re-bake with `scripts/rebake_msdf_atlases.sh`.

## SpaceGrotesk-Bold.ttf

The Map's orb-title face. Added in **Brief BD1** because only the pre-baked atlas shipped —
there was no source font, which meant the atlas could not be regenerated (that is how the
ASCII-only charset survived into V1) and its OFL notice could not be honoured.

| | |
|---|---|
| Source | <https://github.com/floriankarsten/space-grotesk> (the designer's canonical repo) |
| Downloaded | 2026-09-26, `master` archive |
| Cut | `fonts/ttf/static/SpaceGrotesk-Bold.ttf` — the static Bold matching the shipping atlas |
| Version | `Version 2.000; ttfautohint (v1.8.3)` |
| PostScript name | `SpaceGrotesk-Bold` |
| Variable? | No — static instance (no `fvar`) |
| Licence | SIL OFL 1.1, © 2020 The Space Grotesk Project Authors |

★ **Verified against the previously shipped atlas before adoption:** every ASCII advance
(U+0020–U+007E) is byte-for-byte identical and `lineHeight` matches (1.276), so re-baking
from this release does not re-wrap a single existing Map title.

The licence text ships with the app at
`AirPad/Resources/Fonts/SpaceGrotesk/SpaceGrotesk-OFL.txt` — an MSDF atlas is a derivative of
the font outlines, so the notice must travel with the build even though the `.ttf` does not.

## msdf-charset.txt

The charset every shipping atlas is baked with. **Keep it wide.** A character absent from the
atlas is silently dropped on the Map (Brief BC0/BD3), so narrowing this re-introduces the bug:

- `[32,126]` ASCII
- `[160,255]` Latin-1 Supplement — accents plus `¿ ¡` (Spanish, French, German, Portuguese, Italian)
- `[256,383]` Latin Extended-A — `œ Œ š ž`, Polish/Czech/Turkish
- en/em dash, curly quotes, bullet, ellipsis — the punctuation the app itself produces
