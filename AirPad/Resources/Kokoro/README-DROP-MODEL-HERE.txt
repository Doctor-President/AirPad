KOKORO TTS SPIKE — DROP THE MODEL + VOICES HERE
================================================

This folder is a *folder reference* in the Xcode project: anything placed in it
is bundled into the app under the runtime subdirectory "Kokoro/". The code looks
for exactly these two filenames (case-sensitive):

  1.  kokoro-v1_0.safetensors        (~600 MB — the model weights)
  2.  voices.npz                     (the voice styles, ~a few MB)

Put BOTH files directly in this folder:

  AirPad/Resources/Kokoro/kokoro-v1_0.safetensors
  AirPad/Resources/Kokoro/voices.npz

WHERE TO GET THEM
-----------------
The reference project mlalma/KokoroTestApp bundles both under its /Resources
(Git-LFS). The model also lives at Blaizzy/mlx-audio (Kokoro-82M, SafeTensors).
The voices .npz is a NumPy zip mapping voice-id -> style array (e.g. af_heart,
am_adam, bf_emma, bm_george). 28 English voices is normal; the sampler shows
whatever ids are actually in the file.

DO NOT rename the files. The loader in KokoroTTSEngine.swift resolves them via:
  Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors", subdirectory: "Kokoro")
  Bundle.main.url(forResource: "voices",      withExtension: "npz",         subdirectory: "Kokoro")

AFTER DROPPING THE FILES
------------------------
Just build & run on device (Debug). No xcodegen re-run needed — a folder
reference bundles whatever is inside at build time. Open Settings ->
(developer section) -> "Kokoro Voice Sampler" to warm the model and sample
voices. If the files aren't present, the sampler shows this same instruction.

NOTE: ~600 MB in the app bundle makes the Debug .app large but is fine on
device. Production plan (not built): on-demand resources / download-on-first-use.
These files are gitignored — they never get committed.
