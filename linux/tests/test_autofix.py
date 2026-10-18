import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parents[1]))
import autofix
import fix_verify


class AutoFixTests(unittest.TestCase):
    def test_codex_can_execute_bundled_tools_without_reading_notebook_or_raw_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);store=root/'private';app=store/'app';app.mkdir(parents=True)
            executable=app/'codex';executable.write_text('fixture runtime')
            jobroot=root/'job';(jobroot/'evidence').mkdir(parents=True);(jobroot/'source').mkdir();(jobroot/'temporary').mkdir()
            job=dict(directory=str(jobroot),repository=str(root/'repo'),gitDirectory=str(root/'repo/.git'),projectRelative='.')
            def execute(arguments,cwd,log,cancel,**kwargs):
                options=[arguments[i+1] for i,arg in enumerate(arguments[:-1]) if arg=='-c']
                config=tomllib.loads('\n'.join(options));rules=config['permissions']['lens_fix']['filesystem']
                self.assertEqual(rules[str(app)],'read')
                self.assertNotIn(str(store),rules)
                self.assertEqual(rules[str(store/'observations')],'deny')
                self.assertEqual(rules[str(store/'notebook.sqlite')],'deny')
                self.assertNotIn(str(jobroot/'evidence'),rules)
                self.assertNotIn(str(jobroot/'runs'),rules)
                self.assertNotIn(job['gitDirectory'],rules)
                self.assertEqual(config['shell_environment_policy']['inherit'],'none')
                self.assertNotIn('OPENAI_API_KEY',kwargs['environment'])
                log.write_text(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'{"summary":"fixture"}'}})+'\n'+json.dumps({'type':'turn.completed'})+'\n')
            with patch.dict(autofix.os.environ,{'LENS_DATA_DIR':str(store),'OPENAI_API_KEY':'fixture-only'}),patch.object(autofix.onboarding,'codex_binary',return_value=str(executable)),patch.object(autofix,'command',side_effect=execute):
                self.assertEqual(autofix.codex(job,jobroot/'source','fixture','fix',{},threading.Event())['summary'],'fixture')

    def test_user_runtime_mounts_do_not_expose_the_home_or_local_data_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);binary=home/'.local/bin/custom';binary.parent.mkdir(parents=True);binary.write_text('runtime')
            with patch.object(fix_verify.Path,'home',return_value=home),patch.object(fix_verify.shutil,'which',return_value=str(binary)):
                self.assertEqual(fix_verify.runtime_mounts(['custom']),[str(binary)])

    def test_resolves_playwright_browser_before_replacing_home(self):
        with tempfile.TemporaryDirectory() as directory:
            browser=Path(directory)/'cached-chromium';browser.write_text('fixture runtime');browser.chmod(0o700)
            with patch.object(autofix.shutil,'which',return_value=None),patch.object(autofix.subprocess,'check_output',return_value=str(browser)+'\n') as probe:
                self.assertEqual(autofix.browser_binary(Path(directory)),str(browser))
                self.assertEqual(probe.call_args.kwargs['cwd'],Path(directory))
            browser.unlink()
            with patch.object(autofix.shutil,'which',return_value=None),patch.object(autofix.subprocess,'check_output',return_value=str(browser)):
                with self.assertRaisesRegex(ValueError,'Install Chromium'):autofix.browser_binary(Path(directory))

    def test_worktree_preserves_dirty_source_and_plan_cannot_choose_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            repo=Path(directory)/'project';repo.mkdir()
            def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
            git('init','-q');git('config','user.name','Test');git('config','user.email','test@example.test')
            (repo/'app.txt').write_text('saved source');git('add','app.txt');git('commit','-qm','base')
            (repo/'app.txt').write_text('uncommitted user edit')
            (repo/'node_modules').mkdir();(repo/'node_modules/cache.txt').write_text('original dependency cache')
            job=autofix.create_job(repo)
            self.assertEqual(job['baseCommit'],git('rev-parse','HEAD'))
            tree=autofix.add_worktree(job,'source')
            self.assertEqual((tree/'app.txt').read_text(),'saved source')
            self.assertEqual((repo/'app.txt').read_text(),'uncommitted user edit')
            self.assertFalse((tree/'node_modules').is_symlink())
            (tree/'node_modules/cache.txt').write_text('worktree cache')
            self.assertEqual((repo/'node_modules/cache.txt').read_text(),'original dependency cache')
            (tree/'.gitignore').write_text('runtime-cache\n')
            (tree/'runtime-cache').write_text('A false fix that exists only in ignored state')
            (tree/'app.txt').write_text('fixed saved source')
            patch_file=Path(job['directory'])/'fix.patch';patch_file.write_bytes(autofix.patch_bytes(job,tree))
            (repo/'node_modules/cache.txt').write_text('dependencies changed after job start')
            verified=autofix.add_worktree(job,'verified')
            autofix.tree_git(job,verified,'apply','--binary',str(patch_file))
            self.assertFalse((verified/'runtime-cache').exists())
            self.assertEqual((verified/'node_modules/cache.txt').read_text(),'original dependency cache')
            self.assertEqual((verified/'app.txt').read_text(),'fixed saved source')
            self.assertEqual(autofix.patch_bytes(job,verified),patch_file.read_bytes())
            (verified/'.git').unlink();(verified/'.git').write_text('gitdir: /untrusted-config')
            self.assertEqual(autofix.patch_bytes(job,verified),patch_file.read_bytes())
            self.assertEqual(autofix.tree_git(job,verified,'rev-parse','HEAD'),job['baseCommit'])
            self.assertEqual(Path(job['directory']).stat().st_mode&0o777,0o700)
            valid=[{'op':'goto','url':'https://example.test/page'},{'op':'click','selector':'#save'}]
            self.assertEqual(autofix.validate_steps(valid,'https://example.test'),valid)
            for steps in ([{'op':'goto','url':'https://attacker.test'}],[{'op':'shell','command':'rm -rf /'}],[{'op':'fill','selector':'#x','value':'ok','command':'ignored'}],[]):
                with self.assertRaises(ValueError):autofix.validate_steps(steps,'https://example.test')
            subprocess.run(['git','-C',str(repo),'worktree','remove','--force',str(tree)],check=True)

    def test_dependency_copy_rejects_a_committed_destination_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo=root/'project';repo.mkdir();external=root/'original-dependencies';external.mkdir()
            (external/'cache').write_text('preserve original')
            autofix.git(repo,'init','-q');autofix.git(repo,'config','user.name','Test');autofix.git(repo,'config','user.email','test@example.test')
            (repo/'node_modules').symlink_to(external,target_is_directory=True)
            autofix.git(repo,'add','.');autofix.git(repo,'commit','-qm','committed dependency link')
            job=autofix.create_job(repo)
            with self.assertRaisesRegex(ValueError,'symlink'):autofix.add_worktree(job,'source')
            self.assertEqual((external/'cache').read_text(),'preserve original')

    def test_patch_creation_does_not_execute_repository_clean_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo=root/'project';repo.mkdir();canary=root/'host-filter-ran'
            autofix.git(repo,'init','-q');autofix.git(repo,'config','user.name','Test');autofix.git(repo,'config','user.email','test@example.test')
            (repo/'app.txt').write_text('before');(repo/'.gitattributes').write_text('*.txt filter=fixture\n')
            autofix.git(repo,'add','.');autofix.git(repo,'commit','-qm','baseline')
            autofix.git(repo,'config','filter.fixture.clean','touch '+str(canary)+'; cat')
            job=autofix.create_job(repo);tree=autofix.add_worktree(job,'source')
            self.assertFalse(canary.exists(),'Source checkout must not invoke host Git filters.')
            (tree/'.gitattributes').write_text('*.txt filter=fixture\n');(tree/'app.txt').write_text('after')
            self.assertIn(b'after',autofix.patch_bytes(job,tree))
            self.assertFalse(canary.exists(),'Edited attributes must not invoke host Git filters.')

    def test_dependency_copy_replaces_private_descendants_without_following_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo=root/'project';repo.mkdir();canary=root/'original-file';canary.write_text('preserve me')
            autofix.git(repo,'init','-q');autofix.git(repo,'config','user.name','Test');autofix.git(repo,'config','user.email','test@example.test')
            cache=repo/'node_modules/pkg/cache';cache.parent.mkdir(parents=True);cache.symlink_to(canary)
            autofix.git(repo,'add','.');autofix.git(repo,'commit','-qm','committed descendant link')
            cache.unlink();cache.write_text('current installed cache')
            job=autofix.create_job(repo);tree=autofix.add_worktree(job,'source')
            self.assertEqual(canary.read_text(),'preserve me')
            self.assertFalse((tree/'node_modules/pkg/cache').is_symlink())
            self.assertEqual((tree/'node_modules/pkg/cache').read_text(),'current installed cache')

    def test_verification_rejects_changed_contract_script_steps_status_and_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);artifact=root/'network.har';artifact.write_text('{}')
            condition={'type':'http-status','url':'https://example.test/api','method':'GET','failureStatus':500,'successStatus':200}
            contract={'observationId':'o','captureId':'c','failureEventId':'e','condition':condition}
            config={'contract':contract,'contractSHA256':autofix.hash_json(contract),'steps':[{'op':'goto','url':'https://example.test/'}]}
            result={**contract,'contractSHA256':config['contractSHA256'],'stepsSHA256':autofix.hash_json(config['steps']),'scriptSHA256':'a'*64,'executionComplete':True,'observedStatus':500,'matchingResponseCount':1,'phase':'before','artifacts':[{'file':'network.har','sha256':hashlib.sha256(b'{}').hexdigest(),'type':'har'}]}
            path=root/'result.json';path.write_text(json.dumps(result))
            self.assertEqual(autofix.checked_result(path,config,'a'*64,'before')['observedStatus'],500)
            for key,value in [('stepsSHA256','b'*64),('scriptSHA256','b'*64),('observedStatus',200),('matchingResponseCount',2),('executionComplete',False)]:
                path.write_text(json.dumps({**result,key:value}))
                with self.assertRaises(ValueError):autofix.checked_result(path,config,'a'*64,'before')
            path.write_text(json.dumps(result));artifact.write_text('changed')
            with self.assertRaises(ValueError):autofix.checked_result(path,config,'a'*64,'before')

    def test_cancel_stops_owned_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            cancel=threading.Event();cancel.set()
            with self.assertRaisesRegex(ValueError,'cancelled'):
                autofix.command([sys.executable,'-c','import time; time.sleep(30)'],Path(directory),Path(directory)/'log',cancel,timeout=3)

    def test_cancellation_terminates_a_running_child_that_ignores_sigterm(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);pid=root/'child.pid';cancel=threading.Event()
            program='import subprocess,sys,time; from pathlib import Path; p=subprocess.Popen([sys.executable,"-c","import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"]); Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(30)'
            timer=threading.Timer(.5,cancel.set);timer.start()
            try:
                with self.assertRaisesRegex(ValueError,'cancelled'):autofix.command([sys.executable,'-c',program,str(pid)],root,root/'log',cancel,timeout=4)
            finally:timer.cancel()
            self.assertTrue(pid.is_file())
            child=int(pid.read_text());status=Path('/proc')/str(child)/'stat';deadline=time.monotonic()+2
            while status.exists() and status.read_text().split()[2]!='Z' and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(not status.exists() or status.read_text().split()[2]=='Z','The owned descendant must be stopped.')
