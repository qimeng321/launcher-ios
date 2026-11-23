import os,subprocess,tempfile,threading,http.server,pathlib
with tempfile.TemporaryDirectory() as folder:
 target=pathlib.Path(folder)/'resource';target.mkdir()
 (target/'test.swf').write_bytes(b'FWS'+b'\x09'+b'\x08\x00\x00\x00')
 (target/'bad.swf').write_bytes(b'<html>this is not a SWF</html>')
 class Handler(http.server.SimpleHTTPRequestHandler):
  def __init__(self,*args,**kwargs):super().__init__(*args,directory=folder,**kwargs)
  def log_message(self,*args):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 result=subprocess.run(['/tmp/resource_integration',str(server.server_address[1])],capture_output=True,text=True,timeout=14)
 print('return',result.returncode,'out',result.stdout,'err',result.stderr[:800]);server.shutdown()
 assert result.returncode==0
