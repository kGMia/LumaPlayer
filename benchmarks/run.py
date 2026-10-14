#!/usr/bin/env python3
"""Opt-in reproducible matrix. No fabricated entries; failures/timeouts are saved.

python3 benchmarks/run.py --smoke
python3 benchmarks/run.py --full --iterations 30
"""
import argparse,json,subprocess,time,statistics,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();g=p.add_mutually_exclusive_group(required=True);g.add_argument('--smoke',action='store_true');g.add_argument('--full',action='store_true');p.add_argument('--iterations',type=int,default=6);p.add_argument('--timeout',type=int,default=240);a=p.parse_args()
out=ROOT/'benchmarks/results'/time.strftime('run-%Y%m%d-%H%M%S');out.mkdir(parents=True)
binary=ROOT/'native/RIFEBackend/.build/release/iive-rife'
if not binary.exists():sys.exit('Build native backend first: scripts/build-native.sh')
def run(name,args):
 start=time.monotonic()
 try:
  r=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=a.timeout)
  result={'status':'passed' if r.returncode==0 else 'failed','returncode':r.returncode,'wall_seconds':time.monotonic()-start,'stderr':r.stderr}
  try:result['measurement']=json.loads(r.stdout)
  except ValueError:result['stdout']=r.stdout
 except subprocess.TimeoutExpired:result={'status':'timeout','timeout_seconds':a.timeout}
 (out/(name+'.json')).write_text(json.dumps(result,indent=2));print(name,result['status'],flush=True)
for w,h in ([(1280,720)] if a.smoke else [(1280,720),(1920,1080),(3840,2160)]):
 for tier in (['fast'] if a.smoke else ['fast','balanced','hq']):run(f'model-{w}-{h}-{tier}',[binary,'bench',w,h,tier,a.iterations])
 if a.full:
  for source in [24,30,60]:
   fixture=out/f'input-{w}-{h}-{source}.mov'
   r=subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i',f'testsrc2=size={w}x{h}:rate={source}:duration=2','-f','lavfi','-i','sine=frequency=440:duration=2','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-movflags','+write_colr','-c:a','aac',str(fixture)],timeout=a.timeout)
   if r.returncode:continue
   for target in [48,60]:
    if target<=source:continue # already-at-target inputs must not be interpolated
    run(f'motion-{w}-{h}-{source}-{target}',['ffmpeg','-v','info','-benchmark','-i',fixture,'-an','-vf',f'minterpolate=fps={target}:mi_mode=mci:mc_mode=obmc:me_mode=bidir:vsbmc=0:scd=fdiff:scd_threshold=10','-f','null','-'])
    for tier in ['fast','balanced','hq']:
     run(f'pipeline-{w}-{h}-{source}-{target}-{tier}',[binary,'process',fixture,out/f'output-{w}-{h}-{source}-{target}-{tier}.mov',target,tier,'--no-fallback'])
(out/'scope.json').write_text(json.dumps({'input':'generated testsrc2; not natural-video quality validation','GPU_CPU_utilization':None,'stock_IINA_RIFE_combined':'unsupported in stock IINA; separate compile-time mpv adapter exists','player_shader_matrix':'use player.py with a dedicated running IINA IPC instance'},indent=2))
print(out)
