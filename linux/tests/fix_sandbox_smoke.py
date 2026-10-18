"""Verify edited server code cannot reach host files, raw diagnostics or the host network."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
from unittest.mock import patch

repo=Path(__file__).resolve().parents[2];sys.path.insert(0,str(repo/'linux'))
import autofix
import fix_verify

with tempfile.TemporaryDirectory(prefix='lens-sandbox-test-') as directory:
    root=Path(directory);tree=root/'source';tree.mkdir();control=root/'evidence/handoff';control.mkdir(parents=True);output=root/'results';output.mkdir()
    original=root/'original.txt';original.write_text('untouched source')
    raw=control/'unreviewed.txt';raw.write_text('unreviewed private browser data')
    repository=root/'original-repository';repository.mkdir()
    for arguments in (['init','-q'],['config','user.name','Test'],['config','user.email','test@example.test'],['commit','--allow-empty','-qm','baseline']):autofix.git(repository,*arguments)
    git=repository/'.git';base=autofix.git(repository,'rev-parse','HEAD')
    (git/'config.worktree').write_text('private Git credential canary')
    (tree/'bin').mkdir();launcher=tree/'bin/dev';launcher.write_text('#!/bin/sh\nexec python3 "$1"\n');launcher.chmod(0o700)
    (repository/'bin').mkdir();(repository/'bin/dev').write_text('#!/bin/sh\nexit 42\n');(repository/'bin/dev').chmod(0o700)
    runtime=root/'toolchain/bin/python3';runtime.parent.mkdir(parents=True);shutil.copy2(Path(sys.executable).resolve(),runtime)
    dependencies=root/'dependencies';shutil.copytree(repo/'extension/node_modules',dependencies/'node_modules',symlinks=True)
    (dependencies/'apps/web/node_modules').mkdir(parents=True);shutil.move(str(dependencies/'node_modules/playwright'),dependencies/'apps/web/node_modules/playwright')
    (tree/'apps/web').mkdir(parents=True)
    node=root/'runtime/bin/node';node.parent.mkdir(parents=True);shutil.copy2(Path(shutil.which('node')).resolve(),node)
    aliases=root/'aliases';aliases.mkdir();(aliases/'node').symlink_to(node);(aliases/'python3').symlink_to(Path(sys.executable).resolve())
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0));listener.listen();host_port=listener.getsockname()[1]
        with socket.socket() as port_socket:port_socket.bind(('127.0.0.1',0));port=port_socket.getsockname()[1]
        program='''from http.server import BaseHTTPRequestHandler, HTTPServer
import os,json,socket
from pathlib import Path
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_GET(self):
  if self.path!='/check':self.send_response(404);self.end_headers();return
  escaped=[]
  for path in PATHS:
   try:Path(path).read_bytes();escaped.append(path)
   except OSError:pass
  try:Path(ORIGINAL).write_text('private namespace copy')
  except OSError:pass
  try:Path(GIT_POINTER).write_text('gitdir: /attacker');escaped.append('Git pointer write')
  except OSError:pass
  try:Path(GIT_POINTER).unlink();escaped.append('Git pointer removal')
  except OSError:pass
  try:Path(GIT_CONFIG).read_text();escaped.append('Git credential')
  except OSError:pass
  try:
   with socket.create_connection(('127.0.0.1',HOST_PORT),timeout=.2):escaped.append('host network')
  except OSError:pass
  print(json.dumps(escaped),flush=True)
  self.send_response(500 if escaped else 200);self.end_headers();self.wfile.write(json.dumps(escaped).encode())
HTTPServer(('127.0.0.1',int(os.environ['PORT'])),Handler).serve_forever()
'''
        prefix='PATHS='+repr([str(original),str(raw),'/lens/handoff/handoff.json','/lens/results/server.log'])+'\nORIGINAL='+repr(str(original))+'\nGIT_CONFIG='+repr(str(git/'config.worktree'))+'\nGIT_POINTER='+repr(str(tree/'.git'))+'\nHOST_PORT='+str(host_port)+'\n'
        (tree/'app.py').write_text(prefix+program)
        contract={'observationId':'fixture','captureId':'capture','failureEventId':'event','condition':{'type':'http-status','url':'https://capture.example/check','method':'GET','failureStatus':500,'successStatus':200}}
        config={'contract':contract,'contractSHA256':autofix.hash_json(contract),'pageURL':'https://capture.example/','steps':[{'op':'goto','url':'https://capture.example/check'}]}
        (control/'handoff.json').write_text(json.dumps(config));shutil.copy2(repo/'linux/reproduce.mjs',control/'reproduce.mjs')
        browser=shutil.which('chromium') or shutil.which('google-chrome');assert browser
        (tree/'.git').write_text('gitdir: '+str(git)+'\n')
        with patch.dict(os.environ,{'PATH':str(aliases)+':'+os.environ['PATH']}),patch.object(sys,'executable',str(aliases/'python3')):
            command=fix_verify.invocation(tree,'apps/web',git,dependencies,control,output,[str(repository/'bin/dev'),str(repository/'app.py')],'after',port,browser,'',repository=repository,base_commit=base,index=git/'index')
        result=subprocess.run(command,capture_output=True,text=True,timeout=90)
        assert result.returncode==0,(result.stdout,result.stderr,(output/'server.log').read_text() if (output/'server.log').exists() else '',[path.read_text() for path in output.glob('after-*/result.json')])
        files=list(output.glob('after-*/result.json'));assert len(files)==1
        checked=autofix.checked_result(files[0],config,hashlib.sha256((control/'reproduce.mjs').read_bytes()).hexdigest(),'after')
        assert original.read_text()=='untouched source'
        assert (tree/'.git').read_text()=='gitdir: '+str(git)+'\n'
        print(json.dumps(dict(passed=True,hostReadBlocked=True,hostWriteBlocked=True,rawDiagnosticsHidden=True,verificationOutputHidden=True,hostNetworkBlocked=True,gitCredentialsHidden=True,gitPointerImmutable=True,browserHTTP=checked['observedStatus'])))
