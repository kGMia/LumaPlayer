#!/usr/bin/env python3
"""Short visible native-player acceptance. Real Metal/CoreAudio, no synthetic metrics.
--interact adds pause, seek and speed changes; not a throughput benchmark.
"""
import argparse,json,subprocess,time,sys,uuid,statistics,re
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from scripts.ipc import command
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('--fps',type=int,choices=[48,60],default=48);p.add_argument('--interact',action='store_true');a=p.parse_args()
tag=f'realtime-{a.fps}-'+('interactions-' if a.interact else '')+time.strftime('%Y%m%d-%H%M%S')
base=root/'benchmarks/results'/tag;sock=f'/private/tmp/iive-{uuid.uuid4().hex}.sock'
def cmd(*args):
 r=command(list(args),sock)
 if r['error']!='success':raise RuntimeError(str(r))
 return r.get('data')
def quantile(v,q):return sorted(v)[max(0,int(len(v)*q+.999)-1)] if v else None
with base.with_suffix('.log').open('w') as log:
 child=subprocess.Popen([str(root/'build/IIVE-Player.app/Contents/MacOS/IIVE-Player'),'--input',str(a.input.resolve()),'--fps',str(a.fps),'--mute','--ipc',sock,'--metrics',str(base.with_suffix('.jsonl'))],stdout=log,stderr=log)
 actions=[];start=time.monotonic();phase=0;paused_at=None;was_ready=False
 try:
  while time.monotonic()-start<50:
   if child.poll() is not None:raise RuntimeError(f'Player exited: {child.returncode}')
   if not Path(sock).exists():time.sleep(.1);continue
   response=command(['get_property','vf-metadata/iive-rife'],sock)
   if response['error']=='property unavailable':time.sleep(.1);continue
   if response['error']!='success':raise RuntimeError(str(response))
   meta=response['data']
   if a.interact:
    if phase==0 and int(meta.get('generated','0'))>10:
     cmd('set_property','pause',True);paused_at=time.monotonic();phase=1
     actions.append({'action':'pause','metadata':meta})
    elif phase==1 and time.monotonic()-paused_at>.6:
     assert cmd('get_property','pause') is True
     # Rapid seeks while GPU work can still be in flight; old generations must not escape.
     cmd('set_property','pause',False);time.sleep(.01);cmd('seek',8,'absolute+exact');time.sleep(.01);cmd('seek',2,'absolute+exact')
     actions.append({'action':'seek8_then2_resume'});phase=2
    elif phase==2 and int(meta.get('generation','0'))>=2 and int(meta.get('generated','0'))>35:
     cmd('set_property','speed',2);actions.append({'action':'speed2'});phase=3
   if cmd('get_property','eof-reached'):
    final={'filter':meta,'dropped':cmd('get_property','frame-drop-count'),'audio_driver':cmd('get_property','current-ao'),'pause':cmd('get_property','pause')}
    # Exercises the fixed CoreAudio CFString helper too.
    final['audio_device_count']=len(cmd('get_property','audio-device-list'))
    break
   time.sleep(.15)
  else:raise TimeoutError('Playback did not reach EOF in 50s')
 finally:
  if child.poll() is None:
   try:cmd('quit')
   except (RuntimeError,OSError):child.terminate()
  child.wait(timeout=20)
rows=[json.loads(x) for x in base.with_suffix('.jsonl').read_text().splitlines()]
active=[x for x in rows if not x['paused'] and not x['seeking'] and x['filter'].get('state')=='active' and isinstance(x['media_pts'],(float,int)) and x['media_pts']>1]
ms=[float(x['filter']['processing_ms']) for x in active]
# A successful overload fallback is still normal playback; include it for A/V checks.
playing=[x for x in rows if not x['paused'] and not x['seeking']]
av=[abs(x['avsync_s']) for x in playing if isinstance(x['avsync_s'],(float,int))]
rate=[x['render_callbacks_per_s'] for x in active if x['render_callbacks_per_s'] is not None]
log=base.with_suffix('.log').read_text();frames=[(float(x),int(y),int(z)) for x,y,z in re.findall(r'output pts=([\d.\-]+) synthesized=(\d) generation=(\d+)',log)]
ordered=all(b[2]>=x[2] and (b[2]!=x[2] or b[0]>x[0]) for x,b in zip(frames,frames[1:]))
summary={'kind':'visible_native_player_short_smoke','target_fps':a.fps,'interactions':actions,'exit_code':child.returncode,'final':final,'ordered_pts_per_generation':ordered,'sampled_processing_ms_mean':statistics.mean(ms) if ms else None,'sampled_processing_ms_p50':quantile(ms,.5),'sampled_processing_ms_p95':quantile(ms,.95),'render_callbacks_per_s_mean':statistics.mean(rate) if rate else None,'avsync_abs_s_p95':quantile(av,.95),'max_sampled_queue':max(int(x['filter'].get('queued','0')) for x in rows),'fallback_observed':any(x['filter'].get('fallback')=='yes' for x in rows),'display_fps':None,'sustained_realtime_verified':False}
summary['passed']=child.returncode==0 and ordered and int(final['filter'].get('generated','0'))>0 and final['audio_driver']=='coreaudio' and bool(av) and summary['max_sampled_queue']<=8 and (not a.interact or phase==3)
base.with_suffix('.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2));print(base.with_suffix('.json'))
raise SystemExit(0 if summary['passed'] else 1)
