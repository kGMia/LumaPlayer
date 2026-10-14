#!/usr/bin/env python3
"""Basic IPC checks against a dedicated running IIVE test player; no UI claim.
Start it with --fi off --sr off --mute --ipc <socket> and a fixture.
This changes that instance's queue, pause, repeat and timing settings.
"""
import argparse, json, sys, time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root))
from scripts.ipc import command
parser=argparse.ArgumentParser()
parser.add_argument('--socket',required=True)
args=parser.parse_args()
base=root/'benchmarks/results'/('player-controls-'+time.strftime('%Y%m%d-%H%M%S'))
report={'scope':'short real-player IPC controls check; not UI or performance acceptance','checks':{}}
def cmd(*values):
    result=command(list(values),args.socket)
    if result.get('error')!='success':raise RuntimeError(str(result))
    return result.get('data')
def wait_for(key,predicate):
    deadline=time.monotonic()+8
    while time.monotonic()<deadline:
        value=cmd('get_property',key)
        if predicate(value):return value
        time.sleep(.1)
    raise TimeoutError(key)
try:
    cmd('set_property','pause',True)
    report['video_bitrate_bps']=cmd('get_property','video-bitrate')
    assert report['video_bitrate_bps']>0
    tracks=cmd('get_property','track-list')
    report['video_codec']=next(t['codec'] for t in tracks if t.get('selected') and t['type']=='video')
    report['checks']['codec_and_packet_bitrate']=True
    cmd('seek',2,'absolute+exact')
    wait_for('seeking',lambda v:not v)
    before=cmd('get_property','time-pos');cmd('frame-step')
    after=wait_for('time-pos',lambda v:v>before)
    wait_for('pause',lambda v:v is True)
    report['checks']['frame_step']={'before':before,'after':after}
    cmd('set_property','mute',False);assert cmd('get_property','mute') is False
    cmd('set_property','mute',True);assert cmd('get_property','mute') is True
    report['checks']['mute']=True
    for key,value in [('audio-delay',.2),('sub-delay',.3),('sub-scale',1.2)]:
        cmd('set_property',key,value);assert abs(cmd('get_property',key)-value)<.001
    report['checks']['timing_and_subtitle_size']=True
    for key in ['loop-file','loop-playlist']:
        cmd('set_property',key,'inf');assert cmd('get_property',key)=='inf'
        cmd('set_property',key,'no')
    report['checks']['repeat_properties']=True
    screenshot=base.with_suffix('.png');cmd('screenshot-to-file',str(screenshot),'window')
    assert screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    report['checks']['rendered_screenshot']=screenshot.name
    fixture=str(root/'benchmarks/fixtures/tagged-720p24.mov')
    cmd('loadfile',fixture,'append')
    queue=wait_for('playlist',lambda v:len(v)>=2)
    count=len(queue);cmd('playlist-next','weak')
    wait_for('playlist-pos',lambda v:v==1)
    wait_for('path',lambda v:v==fixture)
    cmd('playlist-prev','weak');wait_for('playlist-pos',lambda v:v==0)
    cmd('playlist-remove',1);assert len(cmd('get_property','playlist'))==count-1
    report['checks']['append_next_previous_remove']=True
    report['passed']=True
except Exception as error:
    report['passed']=False;report['error']=str(error)
finally:
    for key,value in [('pause',True),('mute',True),('audio-delay',0),('sub-delay',0),('sub-scale',1),('loop-file','no'),('loop-playlist','no')]:
        try:cmd('set_property',key,value)
        except Exception:pass
    base.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2));print(base.with_suffix('.json'))
sys.exit(0 if report['passed'] else 1)
