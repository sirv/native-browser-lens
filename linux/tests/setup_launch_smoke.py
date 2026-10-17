"""Run on a private D-Bus and Xvfb to verify the packaged first-run command."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from gi.repository import Gio,GLib

parser=argparse.ArgumentParser();parser.add_argument('bundle',type=Path);args=parser.parse_args()
bundle=args.bundle.resolve()
bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
name='studio.sirv.NativeBrowserLens';path='/studio/sirv/NativeBrowserLens'
def owner():return bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',(name,)),None,Gio.DBusCallFlags.NONE,2000,None).unpack()[0]
assert not owner(),'Use dbus-run-session for this fixture.'
with tempfile.TemporaryDirectory(prefix='lens-first-run-') as directory:
    environment={**os.environ,'LENS_DATA_DIR':directory,'XDG_CONFIG_HOME':directory+'/config','GTK_THEME':'Adwaita','GTK_A11Y':'none','GSK_RENDERER':'cairo'}
    process=subprocess.Popen(['python3',str(bundle/'notebook.py'),'--setup'],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+12
        while not owner() and time.monotonic()<deadline:
            assert process.poll() is None,'The packaged setup command exited before registering.'
            time.sleep(.1)
        assert owner()
        time.sleep(1)
        reply=bus.call_sync(name,path,'org.gtk.Actions','Describe',GLib.Variant('(s)',('connection-status',)),None,Gio.DBusCallFlags.NONE,2000,None).unpack()[0]
        assert json.loads(reply[2][0])=={'connectedProfiles':0,'tabs':[]}
        second=subprocess.run(['python3',str(bundle/'notebook.py'),'--setup'],env=environment,capture_output=True,text=True,timeout=8)
        assert second.returncode==0,second.stderr
        assert process.poll() is None
        bus.call_sync(name,path,'org.gtk.Actions','Activate',GLib.Variant('(sava{sv})',('quit',[],{})),None,Gio.DBusCallFlags.NONE,2000,None)
        time.sleep(.3)
        assert owner(),'The installer must not discard an open setup or settings dialog.'
        output=Path(__file__).resolve().parents[2]/'.build/delivery-first-run.png'
        subprocess.run(['import','-window','root',str(output)],check=True)
    finally:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        errors=process.stderr.read().decode(errors='replace')
        assert 'Traceback' not in errors,errors
print('Packaged first-run passed: --setup, existing-instance activation, empty connection state and safe quit with a modal dialog.')
