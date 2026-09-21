#!/bin/sh
# Corpus SHAPE metadata — Brief M. Numbers only, no node content. READ-ONLY.
# Usage: ./run.sh [corpus-root]
# Default root is the AirPad iCloud Documents container.
ROOT="${1:-$HOME/Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents}"
exec python3 "$(dirname "$0")/corpus_shape.py" "$ROOT"
