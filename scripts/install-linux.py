#!/usr/bin/env python3
"""Install the Linux notebook and exact-extension native host for this user."""
import base64
import ctypes.util
import fcntl
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import argparse
import platform
import subprocess
import time

sys.path.insert(0,str(Path(__file__).resolve().parent if (Path(__file__).resolve().parent/'video_codecs.py').exists() else Path(__file__).resolve().parent.parent/'linux'))
import video_codecs

APP_FILES=('lens-host','lens-service','lens-evidence','reproduce.mjs','mcp_server.py','autofix.py','fix_verify.py','notebook.py','media.py','speech.py','tray.py','theme.py','shortcuts.py','maintenance.py','evidence.py','onboarding.py','updates.py','video_codecs.py','install.py','extension/manifest.json')


def file_hash(path):
    digest=hashlib.sha256()
    with path.open('rb') as source:
        while chunk:=source.read(1024*1024):digest.update(chunk)
    return digest.hexdigest()


def verify_bundle(source):
    source=Path(source).resolve()
    info=json.loads((source/'release.json').read_text())
    if info.get('formatVersion')!=1 or not isinstance(info.get('files'),dict):raise ValueError('Unsupported Lens release bundle.')
    if info.get('architecture')!=platform.machine():raise ValueError('This release is built for a different CPU architecture.')
    files={}
    for path in source.rglob('*'):
        if path.is_symlink():raise ValueError('Release bundles cannot contain symbolic links.')
        if path.is_file() and path.name!='release.json' and '__pycache__' not in path.parts and path.suffix!='.pyc':files[str(path.relative_to(source))]=file_hash(path)
    if files!=info['files']:raise ValueError('The release files do not match their checksums. Extract a fresh download before installing.')
    return info


