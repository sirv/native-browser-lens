import sys
from pathlib import Path
import unittest
import json
import tempfile
import subprocess
import zipfile
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parents[1]))
import onboarding
from onboarding import project_from_url,extension_id


class OnboardingTests(unittest.TestCase):
    def test_setup_lists_flatpak_firefox_without_changing_permissions(self):
        def which(name):return '/usr/bin/'+name if name in ('firefox','flatpak') else None
        with patch.object(onboarding.shutil,'which',side_effect=which),patch.object(onboarding.subprocess,'run') as run:
            run.return_value.returncode=0
            self.assertEqual(onboarding.available_browsers(),[('Firefox','/usr/bin/firefox'),('Firefox (Flatpak)',['/usr/bin/flatpak','run','org.mozilla.firefox'])])
            self.assertEqual(run.call_args.args[0],['/usr/bin/flatpak','info','org.mozilla.firefox'])
            run.side_effect=subprocess.TimeoutExpired('flatpak',3)
            self.assertEqual(onboarding.available_browsers(),[('Firefox','/usr/bin/firefox')])

    def test_temporary_xpi_contains_the_complete_addon_and_preserves_old_file_on_failure(self):
        with tempfile.TemporaryDirectory() as directory,patch.dict(onboarding.os.environ,{'XDG_CACHE_HOME':directory+'/cache'}):
            folder=Path(directory)/'extension';(folder/'icons').mkdir(parents=True)
            for name,value in [('manifest.json','{}'),('background.js','browser.runtime.connectNative("fixture");'),('icons/icon.png','synthetic icon')]:
                (folder/name).write_text(value)
            result=onboarding.temporary_firefox_xpi(folder)
            self.assertEqual(result.stat().st_mode&0o777,0o600)
            with zipfile.ZipFile(result) as archive:
                self.assertEqual(set(archive.namelist()),{'manifest.json','background.js','icons/icon.png'})
                self.assertEqual(archive.read('background.js'),(folder/'background.js').read_bytes())
            before=result.read_bytes()
            (folder/'private-link').symlink_to(Path(directory)/'private')
            with self.assertRaises(ValueError):onboarding.temporary_firefox_xpi(folder)
            self.assertEqual(result.read_bytes(),before)

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
