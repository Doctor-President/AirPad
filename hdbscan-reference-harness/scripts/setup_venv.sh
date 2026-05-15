#!/bin/bash
# HDBSCAN reference harness — venv setup.
# Idempotent: rerunnable; only installs what's missing.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${HARNESS_DIR}/venv"

if [ ! -d "${VENV_DIR}" ]; then
    echo "creating venv at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install --quiet --upgrade pip
pip install --quiet \
    "numpy>=1.26,<3.0" \
    "scipy>=1.11,<2.0" \
    "scikit-learn>=1.4,<2.0" \
    "cython>=0.29,<4.0" \
    "hdbscan>=0.8.40,<1.0"

python3 -c "import hdbscan; from importlib.metadata import version; print('hdbscan', version('hdbscan'), 'ok')"
