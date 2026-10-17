"""Check incremental bridge sync and complete explicit notebook refreshes against a real helper."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

parser=argparse.ArgumentParser();parser.add_argument('bundle',type=Path);args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='lens service sync ') as directory:
    environment={**os.environ,'LENS_DATA_DIR':directory,'XDG_CONFIG_HOME':directory+'/config'}
    def command(action,**payload):
        result=subprocess.run([str(args.bundle.resolve()/'lens-service')],input=json.dumps(dict(action=action,**payload)),capture_output=True,text=True,env=environment,check=True,timeout=30)
        return json.loads(result.stdout)
    profile=dict(id=str(uuid.uuid4()),name='Service fixture',origins=['https://example.test'],repositoryPath='',documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])
    command('configure',projects=[profile])
    observation=command('new',projectId=profile['id'])['observationUpdates'][0]
    other=command('new',projectId=profile['id'])['observationUpdates'][0]
    note='Keep this manual note across status updates.\n'*1000
    edited=command('edit',observationId=observation['id'],markdown=note)
    assert 'observations' not in edited and len(edited['observationUpdates'])==1
    assert edited['observationUpdates'][0]['markdown']==note
    sync=command('sync')
    assert 'observations' not in sync,'A status-only bridge sync must not serialize the complete notebook.'
    assert sync['update']['capturedObservationIDs']==[]
    assert len(json.dumps(sync))<32*1024
    snapshot=command('bootstrap')['observations']
    assert next(o for o in snapshot if o['id']==observation['id'])['markdown']==note
    assert len(snapshot)==2
    assert command('archive',observationId=observation['id'])['observationUpdates'][0]['archivedAt']
    capture=str(uuid.uuid4());client=str(uuid.uuid4())
    identity=dict(projectId=profile['id'],clientId=client,tabId=1,windowId=1,documentId='fixture-doc',url='https://example.test/page',title='Capture fixture',capturedAt=1)
    tab=dict(tabId=1,windowId=1,projectId=profile['id'],url=identity['url'],title=identity['title'],mode='deep',documentId='fixture-doc',armedAt=0,capabilities=[],active=True,selected=True)
    envelopes=[('capture-started',dict(initiatedBy='extension',identity=identity,tab=tab)),('capture',dict(identity=identity,events=[],gaps=[],context={},screenshotBase64=base64.b64encode(b'\x89PNG\r\n\x1a\nfixture').decode()))]
    inbox=Path(directory)/'bridge/inbox'
    def deliver(index,kind,payload):
        (inbox/f'{index}.json').write_text(json.dumps(dict(version=1,id=str(uuid.uuid4()),kind=kind,payload=dict(payload,observationId=observation['id'],captureId=capture,clientId=client))))
    for index,(kind,payload) in enumerate(envelopes):deliver(index,kind,payload)
    captured=command('sync')
    assert 'observations' not in captured and len(captured['observationUpdates'])==1
    assert captured['observationUpdates'][0]['id']==observation['id']
    assert len(captured['observationUpdates'][0]['captures'])==1
    deliver(2,*envelopes[-1])
    assert len(command('sync')['observationUpdates'][0]['captures'])==1,'A replay must not duplicate a capture.'
    snapshot=command('bootstrap')['observations']
    assert len(snapshot)==2 and any(o['id']==other['id'] for o in snapshot)
    assert next(o for o in snapshot if o['id']==observation['id'])['markdown']==note
print('Service smoke passed: incremental edits/captures, replay deduplication, explicit refresh, preserved notes and unrelated observations.')
