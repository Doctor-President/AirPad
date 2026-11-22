#!/bin/zsh
# Sweep 2b · 3.3 — fetch the Qwen3.5 4B MLX 4-bit weights ONCE onto this Mac (no tokens needed), pinned to a commit,
# then verify every file's size against the Hugging Face API and the sha256 of the LFS files.
# The phone never downloads: run_on_phone.sh copies this folder over USB.
#
#   spikes/iphone-2b/fetch_weights.sh            # → build/iphone-spike/models/Qwen3.5-4B-MLX-4bit/
#   spikes/iphone-2b/fetch_weights.sh --verify   # verify only
set -euo pipefail
REPO=mlx-community/Qwen3.5-4B-MLX-4bit
REV=32f3e8ecf65426fc3306969496342d504bfa13f3          # pinned (lastModified 2026-03-02)
ROOT=${0:A:h:h:h}
DEST=$ROOT/build/iphone-spike/models/Qwen3.5-4B-MLX-4bit
# README / .gitattributes are not needed to load; everything else is (the vision files are tiny, the vision tensors
# inside model.safetensors are dropped at load by Qwen35Model.sanitize).
FILES=(config.json chat_template.jinja model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json
       vocab.json preprocessor_config.json processor_config.json video_preprocessor_config.json)

avail_gb=$(df -g / | awk 'NR==2 {print $4}')
if (( avail_gb < 15 )); then echo "STOP: only ${avail_gb} GB free on / (need ≥ 15)"; exit 3; fi

mkdir -p $DEST
if [[ ${1:-} != --verify ]]; then
  for f in $FILES; do
    echo "· $f"
    curl -fL --retry 5 --retry-delay 5 -C - -o $DEST/$f "https://huggingface.co/$REPO/resolve/$REV/$f" || {
      # -C - on a complete file returns 416; treat as done and let the verify step judge it.
      [[ -f $DEST/$f ]] || exit 1; }
  done
fi

echo "verifying against the HF API ($REPO @ $REV)"
curl -fsS "https://huggingface.co/api/models/$REPO/tree/$REV" > $DEST.hf-tree.json
python3 -I - $DEST <<'PY'
import hashlib, json, os, sys
dest = sys.argv[1]
tree = {f["path"]: f for f in json.load(open(dest + ".hf-tree.json")) if f["type"] == "file"}
bad = 0; total = 0
for name in sorted(os.listdir(dest)):
    if name.startswith("."): continue
    p = os.path.join(dest, name); size = os.path.getsize(p); total += size
    want = tree.get(name)
    if want is None: print(f"  ?? {name} not in the repo"); bad += 1; continue
    ok = size == want["size"]
    line = f"  {'ok' if ok else 'BAD'} {name} {size} (api {want['size']})"
    oid = (want.get("lfs") or {}).get("oid")
    if ok and oid:
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 24), b""): h.update(chunk)
        ok = h.hexdigest() == oid; line += f" sha256 {'ok' if ok else 'MISMATCH'}"
    print(line); bad += 0 if ok else 1
print(f"  total {total} bytes ({total / 1e9:.2f} GB)")
sys.exit(1 if bad else 0)
PY
echo "weights OK: $DEST"
