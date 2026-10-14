from pathlib import Path
import zipfile, json
root=Path(__file__).resolve().parents[1]
out=root/'dist';out.mkdir(exist_ok=True)
version=json.loads((root/'plugin/Info.json').read_text())['version']
path=out/f'IINA-Video-Enhancer-{version}.iinaplgz'
with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
 for f in sorted((root/'plugin').rglob('*')):
  if f.is_file(): z.write(f, f.relative_to(root/'plugin'))
 z.write(root/'LICENSE','LICENSE')
 z.write(root/'THIRD-PARTY.md','THIRD-PARTY.md')
print(path)
