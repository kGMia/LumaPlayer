#!/usr/bin/env python3
"""Bounded native adapter check. No GUI, audio or real-time performance claim."""
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root))
from scripts.ipc import command

result = root / ('benchmarks/results/rife-nv12-adapter-' + time.strftime('%Y%m%d-%H%M%S') + '.json')
log_path = result.with_suffix('.log')
with tempfile.TemporaryDirectory(prefix='iive-nv12-') as temp, log_path.open('w') as log:
    socket = str(Path(temp) / 'mpv.sock')
    child = subprocess.Popen([
        str(root / 'build/mpv/mpv'), '--no-config', '--audio=no', '--vo=null',
        '--hwdec=no', '--untimed=yes', '--frames=48', '--keep-open=yes', '--idle=yes',
        '--msg-level=iive-rife=trace', '--input-ipc-server=' + socket,
        '--vf=@iive-rife:iive-rife=fps=48:tier=fast:fallback=no',
        str(root / 'benchmarks/fixtures/tagged-720p24.mov')
    ], stdout=log, stderr=log)
    meta = {}
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError(f'mpv exited early: {child.returncode}')
            if Path(socket).exists():
                response = command(['get_property', 'vf-metadata/iive-rife'], socket)
                if response.get('error') == 'success':
                    meta = response['data']
                    if int(meta.get('emitted', '0')) >= 8:
                        break
            time.sleep(.01)
        else:
            raise TimeoutError('No eight-frame output within 45 seconds')
        assert meta.get('input_path') == 'nv12-metal', meta
        assert int(meta.get('generated', '0')) > 0, meta
        assert meta.get('fallback') == 'no', meta
        command(['quit'], socket)
        child.wait(timeout=15)
        assert child.returncode == 0
        log.flush()
        frames = [(float(p), int(s)) for p, s in re.findall(r'output pts=([0-9.]+) synthesized=(\d)', log_path.read_text())]
        assert len(frames) >= 8, frames
        assert all(abs(b[0] - a[0] - 1/48) < 1e-8 for a, b in zip(frames, frames[1:])), frames
        result.write_text(json.dumps({
            'kind': 'bounded_null_output_adapter_check', 'passed': True,
            'filter': meta, 'exit_code': child.returncode,
            'requested_output_limit': 48, 'adapter_emitted': len(frames),
            'generated_observed': sum(s for _, s in frames), 'pts_step_48fps_verified': True,
            'presentation_verified': False, 'realtime_performance_verified': False
        }, indent=2) + '\n')
        print(result)
    except Exception as error:
        result.write_text(json.dumps({'kind': 'bounded_null_output_adapter_check',
                                     'passed': False, 'error': str(error), 'filter': meta}, indent=2) + '\n')
        raise
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=15)
