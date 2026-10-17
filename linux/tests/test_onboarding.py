import sys
from pathlib import Path
import unittest
import json
import tempfile

sys.path.insert(0,str(Path(__file__).parents[1]))
from onboarding import project_from_url,extension_id


class OnboardingTests(unittest.TestCase):
    def test_setup_keeps_only_canonical_origin_and_never_grants_browser_access(self):
        profile=project_from_url('HTTPS://Example.COM:443/private?token=secret#page','Example')
        self.assertEqual(profile['origins'],['https://example.com'])
        self.assertEqual(profile['name'],'Example')
        self.assertTrue(profile['enabled'])
        self.assertNotIn('secret',str(profile))
        self.assertEqual(project_from_url('localhost:3000/page')['origins'],['http://localhost:3000'])
        self.assertEqual(project_from_url('http://[::1]:3000/')['origins'],['http://[::1]:3000'])
        with self.assertRaises(ValueError):project_from_url('https://user:password@example.com')
        with self.assertRaises(ValueError):project_from_url('file:///home/private')

    def test_extension_identity_matches_the_shipped_public_key(self):
        folder=Path(__file__).parents[2]/'extension/public'
        self.assertEqual(extension_id(folder),'mfpclfngcgiahifebjbjlgagmlflcjpg')
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)
            (folder/'manifest.json').write_text(json.dumps({'browser_specific_settings':{'gecko':{'id':'native-browser-lens@sirv.studio'}}}))
            self.assertEqual(extension_id(folder),'native-browser-lens@sirv.studio')
