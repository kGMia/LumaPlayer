#!/usr/bin/env python3
from pathlib import Path
import zipfile,json
root=Path(__file__).resolve().parents[1]
version=json.loads((root/'plugin/Info.json').read_text())['version']
output=root/f'dist/IINA-Video-Enhancer-{version}-source.zip'
excluded={'.git','.research','.cache','node_modules','build','.build','.swiftpm','dist','__pycache__'}
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
 for p in root.rglob('*'):
  rel=p.relative_to(root)
  if not p.is_file() or any(part in excluded for part in rel.parts) or p.name=='.DS_Store' or rel.parts[:2]==('benchmarks','fixtures'):continue
  z.write(p,Path('IINA-Video-Enhancer')/rel)
print(output)
