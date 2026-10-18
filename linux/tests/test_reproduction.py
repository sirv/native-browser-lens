import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('node'), 'Runner development check needs Node.js')
class ReproductionTests(unittest.TestCase):
    def test_double_slash_paths_keep_the_local_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);shutil.copyfile(Path(__file__).parents[1]/'reproduce.mjs',root/'reproduce.mjs')
            module=root/'node_modules/playwright';module.mkdir(parents=True)
            (module/'index.js').write_text('''const {writeFile}=require('node:fs/promises');let response;
exports.chromium={launch:async()=>({newContext:async options=>({tracing:{start:async()=>{},stop:async o=>writeFile(o.path,'trace')},newPage:async()=>({on:(_,callback)=>response=callback,goto:async url=>{if(url!=='http://127.0.0.1:41001//outside.invalid/check')throw Error('Escaped loopback origin: '+url);response({url:()=>url,request:()=>({method:()=> 'GET'}),status:()=>200});}}),newCDPSession:async()=>({send:async command=>command==='Profiler.stop'?{profile:{nodes:[]}}:{}}),close:async()=>writeFile(options.recordHar.path,'{}')}),close:async()=>{}})};''')
            contract={'observationId':'o','captureId':'c','failureEventId':'e','condition':{'type':'http-status','url':'https://capture.example//outside.invalid/check','method':'GET','failureStatus':500,'successStatus':200}}
            digest=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            (root/'handoff.json').write_text(json.dumps({'contract':contract,'contractSHA256':digest,'pageURL':'https://capture.example/','steps':[{'op':'goto','url':contract['condition']['url']}]}))
            result=subprocess.run(['node','reproduce.mjs','after','--reviewed'],cwd=root,env={**os.environ,'LENS_REPRO_ORIGIN':'http://127.0.0.1:41001'},capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            value=json.loads(Path(json.loads(result.stdout)['result']).read_text())
            self.assertEqual(value['observedStatus'],200)
            self.assertEqual(value['testOrigin'],'http://127.0.0.1:41001')

    def test_response_delivered_during_shutdown_cannot_turn_ambiguous_run_into_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).parents[1] / 'reproduce.mjs', root / 'reproduce.mjs')
            module = root / 'node_modules/playwright'
            module.mkdir(parents=True)
            # Model the real asynchronous response event arriving during CDP shutdown.
            (module / 'index.js').write_text('''
const {writeFile} = require('node:fs/promises');
let received;
const response = status => ({url: () => 'http://fixture.test/save', request: () => ({method: () => 'POST'}), status: () => status});
exports.chromium = {launch: async () => ({
  newContext: async options => ({
    tracing: {start: async () => {}, stop: async options => writeFile(options.path, 'trace fixture')},
    newPage: async () => ({on: (_, callback) => {received = callback}, goto: async () => received(response(200))}),
    newCDPSession: async () => ({send: async command => {
      if (command === 'Profiler.stop') {received(response(503)); return {profile: {nodes: []}}}
      return {};
    }}),
    close: async () => writeFile(options.recordHar.path, JSON.stringify({log: {entries: []}}))
  }),
  close: async () => {}
})};
''')
            contract = dict(observationId='fixture', captureId='capture', failureEventId='failure', condition=dict(type='http-status', url='http://fixture.test/save', method='POST', failureStatus=503, successStatus=200))
            digest = hashlib.sha256(json.dumps(contract, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            (root / 'handoff.json').write_text(json.dumps(dict(contract=contract, contractSHA256=digest, steps=[dict(op='goto', url='http://fixture.test/') ])))
            process = subprocess.run(['node', 'reproduce.mjs', 'after', '--reviewed'], cwd=root, text=True, capture_output=True, timeout=20)
            self.assertEqual(process.returncode, 1, process.stderr)
            result = json.loads(Path(json.loads(process.stdout)['result']).read_text())
            self.assertTrue(result['executionComplete'])
            self.assertEqual(result['matchingResponseCount'], 2)
            self.assertIsNone(result['observedStatus'])
