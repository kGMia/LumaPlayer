#!/usr/bin/env python3
"""Convert the audited official v4.25 Lite archive. Never imports archive code.
Run with a Python environment containing PyTorch and NumPy. --archive avoids network.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://drive.usercontent.google.com/download?id=1zlKblGuKNatulJNFf5jdB-emp9AqGK05&export=download'
SHA256 = 'e84366c23e0eb1a637a55aad2e4f3442ec2bf4c388043b4aabbf590be289e6e8'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    import torch  # fail before downloading if the conversion dependency is absent
    workspace = ROOT / '.research/rife-v4.25-lite'
    workspace.mkdir(parents=True, exist_ok=True)
    archive = args.archive or workspace / 'official.zip'
    if not args.archive:
        if not archive.exists():
            with urllib.request.urlopen(URL, timeout=45) as response:
                payload = response.read(32 * 1024 * 1024 + 1)
            if len(payload) > 32 * 1024 * 1024:
                raise ValueError('Unexpected archive size')
            archive.write_bytes(payload)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError('Official archive checksum mismatch; refusing conversion')
    members = ('flownet.pkl', 'IFNet_HDv3.py', 'RIFE_HDv3.py')
    sources = {}
    with zipfile.ZipFile(archive) as z:
        for name in members:
            # Explicit known members only: no extractall, traversal or executable imports.
            data = z.read('train_log/' + name)
            (workspace / name).write_bytes(data)
            sources[name] = hashlib.sha256(data).hexdigest()
    output = ROOT / 'build/models/rife-v4.25-lite.rmw'
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / 'vendor/rife-metal/tools/convert-weights.py'),
                    '--model', 'rife-v4.25-lite', '--pytorch-checkpoint', str(workspace / 'flownet.pkl'),
                    '--out', str(output)], check=True)
    manifest = {'model': 'rife-v4.25-lite', 'status': 'experimental; not player default',
                'source_url': URL, 'archive_sha256': SHA256, 'source_sha256': sources,
                'output_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'license': 'MIT', 'license_url': 'https://github.com/hzwer/Practical-RIFE/blob/main/LICENSE',
                'weight_license_declaration': 'https://github.com/hzwer/Practical-RIFE#trained-model',
                'torch_version': torch.__version__, 'channels': [192,128,96,64,24],
                'scales': [32,16,8,4,1], 'stage_mask': 'replace', 'internal_alignment': 128}
    shutil.copy2(ROOT/'vendor/rife-metal/THIRD-PARTY.md', output.parent/'Practical-RIFE-NOTICE.md')
    output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(output)

if __name__ == '__main__':
    main()
