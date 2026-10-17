"""Real Firefox/native-host acceptance in an isolated profile and home. Never opens a user profile."""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile

parser=argparse.ArgumentParser();parser.add_argument('--extension',type=Path);parser.add_argument('--headed',action='store_true');parser.add_argument('--host',type=Path,required=True);parser.add_argument('--output',type=Path,default=Path('.build/firefox-smoke'));args=parser.parse_args()
repo=Path(__file__).resolve().parents[2];output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)


class Marionette:
    def __init__(self,connection):self.socket=connection;self.index=0;self.file=connection.makefile('rb');self.receive()
    def receive(self):
        prefix=b''
        while (value:=self.file.read(1))!=b':':
            if not value:raise EOFError('Firefox closed')
            prefix+=value
            assert len(prefix)<10
        size=int(prefix);assert size<8*1024*1024
        return json.loads(self.file.read(size))
    def command(self,method,params=None):
        self.index+=1;data=json.dumps([0,self.index,method,params or {}]).encode();self.socket.sendall(str(len(data)).encode()+b':'+data)
        reply=self.receive();assert reply[1]==self.index
        if reply[2]:raise RuntimeError(json.dumps(reply[2]))
        return reply[3]
    def script(self,script,*arguments):return self.command('WebDriver:ExecuteScript',dict(script=script,args=list(arguments),newSandbox=False)).get('value')


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_):pass
    def do_GET(self):
        self.send_response(503 if self.path.startswith('/api') else 200)
        self.send_header('Content-Type','application/json' if self.path.startswith('/api') else 'text/html')
        self.send_header('Set-Cookie','token=fixture-private-secret');self.end_headers()
        if self.path.startswith('/api'):self.wfile.write(b'{"error":"Synthetic failure","token":"fixture-private-secret"}');return
        self.wfile.write(b'''<!doctype html><title>Lens Firefox fixture</title><body><h1>Firefox capture fixture</h1><button id="save" data-source="src/save.ts:10">Save fixture</button><p id="result"></p><script>
localStorage.setItem("token","fixture-private-secret");localStorage.setItem("fixture","keep this");
window.__NATIVE_BROWSER_LENS__={build:{sourceState:"working-tree"},session:{status:"fixture"}};
document.querySelector("#save").onclick=async()=>{const result=await fetch("/api?token=fixture-private-secret");document.querySelector("#result").textContent="HTTP "+result.status;};
</script></body>''')


