#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks
xcrun clang -Wall -Wextra -Werror tests/HDRMathSmoke.c -o build/checks/hdr-math
build/checks/hdr-math
xcrun clang -Wall -Wextra -Werror tests/HDRClockSmoke.c -o build/checks/hdr-clock
build/checks/hdr-clock