def dependencies():
    probe='''import gi,cairo
gi.require_version("Gtk","4.0");gi.require_version("Gst","1.0");gi.require_version("Xdp","1.0");gi.require_version("Soup","3.0")
from gi.repository import Gtk,Gst,Xdp,Soup,cairo
assert Gtk.MediaFile.new().__gtype__.name!="GtkNoMediaFile", "GTK video backend is missing"
'''
    result=subprocess.run([sys.executable,'-c',probe],capture_output=True,text=True)
    missing=[] if result.returncode==0 else ['Python GTK 4 / video backend / Cairo / GStreamer / libportal / Soup bindings']
    if not ctypes.util.find_library('GLESv2'):missing.append('OpenGL ES 2 runtime')
    if not shutil.which('ffmpeg'):missing.append('FFmpeg')
    elif not video_codecs.encoder():missing.append('FFmpeg with libx264 or libopenh264')
    if not shutil.which('gst-inspect-1.0'):missing.append('GStreamer tools and plugins')
    else:
        for plugin in ('pipewiresrc','pulsesrc','jpegenc','appsink','videoconvert','videoscale','videorate'):
            if subprocess.run(['gst-inspect-1.0',plugin],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:missing.append('GStreamer '+plugin)
    if not video_codecs.decoder():missing.append('GStreamer H.264 decoder (avdec_h264 or openh264dec)')
    return missing


def dependency_command(family=None):
    family=family or ('arch' if shutil.which('pacman') else 'debian' if shutil.which('apt-get') else 'fedora' if shutil.which('dnf') else '')
    if family=='arch':return ['pacman','-S','--needed','python','python-gobject','python-cairo','gtk4','libglvnd','gstreamer','gst-plugins-base','gst-plugins-good','gst-libav','gst-plugin-pipewire','ffmpeg','libportal','libsoup3','libsecret','libayatana-appindicator']
    if family=='debian':return ['apt-get','install','-y','python3','python3-gi','python3-cairo','python3-gi-cairo','gir1.2-gtk-4.0','gir1.2-gst-plugins-base-1.0','gir1.2-soup-3.0','gir1.2-xdp-1.0','gir1.2-ayatanaappindicator3-0.1','gstreamer1.0-tools','gstreamer1.0-plugins-base','gstreamer1.0-plugins-good','gstreamer1.0-libav','gstreamer1.0-pipewire','libgtk-4-media-gstreamer','libgles2','ffmpeg','libsecret-tools','xdg-desktop-portal']
    if family=='fedora':return ['dnf','install','-y','python3-gobject','python3-cairo','gobject-introspection','gtk4','libglvnd-gles','gstreamer1-plugins-base','gstreamer1-plugins-good','gstreamer1-plugins-bad-free','gstreamer1-plugin-libav','gstreamer1-plugin-openh264','openh264','pipewire-gstreamer','libportal','libsoup3','libsecret','libayatana-appindicator-gtk3','ffmpeg-free','xdg-desktop-portal']
    return []


def bootstrap(source=None):
    source=Path(source).resolve() if source else Path(__file__).resolve().parent
    if (source/'release.json').exists():verify_bundle(source)
    if not dependencies():return
    command=dependency_command()
    if not command or not shutil.which('pkexec'):
        raise ValueError('Install the desktop components in a terminal, then run this installer again: sudo '+shlex.join(command))
    print('Installing required desktop components. Confirm in your desktop authorization dialog.',flush=True)
    if subprocess.run(['pkexec',*command]).returncode:
        raise ValueError('Desktop component installation was cancelled or failed. Your installed app has been preserved.')
    missing=dependencies()
    if missing:raise ValueError('Some desktop components are still missing: '+', '.join(missing))


def stop_running():
    try:
        from gi.repository import Gio,GLib
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        name='studio.sirv.NativeBrowserLens';path='/studio/sirv/NativeBrowserLens'
        def active():return bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',(name,)),None,Gio.DBusCallFlags.NONE,2000,None).unpack()[0]
        if not active():return
        for action in ('save','quit'):
            bus.call_sync(name,path,'org.gtk.Actions','Activate',GLib.Variant('(sava{sv})',(action,[],{})),None,Gio.DBusCallFlags.NONE,2000,None)
            time.sleep(.5)
        deadline=time.monotonic()+8
        while active() and time.monotonic()<deadline:time.sleep(.1)
        if active():raise ValueError('Lens is still working. Finish active operations and settle dictation, then retry. Your installed app has been preserved.')
    except ImportError:return
    except GLib.Error as error:
        if error.matches(Gio.dbus_error_quark(),Gio.DBusError.SERVICE_UNKNOWN):return
        raise ValueError('The desktop session could not be checked. Keep the current app installed and retry from your desktop.') from error


def write_private(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        shutil.copy2(path, path.with_name(path.name + '.backup-' + stamp))
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w') as output:
        os.chmod(temporary, mode)
        output.write(content)
    temporary.replace(path)


def main(source=None,launch=False,check=True):
    if sys.platform != 'linux':
        raise SystemExit('This installer requires Linux.')
    here=Path(__file__).resolve().parent
    source=Path(source).resolve() if source else here if (here/'lens-host').is_file() else here.parent/'dist/linux'
    if not all((source / name).is_file() for name in APP_FILES):
        raise SystemExit('Run npm --prefix extension ci and bash scripts/build-app.sh first.')
    if (source/'release.json').exists():verify_bundle(source)
    if check:
        missing=dependencies()
        if missing:raise ValueError('Missing desktop components: '+', '.join(missing)+'. Install them with: sudo '+shlex.join(dependency_command()))
    manifest = json.loads((source / 'extension/manifest.json').read_text())
    if not manifest.get('key'):
        raise SystemExit('The extension requires its stable manifest key.')
    digest = hashlib.sha256(base64.b64decode(manifest['key'], validate=True)).hexdigest()[:32]
    extension_id = ''.join(chr(ord('a') + int(n, 16)) for n in digest)
    home = Path.home()
    data = Path(os.environ.get('XDG_DATA_HOME') or home / '.local/share')
    config = Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
    if not data.is_absolute() or not config.is_absolute():
        raise SystemExit('XDG_DATA_HOME and XDG_CONFIG_HOME must be absolute paths.')
    root = data / 'native-browser-lens'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    installed = root / 'app'
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    staged = root / ('app-staging-' + stamp)
    launcher = home / '.local/bin/native-browser-lens'
    launcher_text='#!/bin/sh\ncase "${1-}" in\n evidence) shift; exec '+shlex.quote(str(installed/'lens-evidence'))+' "$@" ;;\n mcp) shift; exec '+shlex.quote(sys.executable)+' '+shlex.quote(str(installed/'mcp_server.py'))+' "$@" ;;\n fix) shift; exec '+shlex.quote(sys.executable)+' '+shlex.quote(str(installed/'autofix.py'))+' "$@" ;;\nesac\nexec '+shlex.quote(sys.executable)+' '+shlex.quote(str(installed/'notebook.py'))+' "$@"\n'
    host = {'name': 'studio.sirv.native_browser_lens', 'description': 'Private local evidence bridge for Native Browser Lens', 'path': str(installed / 'lens-host'), 'type': 'stdio', 'allowed_origins': ['chrome-extension://' + extension_id + '/']}
    executable = str(launcher).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
    desktop = '[Desktop Entry]\nType=Application\nName=Native Browser Lens\nComment=Capture browser defects in a private notebook\nExec="' + executable + '"\nIcon=camera-photo\nTerminal=false\nCategories=Development;\nStartupWMClass=studio.sirv.NativeBrowserLens\n'
    writes={launcher:(launcher_text,0o700),data/'applications/studio.sirv.NativeBrowserLens.desktop':(desktop,0o600)}
    icon=source/'extension/icons/lens.svg'
    if icon.is_file():
        desktop=desktop.replace('Icon=camera-photo','Icon=studio.sirv.NativeBrowserLens')
        writes[data/'applications/studio.sirv.NativeBrowserLens.desktop']=(desktop,0o600)
        writes[data/'icons/hicolor/scalable/apps/studio.sirv.NativeBrowserLens.svg']=(icon.read_text(),0o600)
    for browser in ('google-chrome','chromium'):writes[config/browser/'NativeMessagingHosts'/(host['name']+'.json')]=(json.dumps(host,indent=2)+'\n',0o600)
    firefox_manifest=source/'extension-firefox/manifest.json'
    if firefox_manifest.exists():
        identity=json.loads(firefox_manifest.read_text())['browser_specific_settings']['gecko']['id']
        if identity!='native-browser-lens@sirv.studio':raise ValueError('The Firefox collector identity does not match this installer.')
        firefox={key:value for key,value in host.items() if key!='allowed_origins'}
        firefox['allowed_extensions']=[identity]
        writes[home/'.mozilla/native-messaging-hosts'/(host['name']+'.json')]=(json.dumps(firefox,indent=2)+'\n',0o600)
    with (root/'.install.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise ValueError('Another Lens installer is running. Wait for it to finish, then retry.')
        fresh=not installed.exists()
        originals={path:(path.read_bytes(),path.stat().st_mode&0o777) if path.exists() else None for path in writes}
        previous=root/('app-backup-'+stamp)
        swapped=False
        try:
            shutil.copytree(source, staged,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
            if check:stop_running()
            if installed.exists():installed.rename(previous)
            try:staged.rename(installed)
            except OSError:
                if previous.exists():previous.rename(installed)
                raise
            swapped=True
            for path,(contents,mode) in writes.items():write_private(path,contents,mode)
        except Exception:
            if swapped:
                shutil.rmtree(installed)
                if previous.exists():previous.rename(installed)
                for path,original in originals.items():
                    if original is None:path.unlink(missing_ok=True)
                    else:
                        temporary=path.with_name(path.name+'.restore-'+stamp)
                        temporary.write_bytes(original[0]);temporary.chmod(original[1]);temporary.replace(path)
            raise
        finally:
            if staged.exists():shutil.rmtree(staged)
    print('Installed:', installed)
    print('Launch:', launcher)
    print('Chrome/Chromium extension ID:', extension_id)
    print('Load unpacked extension:', installed / 'extension')
    print('Add projects in Settings, then enable their origins in extension Options.')
    if launch:subprocess.Popen([str(launcher),*(['--setup'] if fresh else [])],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    return installed


def rollback(launch=False):
    data=Path(os.environ.get('XDG_DATA_HOME') or Path.home()/'.local/share')
    if not data.is_absolute():raise ValueError('XDG_DATA_HOME must be an absolute path.')
    root=data/'native-browser-lens';installed=root/'app'
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (root/'.install.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise ValueError('Another Lens installer is running. Wait for it to finish, then retry.')
        previous=sorted(root.glob('app-backup-*'),reverse=True)
        if not previous:raise ValueError('No previous Lens installation is available.')
        stop_running()
        if not installed.is_dir():raise ValueError('The current Lens installation is missing.')
        replaced=root/('app-rolled-back-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        installed.rename(replaced)
        try:previous[0].rename(installed)
        except OSError:replaced.rename(installed);raise
    if launch:subprocess.Popen([str(Path.home()/'.local/bin/native-browser-lens')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    return installed


def gui(source=None):
    import gi
    gi.require_version('Gtk','4.0')
    from gi.repository import Gtk,GLib
    import threading
    app=Gtk.Application(application_id='studio.sirv.NativeBrowserLens.Installer')
    def activate(application):
        appearance=None
        here=Path(__file__).resolve().parent
        if (here/'theme.py').exists():
            sys.path.insert(0,str(here))
            from theme import Appearance
            appearance=Appearance()
            application.connect('shutdown',lambda *_:appearance.close())
        window=Gtk.ApplicationWindow(application=application,title='Install Native Browser Lens',default_width=560,default_height=340)
        busy={'value':False}
        content=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=18)
        for edge in ('top','bottom','start','end'):getattr(content,'set_margin_'+edge)(24)
        content.append(Gtk.Label(label='Native Browser Lens',xalign=0,css_classes=['title-1']))
        status=Gtk.Label(label='Install for your account. Your notebook and previous build are preserved. Chrome setup opens after installation.',xalign=0,wrap=True,selectable=True);content.append(status)
        install=Gtk.Button(label='Install and open Lens',css_classes=['suggested-action']);content.append(install)
        missing=dependencies()
        if missing:
            status.set_text('Install the required desktop components first: '+', '.join(missing))
            packages=Gtk.Button(label='Install desktop components');content.append(packages);install.set_sensitive(False)
            def install_dependencies(*_):
                command=dependency_command()
                if not command or not shutil.which('pkexec'):status.set_text('Run in a terminal: sudo '+shlex.join(command));return
                packages.set_sensitive(False)
                busy['value']=True
                def work():
                    subprocess.run(['pkexec',*command],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    def done():
                        busy['value']=False
                        left=dependencies();packages.set_sensitive(bool(left));install.set_sensitive(not left)
                        status.set_text('Desktop components are ready.' if not left else 'Some components are still missing. Retry installation or use your package manager.')
                    GLib.idle_add(done)
                threading.Thread(target=work,daemon=True).start()
            packages.connect('clicked',install_dependencies)
        def clicked(*_):
            busy['value']=True
            install.set_sensitive(False);status.set_text('Installing Lens…')
            def work():
                try:
                    main(source,launch=True)
                    def done():busy['value']=False;window.close()
                    GLib.idle_add(done)
                except (OSError,ValueError,SystemExit) as error:
                    def failed(message=str(error)):busy['value']=False;status.set_text(message);install.set_sensitive(True)
                    GLib.idle_add(failed)
            threading.Thread(target=work,daemon=True).start()
        install.connect('clicked',clicked)
        def close(*_):
            if busy['value']:status.set_text('Installation is running. Keep this window open until it finishes.')
            return busy['value']
        window.connect('close-request',close)
        window.set_child(content);window.present()
    app.connect('activate',activate)
    return app.run([])


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description='Install or update Native Browser Lens without rebuilding it.')
    parser.add_argument('--source',type=Path);parser.add_argument('--launch',action='store_true');parser.add_argument('--gui',action='store_true');parser.add_argument('--rollback',action='store_true');parser.add_argument('--check',action='store_true');parser.add_argument('--bootstrap',action='store_true')
    args=parser.parse_args()
    try:
        if args.bootstrap:bootstrap(args.source)
        if args.gui:raise SystemExit(gui(args.source))
        if args.check:print(json.dumps({'missing':dependencies(),'installCommand':dependency_command()}))
        elif args.rollback:rollback(args.launch)
        else:main(args.source,args.launch)
    except (OSError,ValueError) as error:raise SystemExit(str(error))
