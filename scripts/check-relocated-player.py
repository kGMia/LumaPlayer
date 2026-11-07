#!/usr/bin/env python3
"""Minimal relocated-bundle check; no GUI, network or GPU/model inference."""
from pathlib import Path
import ctypes
import os
import subprocess
import sys
import tempfile
import time
import wave

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build/Luma Player.app'
with tempfile.TemporaryDirectory(prefix='iive-relocated-', dir='/private/tmp') as scratch:
    scratch = Path(scratch)
    app = scratch/'Player.app'
    subprocess.run(['ditto',str(source),str(app)],check=True)
    subprocess.run([sys.executable,str(root/'scripts/check-app-linkage.py'),str(app),'--standalone'],check=True)
    fixture = scratch/'sound.wav'
    with wave.open(str(fixture),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(bytes(64000))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('DYLD_', 'PACKAGE_RESOURCE_'))}
    env['PATH']='/usr/bin:/bin'
    subprocess.run([str(app/'Contents/MacOS/ffmpeg'),'-v','error','-nostdin','-i',str(fixture),
                    '-t','0.1','-f','null','-'],cwd='/',env=env,check=True,timeout=15)
    # Load the relocated libmpv in a fresh process with the same clean environment.
    code = '''
import ctypes,sys,time
m=ctypes.CDLL(sys.argv[1])
m.mpv_create.restype=ctypes.c_void_p
m.mpv_set_option_string.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
m.mpv_initialize.argtypes=[ctypes.c_void_p]
m.mpv_command.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_char_p)]
m.mpv_get_property.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_void_p]
m.mpv_terminate_destroy.argtypes=[ctypes.c_void_p]
h=m.mpv_create(); assert h
try:
 for k,v in ((b'vo',b'null'),(b'ao',b'null'),(b'config',b'no'),(b'pause',b'yes'),(b'idle',b'yes')):
  assert m.mpv_set_option_string(h,k,v)>=0
 assert m.mpv_initialize(h)>=0
 assert m.mpv_command(h,(ctypes.c_char_p*4)(b'loadfile',sys.argv[2].encode(),b'replace',None))>=0
 duration=ctypes.c_double()
 deadline=time.monotonic()+8
 while time.monotonic()<deadline:
  if m.mpv_get_property(h,b'duration',5,ctypes.byref(duration))>=0 and duration.value>0: break
  time.sleep(.05)
 assert abs(duration.value-2)<.01,duration.value
finally: m.mpv_terminate_destroy(h)
'''
    subprocess.run([sys.executable,'-c',code,str(app/'Contents/Frameworks/libmpv.2.dylib'),str(fixture)],
                   cwd='/',env=env,check=True,timeout=15)
print('PASS: relocated FFmpeg decoded audio; relocated libmpv loaded a two-second file without GUI/GPU.')
