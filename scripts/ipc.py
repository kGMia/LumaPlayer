#!/usr/bin/env python3
"""Local mpv JSON IPC diagnostic client. Does not alter persistent settings."""
import socket,json,sys

def command(args, path='/private/tmp/iive-smoke.sock'):
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(10); s.connect(path)
  s.sendall((json.dumps({'command':args,'request_id':1})+'\n').encode())
  buf=b''
  while True:
   part=s.recv(65536)
   if not part: raise RuntimeError('IPC disconnected')
   buf+=part
   while b'\n' in buf:
    line,buf=buf.split(b'\n',1);r=json.loads(line)
    if r.get('request_id')==1:return r
if __name__=='__main__': print(json.dumps(command(json.loads(sys.argv[1])),ensure_ascii=False,indent=2))
