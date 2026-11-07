#!/usr/bin/env python3
"""Relocate runtime code/resources into a staging app. Never edits source libraries."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from macho_bundle import graph

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
resources = app / 'Contents/Resources'
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
helper = app / 'Contents/MacOS/ffmpeg'
ffmpeg = Path(shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg').resolve()
if not ffmpeg.is_file(): raise SystemExit('Install FFmpeg before packaging.')
shutil.copy2(ffmpeg, helper)
nodes = graph(app)
targets, used = {}, {}
for source in nodes:
    target = source if source.is_relative_to(app) else frameworks / source.name
    if target in used and used[target] != source:
        raise SystemExit(f'Library basename collision: {source.name}')
    used[target] = source; targets[source] = target
    if target != source: shutil.copy2(source, target)

inventory = []
kegs = set()
for source, node in nodes.items():
    target = targets[source]
    target.chmod(target.stat().st_mode | 0o200)
    archs = subprocess.check_output(['lipo', '-archs', str(target)], text=True).split()
    if 'arm64' not in archs: raise SystemExit(f'No arm64 slice: {source}')
    if len(archs) > 1:
        thin = target.with_name(target.name + '.arm64')
        subprocess.run(['lipo', str(target), '-thin', 'arm64', '-output', str(thin)], check=True)
        thin.replace(target)
    changes = []
    for dep, resolved in node['dependencies'].items():
        relative = os.path.relpath(targets[resolved], target.parent)
        replacement = '@loader_path/' + relative
        if dep != replacement: changes += ['-change', dep, replacement]
    if node['identity'] and target.parent == frameworks:
        changes += ['-id', '@rpath/' + target.name]
    for rpath in set(node['rpaths']):
        if rpath.startswith('/') and not rpath.startswith(('/usr/lib/', '/System/Library/')):
            changes += ['-delete_rpath', rpath]
    if changes:
        subprocess.run(['install_name_tool', *changes, str(target)], check=True)
    if not source.is_relative_to(app):
        inventory.append({'file': str(target.relative_to(app)), 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
        if '/Cellar/' in str(source):
            parts = source.parts; i = parts.index('Cellar'); kegs.add(Path(*parts[:i+3]))

# Locate package bundles next to the actual linked library, not an arbitrary
# build directory. SwiftPM's generated accessors search Bundle.main resources.
resource_sets = {'libIIVERIFE.dylib': ('RifeMetal_RifeMetal.bundle', 'RifeMetal_RifeMetalCore.bundle'),
                 'libIIVEFSR.dylib': ('FSRCNNXMetal_FSRCNNXMetal.bundle',)}
for library, bundles in resource_sets.items():
    origin = next((p for p in nodes if p.name == library), None)
    if origin is None: raise SystemExit(f'Missing native engine: {library}')
    for name in bundles:
        source = origin.parent / name
        if not source.is_dir(): raise SystemExit(f'Missing SwiftPM resources: {source}')
        shutil.copytree(source, resources / name, dirs_exist_ok=True)
for name in ('RifeMetal_RifeMetal.bundle/Contents/Resources/rife-v4.26.rmw',
             'RifeMetal_RifeMetalCore.bundle/Contents/Resources/default.metallib',
             'RifeMetal_RifeMetalCore.bundle/Contents/Resources/NV12Input.metal',
             'RifeMetal_RifeMetalCore.bundle/Contents/Resources/NV12Output.metal',
             'FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/default.metallib',
             'FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/Resources/fsrcnnx8.json',
             'FSRCNNXMetal_FSRCNNXMetal.bundle/Contents/Resources/Resources/fsrcnnx16.json'):
    path = resources / name
    if not path.is_file() or path.stat().st_size == 0: raise SystemExit(f'Missing model resource: {name}')

notices = resources / 'RuntimeLicenses'
notices.mkdir(exist_ok=True)
packages = []
# Keep installed upstream notices, exact source recipes and SBOMs with the code.
# These local artifacts are copied as data; no external scripts are executed.
kegs.add(ffmpeg.parent.parent)
for keg in sorted(kegs):
    destination = notices / (keg.parent.name + '-' + keg.name)
    destination.mkdir(exist_ok=True)
    license_files = [p for p in keg.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT', 'NOTICE', 'AUTHORS', 'LGPL-', 'GPL-', 'MIT.', 'APACHE-', 'BSD-'))]
    if not license_files:
        license_files = [p for p in (keg/'share').rglob('*') if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT', 'NOTICE'))]
    if not license_files: raise SystemExit(f'No license notice found for {keg.name}; do not publish an incomplete bundle.')
    for p in license_files:
        dest = destination / p.relative_to(keg); dest.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(p, dest)
    for name in ('sbom.spdx.json', 'INSTALL_RECEIPT.json'):
        if (keg/name).exists(): shutil.copy2(keg/name, destination/name)
    if (keg/'.brew').exists(): shutil.copytree(keg/'.brew', destination/'recipe', dirs_exist_ok=True)
    packages.append({'name': keg.parent.name, 'version': keg.name, 'notices': str(destination.relative_to(resources))})
for source, name in ((root/'vendor/rife-metal/LICENSE','RifeMetal-LICENSE'),
                     (root/'vendor/rife-metal/THIRD-PARTY.md','RIFE-weights-NOTICE.md'),
                     (root/'.research/mpv-native/LICENSE.GPL','mpv-LICENSE.GPL')):
    shutil.copy2(source, notices/name)
shutil.copytree(root/'plugin/licenses', notices/'shader-licenses', dirs_exist_ok=True)
(resources/'RuntimeDependencies.json').write_text(json.dumps({'architecture':'arm64', 'libraries':inventory, 'packages':packages,
    'preview_helper_sha256':hashlib.sha256(ffmpeg.read_bytes()).hexdigest(),
    'tls_ca_file':'/etc/ssl/cert.pem'}, indent=2) + '\n')
print(f'Bundled {len(inventory)} libraries, FFmpeg and three model resource bundles.')
