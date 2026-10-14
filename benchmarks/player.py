#!/usr/bin/env python3
"""Opt-in GPU shader / CPU-motion player matrix through a DEDICATED mpv IPC instance.
Do not point at normal user playback. Measures render passes, drops and A/V drift;
never substitutes filtered FPS for display FPS. Restores live option snapshots.
"""
import argparse,json,time,sys,statistics
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from ipc import command
p=argparse.ArgumentParser();p.add_argument('--socket',required=True);p.add_argument('--fixture',required=True);p.add_argument('--seconds',type=int,default=10);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
def cmd(*args):
 r=command(list(args),a.socket)
 if r['error']!='success':raise RuntimeError(r)
 return r.get('data')
def get(k):
 try:return cmd('get_property',k)
 except RuntimeError:return None
old={k:get(k) for k in ['glsl-shaders','vf','hwdec','pause','loop-file']}
if old['glsl-shaders'] is None or old['vf'] is None:sys.exit('Cannot snapshot player options')
results=[]
try:
 cmd('loadfile',str(Path(a.fixture).resolve()),'replace');cmd('set_property','loop-file','inf');cmd('set_property','pause',False)
 for mode in ['off','fsrcnnx','motion48','motion60','fsrcnnx+motion48','fsrcnnx+motion60']:
  cmd('set_property','glsl-shaders',old['glsl-shaders']+([str(root/'plugin/shaders/FSRCNNX_x2_8-0-4-1.glsl')] if 'fsrcnnx' in mode else []))
  cmd('set_property','vf',old['vf']);cmd('set_property','hwdec','no' if 'motion' in mode else old['hwdec'])
  if 'motion' in mode:cmd('vf','add',f'@iive-benchmark:lavfi=[minterpolate=fps={48 if "48" in mode else 60}:mi_mode=mci:mc_mode=obmc:me_mode=bidir:vsbmc=0:scd=fdiff:scd_threshold=10]')
  time.sleep(2);d0=get('frame-drop-count');samples=[]
  for _ in range(a.seconds):
   time.sleep(1);passes=get('vo-passes');samples.append({'filtered_fps':get('estimated-vf-fps'),'avsync':get('avsync'),'dropped':get('frame-drop-count'),'vo_passes':passes})
  d1=get('frame-drop-count')
  results.append({'mode':mode,'source':get('video-params'),'viewport':get('osd-dimensions'),'source_fps':get('container-fps'),'samples':samples,'dropped_delta':None if d0 is None or d1 is None else max(0,d1-d0),'measured_output_fps':None,'cpu_utilization':None,'gpu_utilization':None,'memory':None,'player_realtime':'inspect samples; filtered FPS alone is insufficient'})
finally:
 for k,v in old.items():
  if v is not None:
   try:cmd('set_property',k,v)
   except Exception:pass
 Path(a.output).write_text(json.dumps(results,indent=2))
