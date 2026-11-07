#!/usr/bin/env python3
"""Validate all embedded arm64 Mach-O images without launching the application."""
import argparse
import json
from pathlib import Path
from macho_bundle import graph, SYSTEM_PREFIXES

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--manifest', type=Path)
parser.add_argument('--standalone', action='store_true', help='Reject non-system dependencies and rpaths outside the app')
args = parser.parse_args()
app = args.app.resolve()
nodes = graph(app)
external = sorted(str(p) for p in nodes if not p.is_relative_to(app))
if args.standalone:
    if external: raise SystemExit('External dependencies remain:\n' + '\n'.join(external))
    for path, node in nodes.items():
        for raw in node['rpaths']:
            if raw.startswith('/') and not raw.startswith(SYSTEM_PREFIXES):
                raise SystemExit(f'External rpath: {path.name}: {raw}')
report = {'architecture': 'arm64', 'image_count': len(nodes), 'external_images': external}
if args.manifest: args.manifest.write_text(json.dumps(report, indent=2) + '\n')
print(f'PASS: {len(nodes)} Mach-O images resolved; external images: {len(external)}; no app launched.')
