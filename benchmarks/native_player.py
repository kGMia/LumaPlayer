#!/usr/bin/env python3
"""Short real native-filter pipeline check; use a one-second 720p24 SDR fixture.
Not an IINA test or a sustained/onscreen performance measurement.
"""
from pathlib import Path
import argparse, subprocess, re, json, time
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('--render',action='store_true');a=p.parse_args()
out=root/'benchmarks/results';out.mkdir(exist_ok=True)
for fps in [48,60]:
 args=[str(root/'build/mpv/mpv'),'--no-config','--vo=null','--ao=null','--untimed','--hwdec=no',f'--vf=iive-rife=fps={fps}:tier=fast:fallback=no','--msg-level=iive-rife=v',str(a.input.resolve())]
 start=time.monotonic();r=subprocess.run(args,capture_output=True,text=True,timeout=60);wall=time.monotonic()-start
 log=r.stdout+r.stderr;(out/f'native-pipeline-{fps}.txt').write_text(log)
 frames=[(float(pts),int(synth)) for pts,synth in re.findall(r'output pts=([\d.\-]+) synthesized=(\d)',log)]
 monotonic=all(b[0]>x[0] for x,b in zip(frames,frames[1:]))
 cadence=all(abs((b[0]-x[0])-1/fps)<2e-8 for x,b in zip(frames,frames[1:]))
 result={'kind':'mpv_native_filter_null_output','target_fps':fps,'exit_code':r.returncode,'output_frames':len(frames),'synthesized_frames':sum(s for _,s in frames),'monotonic_pts':monotonic,'target_cadence':cadence,'wall_seconds':wall,'display_fps':None,'realtime_verified':False,'passed':r.returncode==0 and len(frames)>0 and monotonic and cadence and any(s for _,s in frames)}
 (out/f'native-pipeline-{fps}.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
 if not result['passed']:raise SystemExit(1)
 if a.render:
  r=subprocess.run([str(root/'build/render-smoke'),str(a.input.resolve()),str(fps)],capture_output=True,text=True,timeout=60)
  (out/f'native-render-{fps}.txt').write_text(r.stdout+r.stderr)
  if r.returncode:raise SystemExit(r.returncode)
