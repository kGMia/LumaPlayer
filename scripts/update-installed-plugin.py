#!/usr/bin/env python3
"""Explicit local upgrade of this project's existing plugin, with a backup."""
from pathlib import Path
import shutil, zipfile, json, datetime
root=Path(__file__).resolve().parents[1]
dest=Path.home()/'Library/Application Support/com.colliderli.iina/plugins/org.iina-community.video-enhancer.iinaplugin'
if not dest.is_dir():raise SystemExit('Plugin not installed; install the .iinaplgz using IINA.')
if json.loads((dest/'Info.json').read_text())['identifier']!='org.iina-community.video-enhancer':raise SystemExit('Unexpected identifier')
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
backup=root/f'build/installed-plugin-before-update-{stamp}.zip'
if not backup.exists():
 with zipfile.ZipFile(backup,'w',zipfile.ZIP_DEFLATED) as z:
  for p in dest.rglob('*'):
   if p.is_file():z.write(p,p.relative_to(dest))
for p in (root/'plugin').rglob('*'):
 if p.is_file():
  out=dest/p.relative_to(root/'plugin');out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,out)
print('Updated installed plugin. Restart IINA to reload. Backup:',backup)
