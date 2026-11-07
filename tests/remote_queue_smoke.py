#!/usr/bin/env python3
"""Small authenticated loopback probe and libmpv-hook check; no GUI or GPU."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='iive-remote-queue-') as scratch:
    clip = Path(scratch) / 'clip.mp4'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=256x128:rate=24:duration=1', '-c:v', 'libx264',
                    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(clip)], check=True)
    payload = clip.read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if self.headers.get('Authorization') != 'Basic dGVzdDp0ZXN0LW9ubHk=':
                self.send_error(401); return
            start, end = 0, len(payload)-1
            requested = self.headers.get('Range')
            if requested:
                a, b = requested.removeprefix('bytes=').split('-')
                start = int(a or 0); end = min(end, int(b)) if b else end
            if start >= len(payload): self.send_error(416); return
            self.send_response(206 if requested else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end-start+1))
            if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{len(payload)}')
            self.end_headers()
            try: self.wfile.write(payload[start:end+1])
            except (BrokenPipeError, ConnectionResetError): pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for executable in ['remote-probe-smoke', 'remote-queue-hook-smoke']:
            subprocess.run([str(ROOT/'build/checks'/executable),
                            f'http://127.0.0.1:{server.server_port}/clip.mp4'], check=True, timeout=25)
    finally:
        server.shutdown(); server.server_close()
