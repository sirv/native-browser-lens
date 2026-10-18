"""Exercise an actual release install, its bundled helpers, update rollback and notebook preservation."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

parser=argparse.ArgumentParser();parser.add_argument('bundle',type=Path);args=parser.parse_args()
source=args.bundle.resolve()
spec=importlib.util.spec_from_file_location('lens_installer',source/'install.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
installer.verify_bundle(source)
with tempfile.TemporaryDirectory(prefix='lens release with spaces ') as directory:
    root=Path(directory)
    (root/'codex-empty').mkdir(mode=0o700)
    environment={'XDG_DATA_HOME':str(root/'data'),'XDG_CONFIG_HOME':str(root/'config'),'CODEX_HOME':str(root/'codex-empty'),'LENS_CODEX_BINARY':''}
    with patch.dict(os.environ,environment),patch.object(Path,'home',return_value=root/'home'),patch.object(installer,'stop_running'),contextlib.redirect_stdout(io.StringIO()):
        app=installer.main(source)
        def command(action,**payload):
            process=subprocess.run([str(app/'lens-service')],input=json.dumps(dict(action=action,**payload)),capture_output=True,text=True,timeout=30)
            result=json.loads(process.stdout)
            assert process.returncode==0,result.get('error')
            return result
        import uuid
        profile=dict(id=str(uuid.uuid4()),name='Installed release fixture',origins=['http://localhost:3000'],repositoryPath='',documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])
        command('configure',projects=[profile])
        item=command('new',projectId=profile['id'])['observationUpdates'][0]
        command('edit',observationId=item['id'],markdown='Preserve my installed notebook across update and rollback.')
        installer.main(source)
        installer.rollback()
        state=command('bootstrap')
        assert state['observations'][0]['markdown']=='Preserve my installed notebook across update and rollback.'
        assert (root/'home/.local/bin/native-browser-lens').is_file()
        assert (app/'codex').is_file()
        assert (app/'codex-code-mode-host').is_file()
        assert command('codexStatus')['codexStatus']=='signIn','The packaged helper must find its bundled Codex without a global installation.'
        cli=subprocess.run([str(root/'home/.local/bin/native-browser-lens'),'evidence','--help'],capture_output=True,text=True,timeout=30)
        assert cli.returncode==0 and 'portable exports' in cli.stdout,cli.stderr
        launcher=root/'home/.local/bin/native-browser-lens'
        exported=command('export',observationId=item['id'],destination=str(root/'exports'))['exportPath']
        messages=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'lens_inspect','arguments':{'report':Path(exported).name}}}]
        protocol=subprocess.run([str(launcher),'mcp',str(root/'exports')],input='\n'.join(map(json.dumps,messages))+'\n',capture_output=True,text=True,timeout=30)
        assert protocol.returncode==0,protocol.stderr
        replies=[json.loads(line) for line in protocol.stdout.splitlines()]
        assert all(tool['annotations']['readOnlyHint'] for tool in replies[1]['result']['tools'])
        assert replies[2]['result']['structuredContent']['observation']['markdown']==state['observations'][0]['markdown']
        fix_help=subprocess.run([str(launcher),'fix','--help'],capture_output=True,text=True,timeout=15)
        assert fix_help.returncode==0 and '--server-command' in fix_help.stdout and '--reviewed' in fix_help.stdout,fix_help.stderr
        assert (app/'reproduce.mjs').is_file()
        foreign=root/'untrusted project';foreign.mkdir()
        rogue=foreign/'libggml-cpu-rogue.so';rogue.write_bytes(b'not a backend')
        engine=subprocess.run([str(app/'whisper-cli'),'-m',str(app/'dictation-model.bin'),'-f','/dev/null','-t','1'],capture_output=True,text=True,timeout=30,cwd=foreign,env={**os.environ,'GGML_BACKEND_PATH':str(rogue)})
        assert engine.returncode==11 and 'whisper_model_load' in engine.stderr,engine.stderr
        assert 'loaded CPU backend from '+str(app/'lib') in engine.stderr,engine.stderr
        assert 'rogue' not in engine.stderr,'Backend discovery must stay inside the installed bundle.'
        manifest=json.loads((root/'config/google-chrome/NativeMessagingHosts/studio.sirv.native_browser_lens.json').read_text())
        assert manifest['path']==str(app/'lens-host')
        assert len(manifest['allowed_origins'])==1
        firefox=json.loads((root/'home/.mozilla/native-messaging-hosts/studio.sirv.native_browser_lens.json').read_text())
        assert firefox['allowed_extensions']==['native-browser-lens@sirv.studio']
        assert firefox['path']==str(app/'lens-host') and 'allowed_origins' not in firefox
print('Release smoke passed: verified install in a path with spaces, bundled runtime, native registrations, update, rollback and preserved notebook.')
