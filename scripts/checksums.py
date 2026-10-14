#!/usr/bin/env python3
from pathlib import Path
from hashlib import sha256
dist=Path(__file__).resolve().parents[1]/'dist'
artifacts=sorted(list(dist.glob('*.zip'))+list(dist.glob('*.iinaplgz')))
(dist/'SHA256SUMS').write_text(''.join(f'{sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in artifacts))
