#!/usr/bin/env python3
"""Fetch ONLY the pinned official SPAN x2/48 checkpoint, not the 1.2GB image archive."""
import hashlib
from pathlib import Path
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://drive.usercontent.google.com/download?id=1iYUA2TzKuxI0vzmA-UXr_nB43XgPOXUg&export=download&confirm=t'
SHA256 = '561fd5cf419a23d4de1231ce258180f61aee4aa8caa1aaaa783769c7301847bc'

def main():
    directory = ROOT / '.research/span'
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / 'spanx2_ch48.pth'
    if output.exists():
        if hashlib.sha256(output.read_bytes()).hexdigest() != SHA256:
            raise ValueError('Existing checkpoint checksum mismatch')
    else:
        # Known first member, compressed size 16,781,361; never execute archive code.
        payload = subprocess.check_output(['curl', '--fail', '--location', '--silent',
            '--show-error', '--max-time', '120', '--max-filesize', '17000000',
            '--range', '0-16781447', URL])
        if len(payload) != 16781448 or payload[:4] != b'PK\x03\x04':
            raise ValueError('Server did not return the expected ZIP range')
        fields = struct.unpack_from('<4s5H3I2H', payload)
        name_length, extra_length = fields[-2:]
        if payload[30:30+name_length] != b'spanx2_ch48.pth' or fields[3] != 8:
            raise ValueError('Unexpected ZIP member')
        decoder = zlib.decompressobj(-15)
        checkpoint = decoder.decompress(payload[30+name_length+extra_length:], 17905042)
        if len(checkpoint) != 17905041 or not decoder.eof:
            raise ValueError('Invalid decompressed checkpoint size')
        if hashlib.sha256(checkpoint).hexdigest() != SHA256:
            raise ValueError('Official checkpoint checksum mismatch')
        output.write_bytes(checkpoint)
    print(output)

if __name__ == '__main__':
    main()
