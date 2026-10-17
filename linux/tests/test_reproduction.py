import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('node'), 'Runner development check needs Node.js')
class ReproductionTests(unittest.TestCase):
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
