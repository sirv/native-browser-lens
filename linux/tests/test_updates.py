import hashlib
import io
import json
from pathlib import Path
import platform
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parents[1]))
import updates


class UpdateTests(unittest.TestCase):
    def archive(self,escape=False):
        output=io.BytesIO();content=b'fixture'
        manifest=json.dumps(dict(formatVersion=1,architecture=platform.machine(),version='0.3.0',files={'notebook.py':hashlib.sha256(content).hexdigest()})).encode()
        with tarfile.open(fileobj=output,mode='w:gz') as archive:
            for name,data in [('release/notebook.py',content),('release/release.json',manifest)]+([('../outside',b'bad')] if escape else []):
                entry=tarfile.TarInfo(name);entry.size=len(data);archive.addfile(entry,io.BytesIO(data))
        return output.getvalue()

    def test_download_verifies_digest_and_release_manifest(self):
        payload=self.archive()
        asset=dict(name='native-browser-lens-0.3.0-linux-'+platform.machine()+'.tar.gz',browser_download_url=updates.REPOSITORY+'/releases/download/v0.3.0/release.tar.gz',size=len(payload),digest='sha256:'+hashlib.sha256(payload).hexdigest())
        with tempfile.TemporaryDirectory() as directory,patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(payload)):
            folder=updates.download(asset,Path(directory))
            self.assertEqual((folder/'notebook.py').read_bytes(),b'fixture')

    def test_bad_digest_or_tar_path_cannot_install_or_write_outside_staging(self):
        for escape in (False,True):
            payload=self.archive(escape)
            asset=dict(name='native-browser-lens-0.3.0-linux-'+platform.machine()+'.tar.gz',browser_download_url=updates.REPOSITORY+'/releases/download/v0.3.0/release.tar.gz',size=len(payload),digest='sha256:'+(hashlib.sha256(payload).hexdigest() if escape else '0'*64))
            with tempfile.TemporaryDirectory() as directory,patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(payload)):
                with self.assertRaises(ValueError):updates.download(asset,Path(directory))
                self.assertFalse((Path(directory)/'outside').exists())

    def test_unpublished_or_other_architecture_is_not_offered_as_an_update(self):
        release={'tag_name':'v0.3.0','assets':[{'name':'native-browser-lens-macos.zip'}]}
        with patch.object(updates.urllib.request,'urlopen',return_value=io.BytesIO(json.dumps(release).encode())):
            self.assertFalse(updates.check('0.2.0')['available'])
