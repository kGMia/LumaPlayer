#!/usr/bin/env python3
"""Short loopback-only network/DAV/filter integration check. No GUI or real credentials."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from ipc import command

requests = []
auth = 'Basic ' + base64.b64encode(b'test:test-only').decode()

with tempfile.TemporaryDirectory(prefix='iive-network-') as scratch:
    temp = Path(scratch)
    clip = temp / 'clip.mp4'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=256x128:rate=24:duration=1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                    '-color_range', 'tv', '-movflags', '+faststart', str(clip)], check=True, timeout=20)
    payload = clip.read_bytes()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args): pass
        def reply(self, status, body=b'', **headers):
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            for key, value in headers.items(): self.send_header(key.replace('_', '-'), value)
            self.end_headers()
            if self.command != 'HEAD':
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
        def do_PROPFIND(self):
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if self.headers.get('Authorization') != auth:
                return self.reply(401, WWW_Authenticate='Basic realm="test"')
            if self.path.startswith('/redirect'):
                return self.reply(302, Location='/unexpected-dav/')
            assert self.headers.get('Depth') == '1'
            self.reply(207, b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/clip.mp4</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>', Content_Type='application/xml')
        def do_HEAD(self): self.do_GET()
        def do_GET(self):
            requests.append((self.path, self.headers.get('Authorization')))
            if self.path == '/chain.mp4':
                return self.reply(302, Location='/second.mp4')
            if self.path == '/second.mp4':
                return self.reply(307, Location=f'http://localhost:{self.server.server_port}/signed?token=test-only')
            if self.path.startswith('/redirect.mp4'):
                return self.reply(302, Location='/unexpected.mp4')
            if self.path.startswith('/dav/') and self.headers.get('Authorization') != auth:
                return self.reply(401, WWW_Authenticate='Basic realm="test"')
            start, end = 0, len(payload)-1
            requested = self.headers.get('Range')
            if requested:
                parts = requested.removeprefix('bytes=').split('-')
                start = int(parts[0] or 0); end = min(end, int(parts[1])) if parts[1] else end
            if start >= len(payload): return self.reply(416)
            headers = {'Content_Type': 'video/mp4', 'Accept_Ranges': 'bytes'}
            if requested: headers['Content_Range'] = f'bytes {start}-{end}/{len(payload)}'
            self.reply(206 if requested else 200, payload[start:end+1], **headers)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    base = f'http://127.0.0.1:{server.server_port}'
    swift = str(ROOT / 'build/checks/network-media-smoke')
    subprocess.run([swift], check=True, timeout=15)
    subprocess.run([swift, '--dav', base + '/dav/'], check=True, timeout=20)
    options = json.loads(subprocess.check_output([swift, '--options', base + '/dav/clip.mp4']))
    resolved = json.loads(subprocess.check_output([swift, '--resolve', base + '/chain.mp4']))
    assert 'http-header-fields' not in resolved['options']
    assert resolved['options']['demuxer-lavf-format'] == 'mov'
    assert any(path == '/chain.mp4' and header == auth for path, header in requests)
    assert any(path == '/second.mp4' and header == auth for path, header in requests)
    assert all(header is None for path, header in requests if path.startswith('/signed'))
    socket = str(temp / 'mpv.sock')
    log_path = ROOT / 'benchmarks/results/network-redirect-20261019.log'
    def ipc(args): return command(args, socket)
    def get(name): return ipc(['get_property', name]).get('data')
    def wait_for(predicate, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate(): return
            if process.poll() is not None: raise RuntimeError('mpv exited; inspect smoke log')
            time.sleep(.05)
        raise TimeoutError('Network playback smoke timeout')
    with log_path.open('w') as log:
        process = subprocess.Popen([str(ROOT / 'build/mpv/mpv'), '--no-config', '--vo=null', '--ao=null', '--hwdec=no',
            '--idle=yes', '--keep-open=yes', '--input-terminal=no', '--msg-level=all=v', f'--input-ipc-server={socket}',
            '--vf=@iive-rife:iive-rife=fps=48:tier=fast:fallback=no,@iive-sr:iive-fsrcnnx=tier=fast:fallback=no'], stdout=log, stderr=log)
        try:
            wait_for(lambda: Path(socket).exists())
            assert ipc(['loadfile', base + '/dav/clip.mp4', 'replace', -1, options])['error'] == 'success'
            wait_for(lambda: get('eof-reached') is True)
            rife, sr, output = get('vf-metadata/iive-rife'), get('vf-metadata/iive-sr'), get('video-out-params')
            assert int(rife['generated']) > 0 and rife['fallback'] == 'no', rife
            assert sr['state'] in ('active', 'finished') and sr['fallback'] == 'no', sr
            assert output['w'] == 512 and output['h'] == 256, output
            assert int(sr['emitted']) == 48, sr
            assert any(path.startswith('/dav/') and header == auth for path, header in requests)
            # Per-file Authorization must disappear on the next uncredentialed file.
            assert ipc(['loadfile', base + '/public.mp4', 'replace'])['error'] == 'success'
            wait_for(lambda: any(path == '/public.mp4' for path, _ in requests))
            assert all(header is None for path, header in requests if path == '/public.mp4')
            # The resolver follows the redirect, preserves format across opaque CDN
            # URLs, and passes no Basic credentials to the different origin.
            assert ipc(['loadfile', resolved['url'], 'replace', -1, resolved['options']])['error'] == 'success'
            wait_for(lambda: get('path') == resolved['url'] and get('eof-reached') is True)
            assert get('video-out-params')['w'] == 512
            assert all(header is None for path, header in requests if path.startswith('/signed'))
            # mpv itself must still never forward credentials across redirects.
            assert ipc(['loadfile', base + '/redirect.mp4', 'replace', -1, options])['error'] == 'success'
            wait_for(lambda: any(path == '/redirect.mp4' for path, _ in requests))
            wait_for(lambda: get('idle-active') is True)
            assert not any(path == '/unexpected.mp4' for path, _ in requests)
            result = {'result': 'PASS', 'network_input': 'HTTP Basic authenticated MP4, 256x128/24 SDR',
                      'output': '512x256/48', 'rife_generated': int(rife['generated']), 'sr_emitted': int(sr['emitted']),
                      'per_file_auth_reset': True, 'redirect_blocked': True, 'resolved_cdn_playback': True, 'cross_origin_auth_stripped': True,
                      'note': 'Small loopback integration check, not a real-time or GUI benchmark; WAN, HLS and RTSP untested.'}
            print(json.dumps(result, indent=2))
            (ROOT / 'benchmarks/results/network-redirect-20261019.json').write_text(json.dumps(result, indent=2)+'\n')
        finally:
            if process.poll() is None:
                ipc(['quit'])
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown(); server.server_close()
