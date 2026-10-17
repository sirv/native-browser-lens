"""Real Secret Service + HTTP filing/recovery, entirely on a private test bus."""
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid

assert os.environ.get('LENS_PRIVATE_BUS')=='1','Run with LENS_PRIVATE_BUS=1 dbus-run-session -- python3 linux/tests/filing_smoke.py'
repo=Path(__file__).resolve().parents[2]
service=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=repo,text=True).strip())/'lens-service'

with tempfile.TemporaryDirectory(prefix='lens-filing-smoke-') as directory:
    root=Path(directory);env={**os.environ,'XDG_DATA_HOME':str(root/'data'),'XDG_CONFIG_HOME':str(root/'config'),'GNOME_KEYRING_CONTROL':str(root/'keyring'),'LENS_DATA_DIR':str(root/'notebook')}
    logs=(root/'keyring.log').open('w')
    daemon=subprocess.Popen(['gnome-keyring-daemon','--foreground','--unlock','--components=secrets','--control-directory='+env['GNOME_KEYRING_CONTROL']],env=env,stdin=subprocess.PIPE,stdout=logs,stderr=logs,text=True)
    daemon.stdin.write('disposable-fixture-password\n');daemon.stdin.close()
    receipts={};uploads=[];submissions=[]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def reply(self,status,value):
            data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def do_GET(self):
            if self.path=='/auth/me':
                assert self.headers.get('Cookie')=='session=fixture-token'
                self.reply(200,{'id':'fixture-member'})
            elif self.path=='/api/members':self.reply(200,[{'id':'fixture-member','name':'Fixture owner'}])
            else:
                value=receipts.get(self.path.rsplit('/',1)[-1]);self.reply(200 if value else 404,value or {})
        def do_POST(self):
            body=self.rfile.read(int(self.headers['Content-Length']))
            if self.path=='/api/attachments/stage':
                uploads.append(body);self.reply(200,{'stagedKey':'stage-'+str(len(uploads))})
            else:
                payload=json.loads(body);submissions.append(payload)
                receipt={key:payload[key] for key in ('submissionId','observationId','revision')}
                receipt.update(taskId='fixture-task',taskUrl=f'http://127.0.0.1:{server.server_port}/tasks/fixture-task',createdAt=time.time()*1000,attachmentStatus='complete',missingAttachments=[])
                receipts[payload['submissionId']]=receipt
                self.reply(503,{'message':'Simulated uncertain response after durable commit'})
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    def command(action,**payload):
        result=subprocess.run([str(service)],input=json.dumps(dict(action=action,**payload)),env=env,text=True,capture_output=True,timeout=20)
        messages=[json.loads(line) for line in result.stdout.splitlines()]
        return messages[-1],[value['progress'] for value in messages if 'progress' in value]
    try:
        time.sleep(.3)
        profile=dict(id=str(uuid.uuid4()),name='Filing fixture',origins=['http://localhost:3000'],repositoryPath=str(repo),documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])
        assert 'error' not in command('configure',projects=[profile])[0]
        settings,_=command('settings',settings={'vibeqURL':f'http://127.0.0.1:{server.server_port}'},vibeq='fixture-token')
        assert 'error' not in settings,settings
        members,_=command('members',observationId=command('new',projectId=profile['id'])[0]['selectedObservationId'])
        assert members['members'][0]['id']=='fixture-member',members
        item=members['observationUpdates'][0]
        command('edit',observationId=item['id'],markdown='A reviewed, local-only fixture report.')
        review,_=command('reviewFiling',observationId=item['id']);snapshot=review['review']
        payload=dict(observationId=item['id'],revision=snapshot['draftRevision'],reviewedVersion=snapshot['editVersion'],reviewed=True,assigneeId='fixture-member',stream=True)
        failed,progress=command('file',**payload)
        assert '503' in failed['error'],failed
        assert any(event['stage']=='attachments' and event['state']=='completed' for event in progress)
        assert progress[-1]['stage']=='submit' and progress[-1]['state']=='failed'
        before=len(uploads)
        restored,_=command('reviewFiling',observationId=item['id'])
        assert restored['frozen'] and restored['assigneeId']=='fixture-member'
        command('edit',observationId=item['id'],markdown='Manual changes while recovering the original report.')
        recovered,progress=command('file',**payload)
        assert recovered['receipt']['taskId']=='fixture-task',recovered
        assert progress[-1]['stage']=='receipt' and progress[-1]['state']=='completed'
        assert len(submissions)==1 and len(uploads)==before
        current=recovered['observationUpdates'][0]
        assert current['markdown'].startswith('Manual changes') and current['draftRevision']==2
        assert current['receipt']['revision']==1
        assert before==2,'Real Markdown and sanitized JSON were uploaded'
        command('settings',vibeq='')
        assert 'error' in command('members',observationId=item['id'])[0]
        print('Filing smoke passed: real isolated Secret Service, members, two HTTP uploads, streamed failure, restart recovery, one durable task, preserved edits and credential removal.')
    finally:
        server.shutdown();server.server_close()
        daemon.terminate()
        try:daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:daemon.kill();daemon.wait()
        logs.close()
