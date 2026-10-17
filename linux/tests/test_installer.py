import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

repo = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('installer', repo / 'scripts/install-linux.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_release_manifest_rejects_tampering_and_symlinked_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)
            (source/'notebook.py').write_text('original')
            import hashlib
            (source/'release.json').write_text(json.dumps({'formatVersion':1,'architecture':'x86_64','version':'0.2.0','files':{'notebook.py':hashlib.sha256(b'original').hexdigest()}}))
            self.assertEqual(installer.verify_bundle(source)['version'],'0.2.0')
            (source/'notebook.py').write_text('changed')
            with self.assertRaises(ValueError):installer.verify_bundle(source)
            (source/'notebook.py').unlink();(source/'notebook.py').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):installer.verify_bundle(source)

    def test_dependency_commands_use_the_host_package_manager(self):
        self.assertIn('pacman',installer.dependency_command('arch'))
        self.assertIn('apt-get',installer.dependency_command('debian'))
        self.assertIn('dnf',installer.dependency_command('fedora'))
        self.assertIn('gst-libav',installer.dependency_command('arch'))
        self.assertIn('gstreamer1.0-libav',installer.dependency_command('debian'))
        self.assertIn('gobject-introspection',installer.dependency_command('fedora'))
        self.assertIn('gstreamer1-plugins-bad-free',installer.dependency_command('fedora'))
        self.assertIn('libglvnd-gles',installer.dependency_command('fedora'))

    def test_media_preflight_rejects_a_missing_recording_decoder(self):
        def probe(command,**_):
            return subprocess.CompletedProcess(command,1 if command[-1] in ('avdec_h264','openh264dec') else 0,stdout='libx264',stderr='')
        with patch.object(installer.shutil,'which',return_value='/fixture/tool'),patch.object(installer.subprocess,'run',side_effect=probe):
            self.assertIn('GStreamer H.264 decoder (avdec_h264 or openh264dec)',installer.dependencies())
        with patch.object(installer.ctypes.util,'find_library',return_value=None):
            self.assertIn('OpenGL ES 2 runtime',installer.dependencies())

    def test_bootstrap_checks_payload_before_requesting_system_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory);(source/'release.json').write_text('{}')
            with patch.object(installer,'verify_bundle',side_effect=ValueError('invalid release')),patch.object(installer.subprocess,'run') as run:
                with self.assertRaisesRegex(ValueError,'invalid release'):installer.bootstrap(source)
                run.assert_not_called()
            with patch.object(installer,'verify_bundle'),patch.object(installer,'dependencies',side_effect=[['GTK'],[]]),patch.object(installer,'dependency_command',return_value=['apt-get','install','-y','python3-gi']),patch.object(installer.shutil,'which',return_value='/usr/bin/pkexec'),patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run:
                installer.bootstrap(source)
                self.assertEqual(run.call_args.args[0],['pkexec','apt-get','install','-y','python3-gi'])
            with patch.object(installer,'verify_bundle'),patch.object(installer,'dependencies',return_value=['GTK']),patch.object(installer.shutil,'which',return_value='/usr/bin/pkexec'),patch.object(installer.subprocess,'run',return_value=subprocess.CompletedProcess([],126)):
                with self.assertRaisesRegex(ValueError,'cancelled or failed'):installer.bootstrap(source)

    def test_exact_browser_registration_xdg_paths_spaces_and_existing_install_backup(self):
        with tempfile.TemporaryDirectory(prefix='lens installer ') as directory:
            root = Path(directory)
            fake_repo = root / 'repo'
            dist = fake_repo / 'dist/linux'
            (dist / 'extension').mkdir(parents=True)
            for name in installer.APP_FILES:
                if name=='extension/manifest.json':continue
                (dist / name).write_text('fixture build')
            (dist / 'extension/manifest.json').write_text((repo / 'extension/public/manifest.json').read_text())
            (dist/'extension/icons').mkdir()
            (dist/'extension/icons/lens.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
            (dist/'extension-firefox').mkdir()
            (dist/'extension-firefox/manifest.json').write_text(json.dumps({'browser_specific_settings':{'gecko':{'id':'native-browser-lens@sirv.studio'}}}))
            env = {'HOME': str(root / 'home'), 'XDG_DATA_HOME': str(root / 'data'), 'XDG_CONFIG_HOME': str(root / 'config')}
            with patch.dict(os.environ, env), patch.object(installer, '__file__', str(fake_repo / 'scripts/install-linux.py')), contextlib.redirect_stdout(io.StringIO()):
                with patch.object(installer.subprocess,'Popen') as launched:
                    installer.main(check=False,launch=True)
                    self.assertIn('--setup',launched.call_args.args[0])
                app = root / 'data/native-browser-lens/app'
                (app / 'lens-host').write_text('previous build')
                with patch.object(installer.subprocess,'Popen') as launched:
                    installer.main(check=False,launch=True)
                    self.assertNotIn('--setup',launched.call_args.args[0])
                with (app.parent/'.install.lock').open('a') as lock:
                    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    with self.assertRaisesRegex(ValueError,'Another Lens installer'):installer.main(check=False)
                    with self.assertRaisesRegex(ValueError,'Another Lens installer'):installer.rollback()
            for browser in ('chromium', 'google-chrome'):
                manifest = root / 'config' / browser / 'NativeMessagingHosts/studio.sirv.native_browser_lens.json'
                value = json.loads(manifest.read_text())
                self.assertEqual(value['path'], str(app / 'lens-host'))
                self.assertEqual(value['allowed_origins'], ['chrome-extension://mfpclfngcgiahifebjbjlgagmlflcjpg/'])
                self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
            backup = next((root / 'data/native-browser-lens').glob('app-backup-*'))
            firefox=json.loads((root/'home/.mozilla/native-messaging-hosts/studio.sirv.native_browser_lens.json').read_text())
            self.assertEqual(firefox['allowed_extensions'],['native-browser-lens@sirv.studio'])
            self.assertNotIn('allowed_origins',firefox)
            self.assertEqual(firefox['path'],str(app/'lens-host'))
            self.assertEqual((backup / 'lens-host').read_text(), 'previous build')
            launcher = root / 'home/.local/bin/native-browser-lens'
            subprocess.run(['sh', '-n', str(launcher)], check=True)
            self.assertEqual(launcher.stat().st_mode & 0o777, 0o700)
            self.assertIn('Icon=studio.sirv.NativeBrowserLens',(root/'data/applications/studio.sirv.NativeBrowserLens.desktop').read_text())
            self.assertEqual((root/'data/icons/hicolor/scalable/apps/studio.sirv.NativeBrowserLens.svg').read_text(),'<svg xmlns="http://www.w3.org/2000/svg"/>')
            original_launcher=launcher.read_bytes()
            with patch.dict(os.environ,env),patch.object(installer,'__file__',str(fake_repo/'scripts/install-linux.py')),patch.object(installer,'write_private',side_effect=OSError('Injected disk write failure')):
                (dist/'lens-host').write_text('failed new build')
                with self.assertRaises(OSError):installer.main(check=False)
            self.assertEqual((app/'lens-host').read_text(),'fixture build')
            self.assertEqual(launcher.read_bytes(),original_launcher)
            notebook=app.parent/'notebook.sqlite';notebook.write_text('saved notebook fixture')
            with patch.dict(os.environ,env),patch.object(installer,'stop_running'):
                installer.rollback()
            self.assertEqual((app/'lens-host').read_text(),'previous build')
            self.assertEqual(notebook.read_text(),'saved notebook fixture')


if __name__ == '__main__':
    unittest.main()
