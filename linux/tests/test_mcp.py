import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

REPO = Path(__file__).resolve().parents[2]


class MCPTests(unittest.TestCase):
    def test_stdio_discovery_queries_images_and_export_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            exports = root / 'exports'; exports.mkdir()
            report = exports / 'reviewed'; report.mkdir()
            project, capture, event = [str(uuid.uuid4()) for _ in range(3)]
            image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSmQAAAAASUVORK5CYII=')
            (report / 'capture.png').write_bytes(image)
            (report / 'evidence.json').write_text(json.dumps(dict(id=str(uuid.uuid4()),projectId=project,createdAt=1,title='Reviewed defect',markdown='Manual note',draftRevision=1,editVersion=1,findings=[],captures=[dict(id=capture,identity=dict(projectId=project,tabId=1,windowId=1,documentId='document',url='https://fixture.example/',title='Fixture',capturedAt=1),events=[dict(id=event,projectId=project,tabId=1,documentId='document',timestamp=1,kind='response',data=dict(status=500,url='https://fixture.example/api',method='GET'))],gaps=[],context={},annotations=[],screenshotPath='capture.png')])))
            (exports / 'escape').symlink_to(report, target_is_directory=True)
            messages=[dict(jsonrpc='2.0',id=1,method='initialize',params={'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}}),dict(jsonrpc='2.0',method='notifications/initialized'),dict(jsonrpc='2.0',id=2,method='tools/list')]
            for index,name,args in [(3,'lens_list_reports',{}),(4,'lens_inspect',{'report':'reviewed'}),(5,'lens_event',{'report':'reviewed','id':event}),(6,'lens_image',{'report':'reviewed','id':capture}),(7,'lens_inspect',{'report':'../private'}),(8,'lens_inspect',{'report':'escape'}),(9,'lens_inspect',{'report':'reviewed','command':'handoff'})]:
                messages.append(dict(jsonrpc='2.0',id=index,method='tools/call',params={'name':name,'arguments':args}))
            result=subprocess.run([sys.executable,str(REPO/'linux/mcp_server.py'),str(exports)],input='\n'.join(map(json.dumps,messages))+'\n',capture_output=True,text=True,env={**os.environ,'LENS_EVIDENCE_BINARY':str(REPO/'.build/debug/lens-evidence')},timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            replies={item['id']:item for item in map(json.loads,result.stdout.splitlines())}
            self.assertEqual(len(replies),9)
            self.assertEqual(replies[1]['result']['protocolVersion'],'2025-11-25')
            tools=replies[2]['result']['tools']
            self.assertTrue(all(tool['annotations']['readOnlyHint'] for tool in tools))
            self.assertFalse(any('fix' in tool['name'] or 'file' in tool['name'] for tool in tools))
            self.assertEqual([x['report'] for x in replies[3]['result']['structuredContent']['items']],['reviewed'])
            self.assertEqual(replies[4]['result']['structuredContent']['observation']['markdown'],'Manual note')
            self.assertEqual(replies[5]['result']['structuredContent']['data']['status'],500)
            self.assertEqual(base64.b64decode(replies[6]['result']['content'][1]['data']),image)
            for index in (7,8,9):self.assertTrue(replies[index]['result']['isError'])

    def test_invalid_messages_and_notification_have_no_protocol_noise(self):
        with tempfile.TemporaryDirectory() as directory:
            result=subprocess.run([sys.executable,str(REPO/'linux/mcp_server.py'),directory],input='bad json\n[]\n'+json.dumps({'jsonrpc':'2.0','method':'notifications/cancelled','params':{}})+'\n',capture_output=True,text=True,timeout=5)
            replies=[json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual([r['error']['code'] for r in replies],[-32700,-32600])
