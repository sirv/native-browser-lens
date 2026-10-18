#!/usr/bin/env python3
"""Build a precompiled user installer with its Swift runtime and Codex CLI."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

REPO=Path(__file__).resolve().parent.parent


def checksum(path):
    value=hashlib.sha256()
    with path.open('rb') as source:
        while chunk:=source.read(1024*1024):value.update(chunk)
    return value.hexdigest()


def bundle_codex(folder):
    executable=shutil.which('codex')
    if not executable:raise ValueError('Install the full Codex distribution before building a subscription-enabled release.')
    executable=Path(executable).resolve()
    companion=executable.with_name('codex-code-mode-host')
    if not companion.is_file():raise ValueError('The Codex distribution is missing codex-code-mode-host, required for fix execution tools.')
    for path in (executable,companion):shutil.copy2(path,folder/path.name)
    return executable


def bundle_runtime(folder):
    libraries={}
    loader=None
    shared=list(folder.glob('lib*.so*'))
    for binary in [folder/name for name in ('lens-host','lens-service','lens-evidence','whisper-cli')]+shared:
        output=subprocess.check_output(['ldd',str(binary)],text=True)
        if 'not found' in output:raise ValueError('The build host has unresolved runtime libraries.')
        for value in re.findall(r'(/[^\s()]+)',output):
            source=Path(value)
            if not source.is_file():continue
            previous=libraries.get(source.name)
            if previous and checksum(previous)!=checksum(source):raise ValueError('Runtime library name collision: '+source.name)
            libraries[source.name]=source
        if binary in shared:
            previous=libraries.get(binary.name)
            if previous and checksum(previous)!=checksum(binary):raise ValueError('Runtime library name collision: '+binary.name)
            libraries[binary.name]=binary
            continue
        name=binary.name
        interpreter=Path(subprocess.check_output(['patchelf','--print-interpreter',str(binary)],text=True).strip())
        libraries[interpreter.name]=interpreter
        if loader is not None and loader!=interpreter.name:raise ValueError('The helper binaries require different runtime loaders.')
        loader=interpreter.name
        binary.rename(folder/(name+'.bin'))
        discovery='unset GGML_BACKEND_PATH\ncd "$LENS_APP_DIR/lib" || exit 1\n' if name=='whisper-cli' else ''
        binary.write_text('#!/bin/sh\nLENS_APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1\n'+discovery+'exec "$LENS_APP_DIR/lib/'+loader+'" --library-path "$LENS_APP_DIR/lib" "$LENS_APP_DIR/'+name+'.bin" "$@"\n')
        binary.chmod(0o755)
    (folder/'lib').mkdir()
    for name,source in libraries.items():shutil.copy2(source,folder/'lib'/name)
    for path in shared:path.unlink()
    return libraries


def make_installer(archive,destination):
    payload_hash=checksum(archive)
    header='''#!/bin/sh
set -eu
LENS_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lens-install.XXXXXX")
trap 'rm -rf "$LENS_TEMP_DIR"' EXIT HUP INT TERM
LENS_PAYLOAD_LINE=$(awk '/^__LENS_PAYLOAD_BELOW__$/{print NR+1;exit}' "$0")
tail -n +"$LENS_PAYLOAD_LINE" "$0" > "$LENS_TEMP_DIR/release.tar.gz"
printf '%s  %s\n' 'PAYLOAD_HASH' "$LENS_TEMP_DIR/release.tar.gz" | sha256sum -c - >/dev/null
tar -xzf "$LENS_TEMP_DIR/release.tar.gz" -C "$LENS_TEMP_DIR"
LENS_BUNDLE_DIR=$(find "$LENS_TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
sh "$LENS_BUNDLE_DIR/Install.sh" "$@"
exit 0
__LENS_PAYLOAD_BELOW__
'''.replace('PAYLOAD_HASH',payload_hash)
    with destination.open('wb') as output:
        output.write(header.encode())
        with archive.open('rb') as source:shutil.copyfileobj(source,output)
    destination.chmod(0o755)


def main(skip_build=False):
    if not skip_build:subprocess.run(['bash','scripts/build-app.sh'],cwd=REPO,check=True)
    subprocess.run(['python3','scripts/build-dictation.py'],cwd=REPO,check=True)
    source=REPO/'dist/linux'
    version=json.loads((source/'extension/manifest.json').read_text())['version']
    name='native-browser-lens-'+version+'-linux-'+platform.machine()
    releases=REPO/'dist/releases';releases.mkdir(parents=True,exist_ok=True)
    folder=releases/name
    if folder.exists():shutil.rmtree(folder)
    shutil.copytree(source,folder,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    libraries=bundle_runtime(folder)
    codex=bundle_codex(folder)
    licenses=folder/'licenses';licenses.mkdir()
    for path in [REPO/'LICENSE',Path('/usr/share/licenses/common')]:
        if path.is_dir():shutil.copytree(path,licenses/path.name)
        elif path.is_file():shutil.copy2(path,licenses/path.name)
    if shutil.which('pacman'):
        result=subprocess.run(['pacman','-Qoq',*[str(path) for path in libraries.values()]],capture_output=True,text=True)
        for package in sorted(set(result.stdout.splitlines())):
            path=Path('/usr/share/licenses')/package
            if path.is_dir():shutil.copytree(path,licenses/package,dirs_exist_ok=True)
    (licenses/'RUNTIME.txt').write_text('Unmodified runtime libraries bundled for compatibility:\n'+'\n'.join(sorted(libraries))+'\n\nCodex CLI: OpenAI, Apache-2.0. Source: https://github.com/openai/codex\nWhisper.cpp v1.9.5: MIT. Source: https://github.com/ggml-org/whisper.cpp\nOpenAI Whisper base.en model: MIT. Source: https://github.com/openai/whisper\nModel conversion: https://huggingface.co/ggerganov/whisper.cpp\n')
    subprocess.run(['python3','-c','import urllib.request; from pathlib import Path; Path(__import__("sys").argv[1]).write_bytes(urllib.request.urlopen("https://raw.githubusercontent.com/openai/codex/main/LICENSE",timeout=20).read())',str(licenses/'CODEX-LICENSE')],check=True)
    shutil.copy2(REPO/'scripts/bootstrap-linux.sh',folder/'Install.sh')
    (folder/'Install.sh').chmod(0o755)
    (folder/'README.txt').write_text('Native Browser Lens '+version+'\n\nRun Install.sh, or python3 install.py --gui. No Swift or Node.js installation is needed.\nThe installer checks desktop dependencies and preserves the previous build and notebook.\nBrowser setup opens on first installation. Load the provided Chrome/Chromium collector, approve your project origins, and use Alt+Shift+L to capture. Updates open the main notebook. Firefox has a separate extension-firefox folder and unsigned XPI: load it temporarily through about:debugging. Permanent Firefox installation requires Mozilla signing; signature checks stay enabled.\nAI investigation uses your existing Codex / ChatGPT sign-in; no API key is required.\nEnglish dictation uses bundled Whisper locally. Audio stays in memory and never enters a network request.\nTo restore the previous app build: python3 install.py --rollback --launch\nNotebook backups and Trash controls are in Notebook > Storage and backups.\n')
    files={str(path.relative_to(folder)):checksum(path) for path in folder.rglob('*') if path.is_file()}
    release=dict(formatVersion=1,version=version,architecture=platform.machine(),files=files,codexVersion=subprocess.check_output([str(codex),'--version'],text=True).strip())
    (folder/'release.json').write_text(json.dumps(release,indent=2)+'\n')
    archive=releases/(name+'.tar.gz')
    with tarfile.open(archive,'w:gz') as output:output.add(folder,arcname=name)
    installer=releases/(name+'.run');make_installer(archive,installer)
    extension_zip=releases/('native-browser-lens-extension-'+version+'.zip')
    with zipfile.ZipFile(extension_zip,'w',zipfile.ZIP_DEFLATED) as output:
        for path in (folder/'extension').rglob('*'):
            if path.is_file() and path.suffix!='.map':output.write(path,path.relative_to(folder/'extension'))
    firefox_zip=releases/('native-browser-lens-firefox-'+version+'-unsigned.xpi')
    with zipfile.ZipFile(firefox_zip,'w',zipfile.ZIP_DEFLATED) as output:
        for path in (folder/'extension-firefox').rglob('*'):
            if path.is_file() and path.suffix!='.map':output.write(path,path.relative_to(folder/'extension-firefox'))
    for path in (archive,installer,extension_zip,firefox_zip):path.with_name(path.name+'.sha256').write_text(checksum(path)+'  '+path.name+'\n')
    spec=importlib.util.spec_from_file_location('installer',REPO/'scripts/install-linux.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.verify_bundle(folder)
    print(json.dumps({'folder':str(folder),'installer':str(installer),'archive':str(archive),'extensionZip':str(extension_zip),'firefoxUnsignedXPI':str(firefox_zip),'installerMiB':round(installer.stat().st_size/1024/1024,1),'runtimeLibraries':len(libraries)},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--skip-build',action='store_true');args=parser.parse_args()
    main(args.skip_build)
