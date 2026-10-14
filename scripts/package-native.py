#!/usr/bin/env python3
from pathlib import Path
import shutil,zipfile,json
root=Path(__file__).resolve().parents[1]
src=root/'native/RIFEBackend/.build/release';dst=root/'dist/native-arm64';dst.mkdir(parents=True,exist_ok=True)
for name in ['iive-rife','libIIVERIFE.dylib']:
 shutil.copy2(src/name,dst/name)
for p in list(src.glob('RifeMetal_*.bundle'))+list(src.glob('RifeMetal_*.resources')):
 shutil.copytree(p,dst/p.name,dirs_exist_ok=True)
shutil.copytree(root/'native/RIFEBackend/include',dst/'include',dirs_exist_ok=True)
for srcpath,name in [(root/'LICENSE','LICENSE'),(root/'THIRD-PARTY.md','THIRD-PARTY.md'),(root/'native/RIFEBackend/README.md','README.md'),(root/'vendor/rife-metal/LICENSE','RifeMetal-LICENSE'),(root/'vendor/rife-metal/THIRD-PARTY.md','RIFE-weights-NOTICE.md')]:shutil.copy2(srcpath,dst/name)
print(dst)
version=json.loads((root/'plugin/Info.json').read_text())['version']
archive=root/f'dist/IINA-Video-Enhancer-{version}-native-arm64.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(dst.rglob('*')):
  if p.is_file():z.write(p,Path('native-arm64')/p.relative_to(dst))
print(archive)
