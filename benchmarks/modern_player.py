#!/usr/bin/env python3
"""Focused real-player integration smoke, not a throughput or picture-quality benchmark."""
import json, subprocess, time, uuid, sys, argparse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.ipc import command
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--fi',choices=['rife','apple'],default='rife')
p.add_argument('--sr',choices=['fsrcnnx8','fsrcnnx16','fsrcnnx_metal8','fsrcnnx_metal16','apple'],default='fsrcnnx_metal8')
a=p.parse_args()
tag=f'modern-{a.fi}-{a.sr}-'+time.strftime('%Y%m%d-%H%M%S')
base=root/'benchmarks/results'/tag;sock=f'/private/tmp/iive-{uuid.uuid4().hex}.sock'
app=root/'build/Xcode/Build/Products/Debug/IIVE Player.app/Contents/MacOS/IIVE Player'
def cmd(*args):
    r=command(list(args),sock)
    if r['error']!='success':raise RuntimeError(str(r))
    return r.get('data')
with base.with_suffix('.log').open('w') as log:
    child=subprocess.Popen([str(app),'--input',str(root/'benchmarks/fixtures/720p24.mp4'),'--mute','--fi',a.fi,'--sr',a.sr,'--ipc',sock,'--metrics',str(base.with_suffix('.jsonl'))],stdout=log,stderr=log)
    print('If macOS defers the window, activate IIVE Player in the Dock. This is a foreground GUI check.',flush=True)
    start=time.monotonic();result={'fi':a.fi,'sr':a.sr,'scope':'short real-render integration; no quality or sustained performance acceptance'}
    try:
        while time.monotonic()-start<55:
            if child.poll() is not None:raise RuntimeError(f'player exited {child.returncode}')
            if Path(sock).exists():
                if cmd('get_property','eof-reached'):
                    result['dropped']=cmd('get_property','frame-drop-count')
                    result['audio_driver']=cmd('get_property','current-ao')
                    result['output']=cmd('get_property','video-out-params')
                    break
            time.sleep(.2)
        else:raise RuntimeError('playback timeout')
    except Exception as error:
        result['error']=str(error)
    finally:
        try:cmd('quit')
        except Exception:pass
        try:child.wait(timeout=15)
        except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=10)
        result['exit_code']=child.returncode
    data=[json.loads(line) for line in base.with_suffix('.jsonl').read_text().splitlines()] if base.with_suffix('.jsonl').exists() else []
    label='iive-rife' if a.fi=='rife' else 'iive-fi'
    states=[v.get(label) for v in data if isinstance(v.get(label),dict)]
    result['fi_last']=states[-1] if states else None
    result['fi_active_seen']=any(v.get('state')=='active' for v in states)
    expected_pass='IIVE FSRCNNX 16 / aggregation' if a.sr=='fsrcnnx16' else 'IIVE FSRCNNX 8 / aggregation'
    result['shader_pass_seen']=any(expected_pass in str(v.get('vo-passes')) for v in data)
    sr=[v.get('iive-sr') for v in data if isinstance(v.get('iive-sr'),dict)]
    result['sr_last']=sr[-1] if sr else None
    result['sr_active_seen']=any(v.get('state')=='active' for v in sr)
    result['sr_full_crop']=a.sr!='apple' or (result.get('output',{}).get('crop-w')==1920 and result.get('output',{}).get('crop-h')==1080)
    active=[v for v in data if not v.get('pause') and isinstance(v.get(label),dict) and v[label].get('state')=='active']
    result['render_callbacks_fps_samples']=[round(v['render-callback-fps'],2) for v in active]
    if 'metal' in a.sr:
        expected_backend='fsrcnnx16-mpsgraph' if a.sr=='fsrcnnx_metal16' else 'fsrcnnx8-mpsgraph'
        sr_condition=any(v.get('state')=='active' and v.get('backend')==expected_backend for v in sr)
        result['sr_full_crop']=result.get('output',{}).get('crop-w')==2560 and result.get('output',{}).get('crop-h')==1440
    else:
        sr_condition=result['sr_active_seen'] if a.sr=='apple' else result['shader_pass_seen']
    result['passed']=result['sr_full_crop'] and result['exit_code']==0 and not result.get('error') and result['fi_active_seen'] and sr_condition
    base.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2));print(base.with_suffix('.json'))
    sys.exit(0 if result['passed'] else 1)
