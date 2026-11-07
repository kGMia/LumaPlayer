#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prerequisites: uv and Python 3.13. Only this workspace's environment is changed.
if [[ ! -x build/span-toolchain/bin/python ]]; then
    uv venv --python python3.13 build/span-toolchain
fi
uv pip install --python build/span-toolchain/bin/python --cache-dir build/uv-cache \
    -r native/SPANCoreML/requirements-conversion.txt
uv pip freeze --python build/span-toolchain/bin/python --cache-dir build/uv-cache > build/span-toolchain-resolved.txt
