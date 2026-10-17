import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

REPO=Path(__file__).resolve().parents[2]
SERVICE=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=REPO,text=True).strip())/'lens-service'


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.env={**os.environ,'LENS_DATA_DIR':self.directory.name,'XDG_CONFIG_HOME':self.directory.name+'/config'}
        self.profile=dict(id=str(uuid.uuid4()),name='Fixture',origins=['http://localhost:3000'],repositoryPath=str(REPO),documentationPaths=[],recording='diagnostics',enabled=True,adapter='sirv-studio',ownership=[dict(pattern='src/**',memberId='fixture-member',label='Fixture owner')],logPaths=[])
        self.command('configure',projects=[self.profile])
        self.item=self.command('new',projectId=self.profile['id'])['observationUpdates'][0]

    def tearDown(self):self.directory.cleanup()

    def command(self,action,**payload):
        result=subprocess.run([str(SERVICE)],input=json.dumps(dict(action=action,**payload)),env=self.env,text=True,capture_output=True,timeout=20)
        self.events=[json.loads(line) for line in result.stdout.splitlines()]
        return self.events[-1]

    def test_theme_and_full_project_settings_survive_a_new_helper_process(self):
        response=self.command('settings',settings={'appearance':'light'})
        self.assertEqual(response['settings']['appearance'],'light')
        response=self.command('bootstrap')
        self.assertEqual(response['settings']['appearance'],'light')
        self.assertEqual(response['projects'][0]['ownership'],self.profile['ownership'])
        self.assertIn('error',self.command('settings',settings={'appearance':'invalid'}))

    def test_browser_permissions_open_only_in_the_selected_connected_profile(self):
        self.assertIn('error',self.command('openOptions',payload={}))
        clients=[str(uuid.uuid4()) for _ in range(2)]
        for identity in clients:
            folder=Path(self.directory.name)/'bridge/clients'/identity;folder.mkdir(parents=True)
            (folder/'.owner-pid').write_text(str(os.getpid()))
        result=self.command('openOptions',payload={'clientId':clients[0]})
        self.assertNotIn('error',result)
        first=list((Path(self.directory.name)/'bridge/clients'/clients[0]).glob('*.json'))
        self.assertEqual(len(first),1)
        self.assertEqual(json.loads(first[0].read_text())['kind'],'openOptions')
        self.assertFalse(list((Path(self.directory.name)/'bridge/clients'/clients[1]).glob('*.json')))

    def test_pause_survives_restart_without_disabling_the_saved_project(self):
        self.command('settings',settings={'capturePaused':'true'})
        response=self.command('bootstrap')
        self.assertTrue(response['projects'][0]['enabled'])
        configuration=Path(self.directory.name)/'bridge/projects.json'
        self.assertFalse(json.loads(configuration.read_text())[0]['enabled'])
        self.command('settings',settings={'capturePaused':'false'})
        self.assertTrue(json.loads(configuration.read_text())[0]['enabled'])

    def test_investigation_returns_a_draft_without_overwriting_manual_text(self):
        self.command('edit',observationId=self.item['id'],markdown='Keep my manual report.')
        response=self.command('investigate',observationId=self.item['id'],stream=True)
        self.assertIn('suggestedDraft',response)
        self.assertEqual(response['observationUpdates'][0]['markdown'],'Keep my manual report.')
        self.assertEqual(response['investigationObservationId'],self.item['id'])
        self.assertTrue(any('progress' in event for event in self.events))

    def test_cloud_rejects_changed_review_before_reading_a_provider_key(self):
        self.command('edit',observationId=self.item['id'],markdown='New unreviewed text')
        response=self.command('cloud',observationId=self.item['id'],reviewedVersion=self.item['editVersion'],reviewed=True,captureIds=[])
        self.assertIn('changed',response['error'].lower())

    def test_filing_rejects_changed_review_before_network_or_credentials(self):
        snapshot=self.command('reviewFiling',observationId=self.item['id'])['review']
        self.command('edit',observationId=self.item['id'],markdown='Changed after review')
        response=self.command('file',observationId=snapshot['id'],revision=snapshot['draftRevision'],reviewedVersion=snapshot['editVersion'],reviewed=True,assigneeId='')
        self.assertIn('changed',response['error'].lower())
