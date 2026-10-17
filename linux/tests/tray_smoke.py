"""Live StatusNotifier/DBusMenu roundtrip against an isolated action owner."""
import json
from pathlib import Path
import subprocess
import sys
import time
import gi
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

def call(name, path, interface, method, args=None):
    return bus.call_sync(name, path, interface, method, args, None, Gio.DBusCallFlags.NONE, 2000, None).unpack()

def items():
    return call('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.freedesktop.DBus.Properties', 'Get', GLib.Variant('(ss)', ('org.kde.StatusNotifierWatcher', 'RegisteredStatusNotifierItems')))[0]

def wait(condition):
    deadline = time.monotonic()+10
    while time.monotonic() < deadline:
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        value = condition()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('Tray roundtrip timed out')

app = Gio.Application(application_id='studio.sirv.LensTrayTest')
activated = []
for name in ('show', 'capture', 'pause', 'settings', 'quit'):
    action = Gio.SimpleAction.new(name, None)
    action.connect('activate', lambda _, __, name=name: activated.append(name))
    app.add_action(action)
assert app.register(None)
before = set(items())
helper = subprocess.Popen([sys.executable, str(Path(__file__).parents[1]/'tray.py'), app.get_application_id()], stdin=subprocess.PIPE, text=True)
try:
    entry = wait(lambda: next(iter(set(items())-before), None))
    service, path = entry.split('/', 1); path = '/'+path
    properties = call(service, path, 'org.freedesktop.DBus.Properties', 'GetAll', GLib.Variant('(s)', ('org.kde.StatusNotifierItem',)))[0]
    assert properties['Title'] == 'Native Browser Lens'
    menu = properties['Menu']
    helper.stdin.write(json.dumps({'paused':True})+'\n'); helper.stdin.flush()
    def layout():
        return call(service, menu, 'com.canonical.dbusmenu', 'GetLayout', GLib.Variant('(iias)', (0,-1,[])))[1]
    wait(lambda: 'Lens: Paused' in str(layout()))
    helper.stdin.write(json.dumps({'connected':1,'tabs':1})+'\n');helper.stdin.flush()
    wait(lambda:'Lens: Ready' in str(layout()))
    root = layout()
    for child in root[2]:
        identifier, properties, children = child
        if properties.get('label') == 'Capture focused browser tab':
            call(service, menu, 'com.canonical.dbusmenu', 'Event', GLib.Variant('(isvu)', (identifier,'clicked',GLib.Variant('s',''),0)))
    wait(lambda: activated == ['capture'])
    helper.stdin.close()
    helper.wait(timeout=5)
    assert helper.returncode == 0
    print('Live tray passed: registration, state update, menu action and clean EOF shutdown.')
finally:
    if helper.poll() is None:
        helper.terminate(); helper.wait(timeout=5)
