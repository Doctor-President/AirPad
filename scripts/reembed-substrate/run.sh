#!/bin/bash
# One-off substrate re-embed — NOT shipped app code. See main.swift for why.
#
#   ./scripts/reembed-substrate/run.sh <corpus-root> [--dry-run] [--force]
#
# Compiles the SAME BGEMicro.mlpackage the app bundles and links the app's OWN
# WordPieceTokenizer, so a vector written here is identical to one the app would write.
# Backs the corpus up before writing (the tool refuses to proceed if the backup fails).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="/tmp/airpad-reembed"
mkdir -p "$BUILD"

MLPACKAGE="$REPO/AirPad/Resources/BGE/BGEMicro.mlpackage"
VOCAB="$REPO/AirPad/Resources/BGE/vocab.txt"
TOKENIZER="$REPO/AirPad/Services/WordPieceTokenizer.swift"
MAIN="$REPO/scripts/reembed-substrate/main.swift"

for f in "$MLPACKAGE" "$VOCAB" "$TOKENIZER" "$MAIN"; do
  [[ -e "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

if [[ ! -d "$BUILD/BGEMicro.mlmodelc" ]]; then
  echo "→ compiling BGEMicro.mlpackage …"
  xcrun coremlcompiler compile "$MLPACKAGE" "$BUILD" >/dev/null
fi
cp -f "$VOCAB" "$BUILD/vocab.txt"

echo "→ building the tool …"
xcrun swiftc -O -swift-version 5 \
  -o "$BUILD/reembed-substrate" \
  "$TOKENIZER" "$MAIN" 2>&1 | grep -E "error:" && exit 1 || true

echo "→ running …"
"$BUILD/reembed-substrate" "$@"
