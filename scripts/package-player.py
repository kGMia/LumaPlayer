#!/usr/bin/env python3
"""Bundle, sign, validate and publish the modern arm64 player without launching it."""
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import os
import hashlib
import argparse
from macho_bundle import is_macho

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('configuration', nargs='?', choices=('Debug', 'Release'), default='Debug')
parser.add_argument('--source-app', type=Path, help='Use a signed Xcode product from another DerivedData directory')
args = parser.parse_args()
configuration = args.configuration
source = (args.source_app or root / 'build/Xcode/Build/Products' / configuration / 'Luma Player.app').resolve()
destination = root / 'build/Luma Player.app'
if not (source / 'Contents/Info.plist').is_file():
    raise SystemExit(f'Build the Luma Player scheme first; product not found: {source}')
source_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
if source_info.get('CFBundleIdentifier') != 'com.august.lumaplayer':
    raise SystemExit('Refusing to package a product with a different bundle identifier.')
# A valid code signature alone does not make an expired development profile runnable.
profile = source / 'Contents/embedded.provisionprofile'
if profile.exists():
    decoded = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)]))
    expires = decoded.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise SystemExit('Development profile expired. Renew Personal Team signing in Xcode before packaging.')
with tempfile.TemporaryDirectory(prefix='player-package-', dir=root / 'build') as temporary:
    staged = Path(temporary) / destination.name
    subprocess.run(['ditto', str(source), str(staged)], check=True)
    # Reuse the exact existing Personal Team identity and expanded entitlements.
    certificate = str(Path(temporary) / 'signing-cert-')
    subprocess.run(['codesign', '-d', '--extract-certificates=' + certificate, str(source)], check=True)
    identity = hashlib.sha1(Path(certificate + '0').read_bytes()).hexdigest().upper()
    entitlements = Path(temporary) / 'entitlements.plist'
    raw = subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(source)])
    plistlib.loads(raw)  # Fail before replacing the delivery if extraction failed.
    entitlements.write_bytes(raw)
    subprocess.run([sys.executable, str(root / 'scripts/bundle-player-runtime.py'), str(staged)], check=True)
    for binary in sorted({p.resolve() for p in staged.rglob('*') if is_macho(p)}):
        if '.framework/' not in str(binary):
            subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(binary)], check=True)
    for framework in sorted(staged.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(framework)], check=True)
    subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none',
                    '--entitlements', str(entitlements), str(staged)], check=True)
    info = plistlib.loads((staged / 'Contents/Info.plist').read_bytes())
    for key in ('CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
        if not info.get(key):
            raise SystemExit(f'Missing bundle metadata: {key}')
    for name in ('LICENSE', 'THIRD-PARTY.md', 'MSAL-LICENSE', 'AppIcon.icns',
                 'Shaders/FSRCNNX_x2_8-0-4-1.glsl', 'Shaders/FSRCNNX_x2_16-0-4-1.glsl'):
        if not (staged / 'Contents/Resources' / name).is_file():
            raise SystemExit(f'Missing resource: {name}')
    linkage = Path(temporary) / 'linkage.json'
    subprocess.run([sys.executable, str(root / 'scripts/check-app-linkage.py'), str(staged), '--standalone', '--manifest', str(linkage)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
    # Keep the previous working delivery until validation completes. Rename on
    # the same volume; restore the backup if publication fails.
    backup = Path(temporary) / 'previous.app'
    if destination.exists():
        destination.rename(backup)
    try:
        staged.rename(destination)
    except BaseException:
        if backup.exists(): backup.rename(destination)
        raise
    # Update compatibility aliases only after the new signed app is validated.
    aliases = [root / 'build/PersonalTeam/Luma Player.app']
    for index, alias in enumerate(aliases):
        alias.parent.mkdir(parents=True, exist_ok=True)
        previous_alias = Path(temporary) / f'previous-alias-{index}.app'
        if alias.exists() or alias.is_symlink(): alias.rename(previous_alias)
        try:
            os.symlink(os.path.relpath(destination, alias.parent), alias, target_is_directory=True)
        except BaseException:
            if previous_alias.exists() or previous_alias.is_symlink(): previous_alias.rename(alias)
            raise
    report = { 'built_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'configuration': configuration, 'bundle_id': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'app': str(destination), 'scope': 'self-contained arm64 runtime; Personal Team development signing, not notarized',
        'linkage': json.loads(linkage.read_text()),
        'gui_tested': False }
    (root / 'build/player-delivery.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'Delivered: {destination}')
