"""Verified release downloads; installation uses the already installed trusted helper."""
import hashlib
import importlib.util
import json
from pathlib import Path,PurePosixPath
import platform
import re
import shutil
import os
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.error
import urllib.request

REPOSITORY='https://github.com/VKrachun/native-browser-lens'


def installer_path():
    local=Path(__file__).with_name('install.py')
    return local if local.exists() else Path(__file__).resolve().parent.parent/'scripts/install-linux.py'


def verify(folder):
    spec=importlib.util.spec_from_file_location('lens_installer',installer_path())
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module.verify_bundle(folder)


def version(value):
    match=re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)',value)
    return tuple(map(int,match.groups())) if match else (0,0,0)


def check(current):
    request=urllib.request.Request('https://api.github.com/repos/VKrachun/native-browser-lens/releases/latest',headers={'Accept':'application/vnd.github+json','User-Agent':'Native-Browser-Lens/'+current})
    try:
        with urllib.request.urlopen(request,timeout=12) as response:
            data=response.read(512_001)
            if len(data)>512_000:raise ValueError('The release response is too large.')
            release=json.loads(data)
    except urllib.error.HTTPError as error:
        if error.code==404:return dict(available=False,message='No public Linux release has been published yet. You can install a verified release folder below.')
        raise ValueError('The release service is unavailable. Your installed app is unchanged.') from error
    asset=next((item for item in release.get('assets',[]) if item.get('name','').endswith('linux-'+platform.machine()+'.tar.gz')),None)
    available=asset is not None and version(release.get('tag_name',''))>version(current)
    return dict(available=available,version=release.get('tag_name',''),asset=asset if available else None,message='An update is available.' if available else 'No newer Linux build is available for this computer.')


def download(asset,cache,on_progress=None):
    url=asset.get('browser_download_url','');expected=asset.get('digest','')
    if not url.startswith(REPOSITORY+'/releases/download/') or not re.fullmatch(r'sha256:[0-9a-f]{64}',expected):raise ValueError('This release has no verified download from the Lens repository.')
    size=asset.get('size',0)
    if not isinstance(size,int) or not 0<size<=1024*1024*1024:raise ValueError('This release has an invalid download size.')
    cache=Path(cache).resolve();cache.mkdir(parents=True,exist_ok=True,mode=0o700)
    if shutil.disk_usage(cache).free<size*5:raise ValueError('There is not enough free space to download and install this release.')
    stage=Path(tempfile.mkdtemp(prefix='lens-update-',dir=cache))
    try:
        archive_path=stage/'release.tar.gz';value=hashlib.sha256();received=0
        with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Native-Browser-Lens'}),timeout=30) as response,archive_path.open('wb') as output:
            while chunk:=response.read(1024*1024):
                received+=len(chunk)
                if received>size:raise ValueError('The update exceeded its declared size.')
                output.write(chunk);value.update(chunk)
                if on_progress:on_progress(received,size)
        if received!=size or value.hexdigest()!=expected.removeprefix('sha256:'):raise ValueError('The downloaded release failed its checksum. The current app is unchanged.')
        extracted=stage/'files';extracted.mkdir(mode=0o700)
        with tarfile.open(archive_path,'r:gz') as archive:
            total=0;count=0
            for entry in archive:
                count+=1;total+=entry.size
                relative=PurePosixPath(entry.name)
                if count>10000 or total>2*1024*1024*1024 or relative.is_absolute() or '..' in relative.parts or '\\' in entry.name or not (entry.isdir() or entry.isfile()):raise ValueError('The release archive contains an unsafe or oversized entry.')
                destination=extracted/Path(*relative.parts)
                if entry.isdir():destination.mkdir(parents=True,exist_ok=True,mode=0o700)
                else:
                    destination.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
                    with archive.extractfile(entry) as source,destination.open('xb') as output:shutil.copyfileobj(source,output)
                    destination.chmod(0o755 if entry.mode&0o111 else 0o644)
        roots=list(extracted.iterdir())
        if len(roots)!=1 or not roots[0].is_dir():raise ValueError('The update has no single release folder.')
        verify(roots[0]);archive_path.unlink()
        return roots[0]
    except Exception:
        shutil.rmtree(stage);raise


def show(app):
    from gi.repository import Gtk,GLib
    existing=getattr(app,'updates_window',None)
    if existing:existing.present();return existing
    here=Path(__file__).resolve().parent
    manifest=here/'release.json'
    if not manifest.exists():manifest=here/'extension/manifest.json'
    if not manifest.exists():manifest=here.parent/'extension/public/manifest.json'
    current=json.loads(manifest.read_text())['version']
    window,content=app.review_window('App updates','Install a verified Linux release without rebuilding. Your notebook is preserved, and the previous app build remains available for rollback.')
    app.updates_window=window
    content.append(Gtk.Label(label='Installed version: '+current,xalign=0))
    status=Gtk.Label(label='Checking is optional. It contacts GitHub for release metadata.',xalign=0,wrap=True,selectable=True);content.append(status)
    state={'asset':None,'busy':False}
    def install(folder):
        verify(folder)
        subprocess.Popen([sys.executable,str(installer_path()),'--gui','--source',str(folder)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        window.close()
    def completed(result,error,kind):
        state['busy']=False;app.jobs-=1;check_button.set_sensitive(True);local.set_sensitive(True)
        if error:status.set_text(str(error))
        elif kind=='check':
            state['asset']=result.get('asset');status.set_text(result['message']+(' Version '+result['version'] if result.get('available') else ''))
        else:
            try:install(result)
            except (OSError,ValueError) as failure:status.set_text(str(failure))
        download_button.set_sensitive(state['asset'] is not None)
    def work(kind):
        state['busy']=True;app.jobs+=1
        for button in (check_button,download_button,local):button.set_sensitive(False)
        status.set_text('Checking GitHub releases…' if kind=='check' else 'Downloading and checking the release…')
        def run():
            result=error=None
            try:
                cache=Path(os.environ.get('XDG_CACHE_HOME') or Path.home()/'.cache')/'native-browser-lens'
                result=check(current) if kind=='check' else download(state['asset'],cache)
            except (OSError,ValueError,tarfile.TarError) as failure:error=failure
            GLib.idle_add(completed,result,error,kind)
        threading.Thread(target=run,daemon=True).start()
    check_button=app.button('Check for updates',lambda:work('check'));content.append(check_button)
    download_button=app.button('Download and review installation',lambda:work('download'));download_button.set_sensitive(False);content.append(download_button)
    def chosen(folder):
        try:install(folder)
        except (OSError,ValueError) as error:status.set_text(str(error))
    local=app.button('Install a downloaded release folder',lambda:app.choose_folder('Choose the extracted Lens release folder',chosen));content.append(local)
    content.append(Gtk.Label(label='The installer asks you to close active reviews and finish dictation before replacing the app. After updating, reload the Lens collector in Chrome Extensions.',xalign=0,wrap=True,css_classes=['dim-label']))
    def closed(*_):
        if state['busy']:status.set_text('The update check or download is running. Keep this window open until it finishes.');return True
        if getattr(app,'updates_window',None)==window:app.updates_window=None
        return False
    window.connect('close-request',closed)
    content.append(app.button('Close',window.close));window.present();return window
