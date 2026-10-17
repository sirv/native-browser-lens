import importlib.util
from pathlib import Path
import time
import unittest
import uuid
from gi.repository import Gio,GLib

spec=importlib.util.spec_from_file_location('lens_shortcuts',Path(__file__).parents[1]/'shortcuts.py')
shortcuts=importlib.util.module_from_spec(spec);spec.loader.exec_module(shortcuts)


class ShortcutTests(unittest.TestCase):
    def test_portal_registration_without_a_key_is_not_reported_as_a_working_keybinding(self):
        messages=[]
        capture=shortcuts.CaptureShortcut(lambda:None,messages.append)
        capture.bound({'shortcuts':[('capture',{'trigger_description':''})]},capture.generation)
        self.assertTrue(capture.registered)
        self.assertIsNone(capture.trigger)
        self.assertIn('did not assign a key',messages[-1])

    def test_dbus_session_binding_activation_scope_and_cleanup(self):
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        destination='studio.sirv.LensShortcutTest'+uuid.uuid4().hex
        bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',(destination,0)),None,Gio.DBusCallFlags.NONE,2000,None)
        session='/org/freedesktop/portal/desktop/session/fixture/capture'
        closed=[];requests=[]
        info=Gio.DBusNodeInfo.new_for_xml('''<node><interface name="org.freedesktop.portal.GlobalShortcuts"><method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method><method name="BindShortcuts"><arg type="o" direction="in"/><arg type="a(sa{sv})" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method></interface><interface name="org.freedesktop.portal.Session"><method name="Close"/></interface></node>''')
        def called(connection,sender,path,interface,method,parameters,invocation):
            if method=='Close':closed.append(True);invocation.return_value(None);return
            args=parameters.unpack();options=args[-1];token=options['handle_token']
            request='/org/freedesktop/portal/desktop/request/'+sender[1:].replace('.','_')+'/'+token
            requests.append(method)
            if method=='CreateSession':result={'session_handle':GLib.Variant('s',session)}
            else:
                self.assertEqual(args[0],session)
                self.assertEqual(args[1][0][0],'capture')
                result={'shortcuts':GLib.Variant('a(sa{sv})',[('capture',{'trigger_description':GLib.Variant('s','Ctrl+Alt+Shift+L')})])}
            invocation.return_value(GLib.Variant('(o)',(request,)))
            def reply():
                connection.emit_signal(sender,request,'org.freedesktop.portal.Request','Response',GLib.Variant('(ua{sv})',(0,result)));return False
            GLib.idle_add(reply)
        objects=[bus.register_object('/org/freedesktop/portal/desktop',info.interfaces[0],called,None,None),bus.register_object(session,info.interfaces[1],called,None,None)]
        activated=[];messages=[]
        capture=shortcuts.CaptureShortcut(lambda:activated.append(True),messages.append,destination)
        def wait(condition):
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
                if condition():return
                time.sleep(.01)
            self.fail(f'Shortcut fixture timed out: {requests}, {messages}')
        try:
            capture.start();wait(lambda:capture.trigger is not None)
            for owner in ('/org/freedesktop/portal/desktop/session/other/capture',session):
                bus.emit_signal(None,'/org/freedesktop/portal/desktop','org.freedesktop.portal.GlobalShortcuts','Activated',GLib.Variant('(osta{sv})',(owner,'capture',0,{})))
            wait(lambda:len(activated)==1)
            capture.stop();wait(lambda:closed)
            self.assertFalse(capture.subscriptions)
            self.assertIsNone(capture.session)
        finally:
            capture.stop()
            for obj in objects:bus.unregister_object(obj)
            bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReleaseName',GLib.Variant('(s)',(destination,)),None,Gio.DBusCallFlags.NONE,2000,None)