servers=[http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture) for _ in range(2)]
for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
origins=['http://127.0.0.1:'+str(server.server_port) for server in servers]
with tempfile.TemporaryDirectory(prefix='lens-firefox-') as directory:
    root=Path(directory);profile=root/'profile';profile.mkdir();data=root/'notebook';(data/'bridge/inbox').mkdir(parents=True)
    projects=[dict(id=str(uuid.uuid4()),name='Firefox '+str(i),origins=[origin],enabled=True,repositoryPath='',documentationPaths=[],logPaths=[],ownership=[],adapter='generic',recording='diagnostics') for i,origin in enumerate(origins)]
    service=args.host.resolve().with_name('lens-service')
    environment={**os.environ,'LENS_DATA_DIR':str(data),'XDG_CONFIG_HOME':directory+'/config'}
    def stored(action,**payload):
        reply=subprocess.run([str(service)],input=json.dumps(dict(action=action,**payload)),env=environment,capture_output=True,text=True,timeout=25)
        value=json.loads(reply.stdout);assert reply.returncode==0,value
        return value
    stored('configure',projects=projects)
    hosts=root/'.mozilla/native-messaging-hosts';hosts.mkdir(parents=True)
    identity='native-browser-lens@sirv.studio'
    (hosts/'studio.sirv.native_browser_lens.json').write_text(json.dumps(dict(name='studio.sirv.native_browser_lens',description='Isolated Firefox Lens fixture',path=str(args.host.resolve()),type='stdio',allowed_extensions=[identity])))
    addon=root/'extension';shutil.copytree(args.extension or repo/'extension/dist-firefox',addon)
    manifest=json.loads((addon/'manifest.json').read_text());manifest['host_permissions']=['http://127.0.0.1/*']
    (addon/'manifest.json').write_text(json.dumps(manifest))
    (addon/'fixture.html').write_text('<!doctype html><title>Lens Firefox test control</title><textarea id="input"></textarea><button id="run">Run</button><pre id="output"></pre><script src="fixture.js"></script>')
    (addon/'fixture.js').write_text('''const api=globalThis.browser??chrome;document.querySelector("#run").onclick=async()=>{try{const request=JSON.parse(document.querySelector("#input").value);let result;
if(request.kind==="focus")result=await api.windows.update(request.windowId,{focused:true});else if(request.kind==="commands")result=await api.commands.getAll();else if(request.kind==="windows")result=await Promise.all(request.urls.map(url=>api.windows.create({url})));else result=await api.runtime.sendMessage(request);
document.querySelector("#output").textContent=JSON.stringify({result});}catch(error){document.querySelector("#output").textContent=JSON.stringify({error:String(error)});}};''')
    xpi=root/'lens.xpi'
    with zipfile.ZipFile(xpi,'w') as archive:
        for path in addon.rglob('*'):
            if path.is_file():archive.write(path,path.relative_to(addon))
    with socket.socket() as port:port.bind(('127.0.0.1',0));number=port.getsockname()[1]
    extension_uuid=str(uuid.uuid4())
    preferences={'marionette.port':number,'extensions.webextensions.uuids':json.dumps({identity:extension_uuid}),'browser.shell.checkDefaultBrowser':False,'browser.startup.homepage_override.mstone':'ignore','browser.startup.page':0,'browser.ml.enable':False,'browser.safebrowsing.update.enabled':False,'app.update.disabledForTesting':True}
    (profile/'user.js').write_text('\n'.join('user_pref('+json.dumps(key)+','+json.dumps(value)+');' for key,value in preferences.items()))
    process=None
    try:
        with (output/'firefox.log').open('wb') as log:
            process=subprocess.Popen(['firefox',*([ ] if args.headed else ['--headless']),'--no-remote','--marionette','--remote-allow-system-access','--profile',str(profile)],env={**os.environ,'HOME':directory,'LENS_DATA_DIR':str(data),'XDG_CACHE_HOME':directory+'/cache'},stdout=log,stderr=log)
            deadline=time.monotonic()+20;connection=None
            while time.monotonic()<deadline:
                try:connection=socket.create_connection(('127.0.0.1',number),timeout=15);break
                except ConnectionRefusedError:assert process.poll() is None;time.sleep(.1)
            assert connection,'Firefox did not start'
            client=Marionette(connection);capabilities=client.command('WebDriver:NewSession',{'capabilities':{}})['capabilities']
            client.command('Addon:Install',{'path':str(xpi),'temporary':True})
            client.command('WebDriver:Navigate',{'url':'moz-extension://'+extension_uuid+'/fixture.html'})
            control=client.command('WebDriver:GetWindowHandle')['value']
            def call(request):
                client.script('document.querySelector("#output").textContent="";document.querySelector("#input").value=arguments[0];document.querySelector("#run").click();',json.dumps(request))
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    value=client.script('return document.querySelector("#output").textContent;')
                    if value:
                        result=json.loads(value);assert 'error' not in result,result
                        return result['result']
                    time.sleep(.05)
                raise TimeoutError('The Firefox extension control did not respond')
            def wait_state(predicate):
                deadline=time.monotonic()+15;state=None
                while time.monotonic()<deadline:
                    state=call({'kind':'getState'})
                    if predicate(state):return state
                    time.sleep(.15)
                raise AssertionError(state)
            wait_state(lambda s:not s['nativeError'] and len(s['projects'])==2)
            call({'kind':'windows','urls':[origin+'/page' for origin in origins]})
            state=wait_state(lambda s:len(s['tabs'])==2 and all(t['mode']=='limited' for t in s['tabs']))
            target=state['tabs'][0]
            for handle in client.command('WebDriver:GetWindowHandles'):
                client.command('WebDriver:SwitchToWindow',{'handle':handle})
                if client.script('return location.href;').startswith(target['url']):break
            element=client.command('WebDriver:FindElement',{'using':'css selector','value':'#save'})['value']
            client.command('WebDriver:ElementClick',{'id':element['element-6066-11e4-a52e-4f735466cecf']})
            time.sleep(.4)
            client.command('WebDriver:SwitchToWindow',{'handle':control})
            captured=call({'kind':'capture','tabId':target['tabId']});assert not captured.get('error'),captured
            def messages():return [json.loads(path.read_text()) for path in (data/'bridge/inbox').glob('*.json')]
            deadline=time.monotonic()+10;capture=None
            while time.monotonic()<deadline:
                capture=next((m['payload'] for m in messages() if m['kind']=='capture' and m['payload']['captureId']==captured['captureId']),None)
                if capture:break
                time.sleep(.1)
            assert capture,'The native host did not persist the Firefox capture'
            (output/'capture.json').write_text(json.dumps(capture,indent=2))
            assert capture['identity']['projectId']==target['projectId']
            assert any(e['kind']=='response' and e['data'].get('status')==503 for e in capture['events']),capture['events']
            assert any(e['kind']=='action' for e in capture['events']),capture['events']
            assert capture['context']['storage']['localStorage']['entries']['fixture']=='keep this',capture['context']
            assert any(g['channel']=='debugger' for g in capture['gaps'])
            assert 'fixture-private-secret' not in json.dumps(capture)
            assert all(e['projectId']==target['projectId'] for e in capture['events'])
            assert call({'kind':'commands'})[0]['shortcut']=='Alt+Shift+L'
            call({'kind':'focus','windowId':target['windowId']})
            before_ids={m['payload'].get('captureId') for m in messages() if m['kind']=='capture'}
            client.command('WebDriver:SwitchToWindow',{'handle':handle})
            client.command('Marionette:SetContext',{'value':'chrome'})
            button=client.command('WebDriver:FindElement',{'using':'css selector','value':'#unified-extensions-button'})['value']
            client.command('WebDriver:ElementClick',{'id':button['element-6066-11e4-a52e-4f735466cecf']})
            button=client.command('WebDriver:FindElement',{'using':'css selector','value':'toolbarbutton.unified-extensions-item-action-button[data-extensionid="native-browser-lens@sirv.studio"]'})['value']
            client.command('WebDriver:ElementClick',{'id':button['element-6066-11e4-a52e-4f735466cecf']})
            client.command('Marionette:SetContext',{'value':'content'})
            deadline=time.monotonic()+10;shortcut=None
            while time.monotonic()<deadline:
                shortcut=next((m['payload'] for m in messages() if m['kind']=='capture' and m['payload'].get('captureId') not in before_ids),None)
                if shortcut:break
                time.sleep(.1)
            assert shortcut,'The browser action did not reach the native host'
            assert shortcut['identity']['tabId']==target['tabId']
            chunks=[m['payload'] for m in messages() if m['kind']=='artifact' and m['payload']['captureId']==shortcut['captureId']]
            png=base64.b64decode(shortcut['screenshotBase64']) if shortcut.get('screenshotBase64') else b''.join(base64.b64decode(p['data']) for p in sorted(chunks,key=lambda p:p['index']))
            assert png.startswith(b'\x89PNG\r\n\x1a\n'),shortcut.get('screenshotOmission')
            assert shortcut['context']['spatialBinding']=='stable-across-capture',shortcut['gaps']
            (output/'capture.png').write_bytes(png)
            client.command('WebDriver:SwitchToWindow',{'handle':control})
            call({'kind':'pause','paused':True});wait_state(lambda s:all(t['mode']=='paused' for t in s['tabs']))
            call({'kind':'pause','paused':False});wait_state(lambda s:all(t['mode']=='limited' for t in s['tabs']))
            client.command('WebDriver:SwitchToWindow',{'handle':handle})
            client.command('WebDriver:Navigate',{'url':target['url']+'?next-document=1'})
            client.command('WebDriver:SwitchToWindow',{'handle':control})
            current=wait_state(lambda s:any(t['tabId']==target['tabId'] and t['documentId']!=target['documentId'] and t['mode']=='limited' for t in s['tabs']))
            again=call({'kind':'capture','tabId':target['tabId']});assert not again.get('error'),again
            deadline=time.monotonic()+10;replacement=None
            while time.monotonic()<deadline:
                replacement=next((m['payload'] for m in messages() if m['kind']=='capture' and m['payload']['captureId']==again['captureId']),None)
                if replacement:break
                time.sleep(.1)
            assert replacement and replacement['identity']['documentId']!=target['documentId']
            assert not any(e['kind']=='response' and e['data'].get('status')==503 for e in replacement['events']),'The old document response leaked into the new capture'
            saved=stored('bootstrap')
            assert len(saved['observations'])>=3,saved
            pictures=[c['screenshotPath'] for o in saved['observations'] for c in o['captures'] if c.get('screenshotPath')]
            assert pictures and all(Path(p).read_bytes().startswith(b'\x89PNG') for p in pictures)
            summary=dict(passed=True,browser=capabilities['browserVersion'],projects=2,nativeHost=str(args.host.resolve()),mode='limited',events=len(capture['events']),imagePresent=True,imageBytes=len(png),initialNativeCaptureOmission=capture.get('screenshotOmission'),savedObservations=len(saved['observations']),assertions=['real Firefox extension install','framed native host','two project isolation','webRequest HTTP 503','document-bound actions','DOM/storage snapshot','credential redaction','explicit debugger coverage','pause and resume','real browser action and activeTab PNG','stable spatial screenshot binding','navigation replaces document evidence','actual notebook persistence'])
            (output/'result.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
    finally:
        if process:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        for server in servers:server.shutdown();server.server_close()
