#!/usr/bin/env python3
"""Bundle shader models, license notices and app icon resources."""
from pathlib import Path
import sys, shutil

root = Path(__file__).resolve().parents[1]
app_resources = Path(sys.argv[1])

# 1. Shaders
shaders_dir = app_resources / 'Shaders'
shaders_dir.mkdir(parents=True, exist_ok=True)
for channels in (8, 16):
    name = f'FSRCNNX_x2_{channels}-0-4-1.glsl'
    shader_path = root / 'plugin/shaders' / name
    if shader_path.exists():
        shader = shader_path.read_text()
        shader = shader.replace('//!DESC ', f'//!DESC IIVE FSRCNNX {channels} / ')
        (shaders_dir / name).write_text(shader)

# These earlier experimental files are not valid trained model exports.
# Remove stale copies on incremental builds; retain unrelated resources.
for name in ('fsrcnnx8_fp16.bin', 'fsrcnnx16_fp16.bin', 'weights_manifest.json'):
    (app_resources / 'Models' / name).unlink(missing_ok=True)

# 3. Licenses
for name in ('LICENSE', 'THIRD-PARTY.md', 'LittleCMS-LICENSE'):
    license_path = root / name
    if license_path.exists():
        shutil.copy2(license_path, app_resources / name)

# 4. AppIcon (AppIcon.icns & AppIcon.icon)
app_icon_icns = root / 'AppIcon.icns'
if app_icon_icns.exists():
    shutil.copy2(app_icon_icns, app_resources / 'AppIcon.icns')

app_icon_bundle = root / 'AppIcon.icon'
if app_icon_bundle.exists():
    dst_bundle = app_resources / 'AppIcon.icon'
    if dst_bundle.exists():
        shutil.rmtree(dst_bundle)
    shutil.copytree(app_icon_bundle, dst_bundle)

# 5. Patch generated Info.plist if present
info_plist = app_resources.parent / 'Info.plist'
if info_plist.exists():
    import plistlib
    try:
        with open(info_plist, 'rb') as f:
            data = plistlib.load(f)
        data['CFBundleIconFile'] = 'AppIcon'
        data['CFBundleIconName'] = 'AppIcon'
        with open(info_plist, 'wb') as f:
            plistlib.dump(data, f)
    except Exception:
        pass
