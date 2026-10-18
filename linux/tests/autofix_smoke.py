"""Opt-in subscription test: real collector capture -> Codex source patch -> independent local regression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import time
import uuid

repo=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle',type=Path,required=True);parser.add_argument('--extension',type=Path,default=repo/'extension/dist');parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();bundle=args.bundle.resolve();root=args.output.resolve();root.mkdir(parents=True,mode=0o700)
sys.path.insert(0,str(bundle if (bundle/'autofix.py').is_file() else repo/'linux'))
import autofix
project_root=Path.home()/'Projects'/('native-browser-lens-agent-acceptance-'+uuid.uuid4().hex[:8]);project_root.mkdir(mode=0o700)
project_dir=project_root/'apps/web';project_dir.mkdir(parents=True)
application='''from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os
def calculate(price, quantity):
    return f"{int(price) * int(quantity):.2f}"
class App(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
        self.wfile.write(b''' + repr('''<!doctype html><title>Lens agent acceptance application</title><h1>Order total</h1><label>Price <input id="price" value="12.50"></label><label>Quantity <input id="quantity" value="2"></label><button id="calculate" onclick="calculateTotal()">Calculate total</button><p id="result"></p><script>async function calculateTotal(){const r=await fetch('/api/total',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({price:document.querySelector('#price').value,quantity:document.querySelector('#quantity').value})});const data=await r.json();document.querySelector('#result').textContent=r.ok?'Total: '+data.total:'Calculation failed';}</script>''') + ''')
    def do_POST(self):
        values=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        try: result={'total': calculate(values['price'], values['quantity'])}; status=200
        except ValueError: result={'error':'Decimal prices are rejected'}; status=500
        self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(result).encode())
if __name__=='__main__': ThreadingHTTPServer(('127.0.0.1',int(os.environ['PORT'])),App).serve_forever()
'''
(project_dir/'app.py').write_text(application)
(project_dir/'serve').write_text('#!/bin/sh\nexec python3 app.py\n');(project_dir/'serve').chmod(0o700)
(project_dir/'README.md').write_text('Local order-total application. Decimal prices must be accepted. Run python3 app.py with PORT set. calculate("12.50", "2") must return "25.00".\n')
(project_root/'.gitignore').write_text('__pycache__\n')
for command in (['init','-q'],['config','user.name','Lens acceptance'],['config','user.email','acceptance@example.test'],['add','.'],['commit','-qm','Order total with decimal parsing defect']):autofix.git(project_root,*command)
shutil.copytree(repo/'extension/node_modules',project_root/'node_modules',symlinks=True)
(project_dir/'node_modules').mkdir();shutil.move(str(project_root/'node_modules/playwright'),project_dir/'node_modules/playwright')
(project_dir/'README.md').write_text((project_dir/'README.md').read_text()+'Uncommitted user note: preserve me exactly.\n')
source_before=hashlib.sha256((project_dir/'app.py').read_bytes()+(project_dir/'README.md').read_bytes()).hexdigest()
with socket.socket() as listener:listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
origin='http://127.0.0.1:'+str(port)
environment={**os.environ,'LENS_DATA_DIR':str(root/'notebook'),'XDG_CONFIG_HOME':str(root/'config'),'LENS_EVIDENCE_BINARY':str(bundle/'lens-evidence')}
os.environ['LENS_EVIDENCE_BINARY']=str(bundle/'lens-evidence')
def service(action,**payload):
    process=subprocess.run([str(bundle/'lens-service')],input=json.dumps(dict(action=action,**payload)),env=environment,capture_output=True,text=True,timeout=30)
    value=json.loads(process.stdout);assert process.returncode==0,value;return value
project=dict(id=str(uuid.uuid4()),name='Agent acceptance application',origins=[origin],repositoryPath=str(project_dir),documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])
service('configure',projects=[project])
with (root/'capture-server.log').open('wb') as output:
    server=subprocess.Popen([sys.executable,'app.py'],cwd=project_dir,env={**os.environ,'PORT':str(port)},stdout=output,stderr=output,start_new_session=True)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.05)
        browser={**environment,'LENS_AGENT_QA':str(root),'LENS_AGENT_BUNDLE':str(bundle),'LENS_AGENT_EXTENSION':str(args.extension.resolve()),'LENS_AGENT_ORIGIN':origin,'CHROME_PATH':__import__('shutil').which('chromium')}
        subprocess.run(['node',str(repo/'linux/tests/agent_capture.mjs')],cwd=repo/'extension',env=browser,check=True,timeout=90)
    finally:autofix.stop(server)
observations=[]
for _ in range(50):
    observations=service('bootstrap')['observations']
    if observations and observations[0]['captures']:break
    time.sleep(.1)
assert observations
item=observations[0];capture=item['captures'][0]
failure=next(event for event in capture['events'] if event['kind']=='response' and event['data'].get('status')==500)
assert Path(capture['screenshotPath']).is_file()
manual='Observed: Calculate total fails for price 12.50 and quantity 2. Expected: HTTP 200 and total 25.00. Preserve this manual note.'
item=service('edit',observationId=item['id'],markdown=manual)['observationUpdates'][0]
job=autofix.create_job(project_dir)
prepared=service('prepareFix',observationId=item['id'],captureId=capture['id'],reviewedVersion=item['editVersion'],reviewed=True,eventId=failure['id'],successStatus=200,destination=str(Path(job['directory'])/'evidence'))
result=autofix.run(job,prepared['exportPath'],prepared['handoffPath'],'./serve',progress=lambda detail:print(detail,flush=True))
semantic=autofix.fix_verify.sandbox()
for runtime in autofix.fix_verify.runtime_mounts([sys.executable]):semantic+=['--ro-bind',runtime,runtime]
semantic+=['--ro-bind',result['worktree'],'/fixture','--chdir','/fixture/apps/web','--',sys.executable,'-c','import app; assert app.calculate("12.50","2")=="25.00", "HTTP success alone is insufficient"']
subprocess.run(semantic,check=True,capture_output=True,text=True,timeout=30)
assert hashlib.sha256((project_dir/'app.py').read_bytes()+(project_dir/'README.md').read_bytes()).hexdigest()==source_before
assert 'node_modules' not in Path(result['patch']).read_text()
assert json.loads(Path(result['after']).read_text())['buildId'] is None
for phase in ('before','after'):service('importVerification',observationId=item['id'],captureId=capture['id'],source=result[phase])
saved=service('bootstrap')['observations'][0];assert saved['markdown']==manual
verification=service('verificationSummary',observationId=item['id'],captureId=capture['id'])['verification']
assert verification['status']=='same-condition-check-passed' and verification['localRetest'],verification
assert all(not record['reviewed'] for record in saved['captures'][0]['context']['diagnosticArtifacts'])
exported=service('export',observationId=item['id'],destination=str(root/'exports'))['exportPath']
proof=dict(passed=True,fixture=True,project=str(project_root),job=result,realCollectorCapture=True,capturedHTTP=500,verifiedHTTP=200,semanticTotal='25.00',manualNotesPreserved=True,dirtySourcePreserved=True,rawArtifactsUnreviewed=True,exportedReport=exported,limits=['Controlled local application, not a private production defect.','Fresh browser; no authenticated user session.'])
(root/'result.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps({key:value for key,value in proof.items() if key!='job'}),flush=True)
