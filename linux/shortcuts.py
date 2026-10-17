"""Global capture through the desktop portal, with session-scoped ownership."""
import uuid
from gi.repository import Gio, GLib


class CaptureShortcut:
    def __init__(self,on_capture,on_changed,destination='org.freedesktop.portal.Desktop'):
        self.on_capture,self.on_changed,self.destination=on_capture,on_changed,destination
        self.bus=None;self.session=None;self.generation=0;self.subscriptions=set();self.requests=set();self.trigger=None;self.registered=False

    def start(self):
        self.stop();generation=self.generation
        try:
            self.bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
            self.on_changed('Choose a desktop capture shortcut if the system prompts you.')
            self.request('CreateSession',lambda options:GLib.Variant('(a{sv})',({**options,'session_handle_token':GLib.Variant('s','lens_'+uuid.uuid4().hex)},)),lambda result:self.created(result,generation),generation)
        except GLib.Error:self.fail('The desktop shortcut portal is unavailable. Use the extension shortcut or Capture tab.',generation)

    def request(self,method,arguments,callback,generation):
        token='lens_'+uuid.uuid4().hex
        sender=self.bus.get_unique_name()[1:].replace('.','_')
        path='/org/freedesktop/portal/desktop/request/'+sender+'/'+token
        def response(connection,sender,path,interface,signal,parameters):
            connection.signal_unsubscribe(subscription);self.subscriptions.discard(subscription);self.requests.discard(path)
            if generation!=self.generation:return
            code,result=parameters.unpack()
            if code:self.fail('The desktop shortcut was not enabled. You can configure it again in Settings.',generation)
            else:callback(result)
        subscription=self.bus.signal_subscribe(self.destination,'org.freedesktop.portal.Request','Response',path,None,Gio.DBusSignalFlags.NONE,response)
        self.subscriptions.add(subscription);self.requests.add(path)
        def called(connection,result):
            try:connection.call_finish(result)
            except GLib.Error:
                if generation==self.generation:self.fail('The desktop shortcut portal could not complete this request. The browser shortcut remains available.',generation)
        self.bus.call(self.destination,'/org/freedesktop/portal/desktop','org.freedesktop.portal.GlobalShortcuts',method,arguments({'handle_token':GLib.Variant('s',token)}),None,Gio.DBusCallFlags.NONE,10000,None,called)

    def created(self,result,generation):
        self.session=result.get('session_handle')
        if not self.session or not self.session.startswith('/org/freedesktop/portal/desktop/session/'):
            self.fail('The desktop returned an invalid shortcut session.',generation);return
        for interface,signal,path,callback in [('org.freedesktop.portal.GlobalShortcuts','Activated','/org/freedesktop/portal/desktop',self.activated),('org.freedesktop.portal.Session','Closed',self.session,lambda *_:self.fail('Desktop capture shortcut disconnected. Enable it again in Settings.',generation))]:
            self.subscriptions.add(self.bus.signal_subscribe(self.destination,interface,signal,path,None,Gio.DBusSignalFlags.NONE,callback))
        shortcuts=[('capture',{'description':GLib.Variant('s','Capture the focused browser tab in Native Browser Lens'),'preferred_trigger':GLib.Variant('s','CTRL+ALT+SHIFT+l')})]
        self.request('BindShortcuts',lambda options:GLib.Variant('(oa(sa{sv})sa{sv})',(self.session,shortcuts,'',options)),lambda result:self.bound(result,generation),generation)

    def bound(self,result,generation):
        shortcuts=result.get('shortcuts',[])
        matched=next((properties for identifier,properties in shortcuts if identifier=='capture'),None)
        if matched is None:self.fail('No desktop capture shortcut was granted. Use the browser shortcut or configure it again.',generation);return
        self.registered=True;self.trigger=matched.get('trigger_description') or None
        self.on_changed(self.trigger+' is ready while the browser is focused.' if self.trigger else 'Capture action registered. This desktop did not assign a key; bind a shortcut to the command shown in Settings.')

    def activated(self,connection,sender,path,interface,signal,parameters):
        session,identifier,_,options=parameters.unpack()
        if session==self.session and identifier=='capture':self.on_capture()

    def fail(self,message,generation):
        if generation==self.generation:self.stop();self.on_changed(message)

    def stop(self):
        self.generation+=1
        if self.bus:
            for subscription in self.subscriptions:self.bus.signal_unsubscribe(subscription)
            for path in self.requests:self.bus.call(self.destination,path,'org.freedesktop.portal.Request','Close',None,None,Gio.DBusCallFlags.NONE,1000,None,None)
            if self.session:self.bus.call(self.destination,self.session,'org.freedesktop.portal.Session','Close',None,None,Gio.DBusCallFlags.NONE,1000,None,None)
        self.subscriptions.clear();self.requests.clear();self.session=None;self.trigger=None;self.registered=False
