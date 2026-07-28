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


ORT (ONNX RUNTIME) KOKORO — DROP THE ONNX MODEL HERE  (added 2026-07-28)
=======================================================================
The new ORTKokoroTTSEngine (Kokoro on ONNX Runtime CPU — the pivot off Core ML/
BNNS + MLX/Metal) needs ONE more file in THIS folder:

  3.  kokoro-v1_0.onnx                (~326 MB — fp32 Kokoro ONNX model)

WHERE TO GET IT
---------------
Download `onnx/model.onnx` (326 MB, fp32, self-contained — NO external _data file)
from Hugging Face:
  https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/blob/main/onnx/model.onnx
Rename it to `kokoro-v1_0.onnx` and place it here:
  AirPad/Resources/Kokoro/kokoro-v1_0.onnx

It REUSES the existing voices.npz (same 256-dim style vectors, same voice ids) —
you do NOT need a separate voices file for the ORT engine.

The loader resolves it via:
  Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "onnx", subdirectory: "Kokoro")

int8 note: quantized variants (model_quantized.onnx ~92 MB, model_q8f16 ~86 MB)
exist in the same repo — a follow-up size win, NOT for M1 (do fp32 first).
Gitignored like the others.
