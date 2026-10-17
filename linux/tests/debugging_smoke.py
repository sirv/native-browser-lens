"""Real local HTTP failure -> exported handoff -> Playwright before/after -> imported diagnostics."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

parser=argparse.ArgumentParser();parser.add_argument('--bundle',type=Path,required=True);args=parser.parse_args()
bundle=args.bundle.resolve();repo=Path(__file__).resolve().parents[2]
fixed=False
class Fixture(BaseHTTPRequestHandler):
    def log_message(self,*_):pass
    def do_GET(self):
        body=b'<button id="save" onclick="fetch(\'/save\',{method:\'POST\'}).then(r=>document.querySelector(\'#result\').textContent=r.status)">Save</button><div id="result"></div>'
        self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(body)
    def do_POST(self):
        self.send_response(200 if fixed else 503);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"fixture":true}')

server=ThreadingHTTPServer(('127.0.0.1',0),Fixture);threading.Thread(target=server.serve_forever,daemon=True).start()
origin=f'http://127.0.0.1:{server.server_port}'
with tempfile.TemporaryDirectory(prefix='lens-debugging-') as directory:
    root=Path(directory);environment={**os.environ,'LENS_DATA_DIR':str(root/'notebook'),'XDG_CONFIG_HOME':str(root/'config')}
    def command(action,allow_error=False,**payload):
        process=subprocess.run([str(bundle/'lens-service')],input=json.dumps(dict(action=action,**payload)),capture_output=True,text=True,env=environment,timeout=45)
        value=json.loads(process.stdout)
        if not allow_error:assert process.returncode==0,value
        return value
    project=dict(id=str(uuid.uuid4()),name='Debugging fixture',origins=[origin],repositoryPath='',documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])
    command('configure',projects=[project]);item=command('new',projectId=project['id'])['observationUpdates'][0]
    command('edit',observationId=item['id'],markdown='Preserve my manual report during reproduction and verification.')
    capture=str(uuid.uuid4());client=str(uuid.uuid4());stamp=time.time()*1000
    identity=dict(projectId=project['id'],tabId=1,windowId=1,documentId='fixture',url=origin+'/',title='HTTP failure fixture',capturedAt=stamp,clientId=client)
    def event(kind,offset,**data):return dict(id=str(uuid.uuid4()),projectId=project['id'],tabId=1,documentId='fixture',timestamp=stamp+offset,kind=kind,data=data)
    events=[event('action',-30,element={'selector':'#save','label':'Save'}),event('request',-20,requestId='save',method='POST',url=origin+'/save'),event('response',-10,requestId='save',url=origin+'/save',status=503)]
    inbox=root/'notebook/bridge/inbox'
    envelope=dict(version=1,id=str(uuid.uuid4()),kind='capture',payload=dict(observationId=item['id'],captureId=capture,clientId=client,identity=identity,events=events,gaps=[],context={},screenshotOmission='No screenshot in the diagnostic fixture'))
    start=dict(version=1,id=str(uuid.uuid4()),kind='capture-started',payload=dict(observationId=item['id'],captureId=capture,clientId=client,identity=identity,initiatedBy='extension',tab=dict(tabId=1,windowId=1,projectId=project['id'],url=origin+'/',title='HTTP failure fixture',mode='deep',documentId='fixture',armedAt=0,capabilities=[],active=True,selected=True)))
    (inbox/'start.json').write_text(json.dumps(start))
    (inbox/'fixture.json').write_text(json.dumps(envelope))
    current=command('sync')['observationUpdates'][0]
    timeline=command('timeline',observationId=item['id'],captureId=capture)['timeline']
    failed=next(row for row in timeline if row['event']['id']==events[-1]['id'])
    assert any(link['relationship']=='request' and link['target']==events[1]['id'] for link in failed['links'])
    assert any(link['relationship']=='nearby' and link['target']==events[0]['id'] for link in failed['links'])
    preview=command('cloudPreview',observationId=item['id'],reviewedVersion=current['editVersion'],captureIds=[capture])['selection']
    assert preview['captures'][0]['events'] and preview['selection']['omittedEventCount']==0
    exported=Path(command('export',observationId=item['id'],destination=str(root/'exports'))['exportPath'])
    cli=lambda *args:json.loads(subprocess.check_output([str(bundle/'lens-evidence'),str(exported),*args],text=True))
    assert cli('event',events[-1]['id'])['data']['status']==503
    assert cli('requests',capture)
    handoff=root/'reproduction'
    assert cli('handoff',events[-1]['id'],'200',str(handoff))['handoff']==str(handoff)
    service_handoff=command('handoff',observationId=item['id'],reviewedVersion=current['editVersion'],eventId=events[-1]['id'],successStatus=200,destination=str(root/'service-handoff'))
    assert (Path(service_handoff['handoffPath'])/'reproduce.mjs').is_file()
    config=json.loads((handoff/'handoff.json').read_text());assert config['steps']==[]
    config['steps']=[dict(op='goto',url=origin+'/'),dict(op='click',selector='#save'),dict(op='expectVisible',selector='#result')]
    (handoff/'handoff.json').write_text(json.dumps(config))
    browser=shutil.which('chromium') or shutil.which('google-chrome')
    assert browser,'Install Chromium for the opt-in browser fixture'
    run_environment={**environment,'LENS_REPRO_BROWSER':browser}
    results=[]
    for phase in ('before','after'):
        fixed=phase=='after'
        run_environment['LENS_REPRO_BUILD']='fixture-fixed' if fixed else 'fixture-broken'
        process=subprocess.run(['node',str(handoff/'reproduce.mjs'),phase,'--reviewed'],cwd=repo/'extension',capture_output=True,text=True,env=run_environment,timeout=90)
        assert process.returncode==0,process.stderr
        result=Path(json.loads(process.stdout)['result']);results.append(result)
        command('importVerification',observationId=item['id'],captureId=capture,source=str(result))
    summary=command('verificationSummary',observationId=item['id'],captureId=capture)['verification']
    assert summary['status']=='same-condition-check-passed',summary
    assert summary['matchesCapturedFailure'],summary
    saved=next(item for item in command('bootstrap')['observations'] if item['id']==current['id'])
    assert saved['markdown']=='Preserve my manual report during reproduction and verification.'
    assert len(saved['captures'][0]['context']['diagnosticArtifacts'])==8
    assert all(not artifact['reviewed'] for artifact in saved['captures'][0]['context']['diagnosticArtifacts'])
    har=results[-1].parent/'network.har';original=har.read_bytes();har.write_bytes(original+b' ')
    rejected=command('importVerification',allow_error=True,observationId=item['id'],captureId=capture,source=str(results[-1]))
    assert 'checksum' in rejected['error'];har.write_bytes(original)
    artifact=saved['captures'][0]['context']['diagnosticArtifacts'][0]
    rejected=command('reviewDiagnostic',allow_error=True,observationId=item['id'],captureId=capture,artifactId=artifact['id'],reviewedVersion=current['editVersion'],reviewed=True)
    assert 'Review' in rejected['error']
    print(json.dumps(dict(passed=True,timelineRelations=True,reviewedCLI=True,reproducedHTTP=503,verifiedHTTP=200,importedChecksumCheckedArtifacts=8,rawArtifactsDefaultLocal=True,manualNotesPreserved=True,corruptArtifactRejected=True)))
server.shutdown()
