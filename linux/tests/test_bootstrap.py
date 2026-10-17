import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BootstrapTests(unittest.TestCase):
    def test_desktop_cli_and_missing_python_keep_arguments_and_use_only_package_manager_as_root(self):
        script=Path(__file__).resolve().parents[2]/'scripts/bootstrap-linux.sh'
        with tempfile.TemporaryDirectory(prefix='lens bootstrap ') as directory:
            root=Path(directory);tools=root/'tools';tools.mkdir()
            shutil.copy2(script,root/'Install.sh')
            (tools/'dirname').symlink_to(shutil.which('dirname'))
            python=tools/'python3'
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n');python.chmod(0o755)
            environment={**os.environ,'PATH':str(tools),'DISPLAY':':fixture','WAYLAND_DISPLAY':''}
            def run(*args):return subprocess.run(['/bin/sh',str(root/'Install.sh'),*args],env=environment,capture_output=True,text=True,check=True).stdout.splitlines()
            self.assertEqual(run('--source','a path with spaces'),[str(root/'install.py'),'--bootstrap','--gui','--source','a path with spaces'])
            self.assertEqual(run('--cli','--check'),[str(root/'install.py'),'--check'])
            environment['DISPLAY']=''
            self.assertEqual(run('--check'),[str(root/'install.py'),'--check'])
            python.rename(tools/'python-after-install')
            (tools/'apt-get').write_text('fixture')
            (tools/'apt-get').chmod(0o755)
            (tools/'mv').symlink_to(shutil.which('mv'))
            pkexec=tools/'pkexec'
            pkexec.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nmv "'+str(tools/'python-after-install')+'" "'+str(python)+'"\n');pkexec.chmod(0o755)
            check=subprocess.run(['/bin/sh',str(root/'Install.sh'),'--cli','--check'],env=environment,capture_output=True,text=True)
            self.assertNotEqual(check.returncode,0)
            self.assertIn('Install Python 3',check.stderr)
            self.assertFalse(python.exists(),'A CLI check must not install Python.')
            environment['DISPLAY']=':fixture'
            self.assertEqual(run('--source','a path with spaces'),['apt-get','install','-y','python3',str(root/'install.py'),'--bootstrap','--gui','--source','a path with spaces'])
