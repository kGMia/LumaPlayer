#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
app="$PWD/build/Luma HDR Prototype.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .cache/clang
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror -mmacosx-version-min=27.0 \
    native/HDRPrototype/main.m native/HDRPrototype/HDRFrame.m -framework AppKit -framework Metal -framework QuartzCore -framework AVKit -framework AVFoundation -framework CoreVideo -framework CoreMedia -framework UniformTypeIdentifiers \
    -o "$app/Contents/MacOS/LumaHDRPrototype"
cat native/HDRPrototype/HDRMath.h native/HDRPrototype/Pattern.metal > "$app/Contents/Resources/Pattern.metal"
python3 - "$app" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='LumaHDRPrototype',CFBundleIdentifier='com.august.lumaplayer.hdrprototype',CFBundleName='Luma HDR Prototype',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='27.0',NSHighResolutionCapable=True),f)
PY
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built (not launched): %s\n' "$app"
