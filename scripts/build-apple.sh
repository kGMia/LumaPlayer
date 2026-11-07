#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Library/Developer/CommandLineTools" ]]; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
mkdir -p build/apple
if xcrun --find metal >/dev/null 2>&1 && xcrun --find metallib >/dev/null 2>&1; then
  xcrun metal -c -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" \
   native/AppleBackend/NV12Normalize.metal -o build/apple/NV12Normalize.air
  xcrun metallib build/apple/NV12Normalize.air -o build/apple/NV12Normalize.metallib
elif [[ ! -f build/apple/NV12Normalize.metallib ]]; then
  echo "error: metallib tool not found and build/apple/NV12Normalize.metallib is missing" >&2
  exit 1
fi
# Embed the compiled library, so loading it never depends on a resource path.
python3 - <<'PY'
from pathlib import Path
data = Path('build/apple/NV12Normalize.metallib').read_bytes()
lines = [','.join(str(b) for b in data[i:i+24]) for i in range(0, len(data), 24)]
Path('build/apple/NV12NormalizeLibrary.h').write_text('static const unsigned char iive_nv12_library[] = {\n' + ',\n'.join(lines) + '\n};\n')
PY
xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=27.0 -arch arm64 -dynamiclib \
 native/AppleBackend/AppleBackend.m native/AppleBackend/NV12Normalizer.m -I build/apple \
 -framework Metal -framework VideoToolbox -framework CoreMedia \
 -framework CoreVideo -framework Foundation -install_name @rpath/libIIVEApple.dylib \
 -o build/apple/libIIVEApple.dylib
