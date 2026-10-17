"""Live window-portal smoke; select the 'Lens capture test' window when prompted."""
from pathlib import Path
import sys
import time
import gi
gi.require_version('Gtk','4.0')
from gi.repository import Gio, GLib, Gtk
sys.path.insert(0,str(Path(__file__).parents[1]))
from media import DesktopCapture, save_png, Xdp
original_streams = Xdp.Session.get_streams
def inspected_streams(session):
    streams = original_streams(session)
    print('Portal stream metadata:', streams.unpack(), flush=True)
    return streams
Xdp.Session.get_streams = inspected_streams

app=Gtk.Application(application_id='studio.sirv.LensPortalTest')
capture=DesktopCapture(lambda message:print(message,flush=True))
tab=dict(clientId='fixture',projectId='fixture',windowId=1,tabId=1,documentId='fixture',title='Lens capture test',selected=True,selectionEpoch='portal-fixture')
started=time.monotonic()
passed=False

def active(*_):
    window=Gtk.ApplicationWindow(application=app,title='Lens capture test',default_width=640,default_height=360)
    label=Gtk.Label(label='Native Browser Lens\nWindow capture test\n\nOnly this synthetic window will be recorded.')
    window.set_child(label);window.present()
    GLib.timeout_add(700,lambda:capture.start(tab,False))
    GLib.timeout_add(100,check)

def check():
    global passed
    frames=capture.frames_at(tab,time.time())
    if frames:
        output=Path(__file__).resolve().parents[2]/'.build/linux-portal-window.png'
        save_png(frames[-1][2],output)
        print('Live portal and PipeWire PNG passed:',output,flush=True)
        passed=True;capture.stop();app.quit();return False
    if time.monotonic()-started>300:
        print('Portal smoke timed out without a shared window.',flush=True)
        capture.stop();app.quit();return False
    return True

app.connect('activate',active)
app.run([])
raise SystemExit(0 if passed else 1)
