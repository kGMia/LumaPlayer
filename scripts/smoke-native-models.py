#!/usr/bin/env python3
"""Basic combined RIFE + native FSRCNNX wiring check; null VO, no speed claims."""
import json, subprocess, sys, tempfile, time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root))
from scripts.ipc import command
name='native-models-'+time.strftime('%Y%m%d-%H%M%S')
result=root/'benchmarks/results'/f'{name}.json'
log_path=result.with_suffix('.log')
with tempfile.TemporaryDirectory(prefix='iive-native-') as tmp, log_path.open('w') as log:
    sock=str(Path(tmp)/'mpv.sock')
    child=subprocess.Popen([str(root/'build/mpv/mpv'),'--no-config','--audio=no','--vo=null',
        '--hwdec=no','--untimed=yes','--frames=48','--keep-open=yes','--idle=yes',
        '--input-ipc-server='+sock,
        '--vf=@iive-rife:iive-rife=fps=48:tier=fast:fallback=no,@iive-sr:iive-fsrcnnx=tier=fast:fallback=no',
        str(root/'benchmarks/fixtures/tagged-720p24.mov')],stdout=log,stderr=log)
    last={}
    try:
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            if child.poll() is not None:raise RuntimeError(f'Early exit: {child.returncode}')
            if Path(sock).exists():
                for key in ('vf-metadata/iive-rife','vf-metadata/iive-sr','video-out-params'):
                    response=command(['get_property',key],sock)
                    if response.get('error')=='success':last[key]=response['data']
                fi=last.get('vf-metadata/iive-rife',{});sr=last.get('vf-metadata/iive-sr',{})
                if int(sr.get('emitted','0'))>=8:break
                if fi.get('fallback')=='yes' or sr.get('fallback')=='yes':raise RuntimeError(f'Filter error: {last}')
            time.sleep(.02)
        else:raise TimeoutError('No native combined output within 60 seconds')
        assert fi['input_path']=='nv12-metal' and fi['output_path']=='nv12-metal',fi
        assert int(fi['generated'])>0,fi
        assert sr['backend']=='fsrcnnx8-mpsgraph' and sr['state']=='active',sr
        assert sr['input_surface']=='shared-iosurface' and int(sr['shared_inputs'])>=8,sr
        assert int(sr['copied_inputs'])==0,sr
        out=last['video-out-params']
        assert out['w']==2560 and out['h']==1440,out
        assert out.get('pixelformat')=='nv12',out
        command(['quit'],sock);child.wait(timeout=15)
        assert child.returncode==0
        result.write_text(json.dumps({'passed':True,'kind':'combined_native_model_basic_check',
            'observations':last,'exit_code':child.returncode,'display_verified':False,
            'realtime_performance_verified':False,'log':log_path.name},indent=2)+'\n')
        print(result)
    except Exception as error:
        result.write_text(json.dumps({'passed':False,'error':str(error),'observations':last,'log':log_path.name},indent=2)+'\n')
        raise
    finally:
        if child.poll() is None:child.terminate();child.wait(timeout=15)
