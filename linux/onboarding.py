"""First-run browser setup; browser origin approval remains an explicit browser action."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import os
from urllib.parse import urlsplit
import uuid


def project_from_url(value,name=''):
    value=value.strip()
    if '://' not in value:value=('http://' if value.startswith(('localhost', '127.0.0.1','[::1]')) else 'https://')+value
    parsed=urlsplit(value)
    if parsed.scheme.lower() not in ('http','https') or not parsed.hostname or parsed.username is not None or parsed.password is not None:raise ValueError('Enter a project HTTP or HTTPS URL without a username or password.')
    host=parsed.hostname.encode('idna').decode().lower()
    host='['+host+']' if ':' in host else host
    port=parsed.port
    origin=parsed.scheme.lower()+'://'+host+(':'+str(port) if port and (parsed.scheme.lower(),port) not in (('http',80),('https',443)) else '')
    return dict(id=str(uuid.uuid4()),name=name.strip() or parsed.hostname,origins=[origin],repositoryPath='',documentationPaths=[],recording='diagnostics',enabled=True,adapter='generic',ownership=[],logPaths=[])


def extension_id(folder):
    manifest=json.loads((Path(folder)/'manifest.json').read_text())
    if 'browser_specific_settings' in manifest:return manifest['browser_specific_settings']['gecko']['id']
    public_key=manifest['key']
    digest=hashlib.sha256(base64.b64decode(public_key,validate=True)).hexdigest()[:32]
    return ''.join(chr(ord('a')+int(n,16)) for n in digest)


def collector_folder(family='chromium'):
    name='extension-firefox' if family=='firefox' else 'extension'
    folder=Path(__file__).with_name(name)
    return folder if folder.is_dir() else Path(__file__).resolve().parent.parent/('extension/dist-firefox' if family=='firefox' else 'extension/dist')


def codex_binary():
    candidates=[os.environ.get('LENS_CODEX_BINARY'),str(Path(__file__).with_name('codex')),shutil.which('codex'),str(Path.home()/'.local/bin/codex'),str(Path.home()/'.codex/packages/standalone/current/bin/codex')]
    return next((path for path in candidates if path and os.access(path,os.X_OK)),None)


def show(app):
    import gi
    gi.require_version('Gtk','4.0')
    gi.require_version('Gdk','4.0')
    from gi.repository import Gtk,Gdk
    existing=getattr(app,'setup_window',None)
    if existing:existing.present();return existing
    window,content=app.review_window('Connect your browser','Choose your project, load the collector once, then approve the project in its browser. Lens will show when capture is ready.')
    window.set_child(None);window.set_child(Gtk.ScrolledWindow(child=content))
    app.setup_window=window
    browsers=[(label,path) for label,names in [('Chrome',('google-chrome','google-chrome-stable')),('Chromium',('chromium','chromium-browser')),('Firefox',('firefox',))] if (path:=next((shutil.which(name) for name in names if shutil.which(name)),None))]
    picker=Gtk.DropDown.new_from_strings([label for label,_ in browsers] or ['Install Chrome, Chromium or Firefox first'])
    content.append(picker)
    def family():return 'firefox' if browsers and browsers[picker.get_selected()][0]=='Firefox' else 'chromium'
    def folder():return collector_folder(family())
    target={'id':None}
    index=app.project_picker.get_selected()
    if index<len(app.state['projects']):target['id']=app.state['projects'][index]['id']
    site=Gtk.Label(xalign=0,wrap=True);content.append(site)
    content.append(Gtk.Label(label='1. Choose a project',xalign=0,css_classes=['heading']))
    url=Gtk.Entry(placeholder_text='https://your-project.example',hexpand=True)
    name=Gtk.Entry(placeholder_text='Project name (optional)',hexpand=True)
    content.append(url);content.append(name)
    message=Gtk.Label(xalign=0,wrap=True,selectable=True)
    def configured(result):
        if 'error' in result:message.set_text(result['error'])
        else:message.set_text('Project saved. Approve its origin in the extension permissions.');update()
        add.set_sensitive(True)
    def add_project():
        try:profile=project_from_url(url.get_text(),name.get_text())
        except ValueError as error:message.set_text(str(error));return
        projects=list(app.state['projects'])
        old=next((p for p in projects if profile['origins'][0] in p['origins']),None)
        if old:
            profile={**old,'enabled':True};projects=[profile if p['id']==old['id'] else p for p in projects]
        else:projects.append(profile)
        target['id']=profile['id'];add.set_sensitive(False)
        app.send('configure',projects=projects,callback=configured)
    add=app.button('Use this project',add_project);content.append(add)
    content.append(Gtk.Label(label='2. Add the browser collector',xalign=0,css_classes=['heading']))
    instructions=Gtk.Label(xalign=0,wrap=True);content.append(instructions)
    content.append(Gtk.Label(label='Already installed? After an app update, use Reload on the Native Browser Lens extension card.',xalign=0,wrap=True,css_classes=['dim-label']))
    path=Gtk.Label(xalign=0,wrap=True,selectable=True,css_classes=['dim-label']);content.append(path)
    def copy_folder():
        source=folder()/'manifest.json' if family()=='firefox' else folder()
        Gdk.Display.get_default().get_clipboard().set(str(source));message.set_text('Collector path copied. Paste it in the browser’s load chooser.')
    def open_browser(page,copy=False):
        if not browsers:message.set_text('Install a supported native browser, then open this setup again.');return
        if copy:copy_folder()
        app.open_browser(browsers[picker.get_selected()][1],page)
    content.append(app.button('Open browser extensions',lambda:open_browser('about:debugging#/runtime/this-firefox' if family()=='firefox' else 'chrome://extensions',True)))
    copy=app.button('Copy extension folder',copy_folder);content.append(copy)
    content.append(Gtk.Label(label='3. Approve your project and test capture',xalign=0,css_classes=['heading']))
    def permissions_page():
        clients=[client for client in app.connected_clients if app.client_browsers.get(client,'chromium')==family()]
        selected=app.selected_tab() or {}
        client=selected.get('clientId') if selected.get('clientId') in clients else next((tab.get('clientId') for tab in app.tabs if tab['projectId']==target['id'] and tab.get('clientId') in clients),clients[0] if clients else None)
        version=json.loads((folder()/'manifest.json').read_text())['version']
        if client and (family()=='firefox' or app.client_versions.get(client)==version):app.send('openOptions',payload={'clientId':client})
        elif family()=='firefox':open_browser('about:addons')
        else:open_browser(f'chrome-extension://{extension_id(folder())}/options.html')
    permissions=app.button('Open project permissions',permissions_page);content.append(permissions)
    def project_page():
        project=next((p for p in app.state['projects'] if p['id']==target['id']),None)
        if project:open_browser(project['origins'][0])
    open_site=app.button('Open project site',project_page);content.append(open_site)
    state=Gtk.Label(xalign=0,wrap=True,selectable=True);content.append(state)
    def capture():
        match=next((i for i,tab in enumerate(app.tabs) if app.client_browsers.get(tab.get('clientId'),'chromium')==family() and tab['projectId']==target['id'] and tab['mode'] in ('deep','devtools','limited')),None)
        if match is not None:app.tab_picker.set_selected(match);app.capture()
    test=app.button('Capture this project tab',capture);test.add_css_class('suggested-action');content.append(test)
    resume=app.button('Resume collection',app.pause);content.append(resume)
    def update():
        project=next((p for p in app.state['projects'] if p['id']==target['id']),None)
        site.set_text('Current project: '+project['name']+' · '+', '.join(project['origins']) if project else 'Add a project URL to begin.')
        ready=[tab for tab in app.tabs if app.client_browsers.get(tab.get('clientId'),'chromium')==family() and tab['projectId']==target['id'] and tab['mode'] in ('deep','devtools','limited')]
        clients=[client for client in app.connected_clients if app.client_browsers.get(client,'chromium')==family()]
        connected=bool(clients)
        version=json.loads((folder()/'manifest.json').read_text())['version']
        stale=connected and any(app.client_versions.get(client)!=version for client in clients)
        path.set_text(str(folder()/'manifest.json' if family()=='firefox' else folder()))
        copy.set_label('Copy manifest path' if family()=='firefox' else 'Copy extension folder')
        instructions.set_text('In This Firefox, choose Load Temporary Add-on and select the copied manifest.json path. This unsigned collector lasts until Firefox restarts. Permanent installation needs Mozilla signing; signing checks stay enabled. Use the collector button or Alt+Shift+L for screenshots; native-app capture may need approved window sharing.' if family()=='firefox' else 'Open Extensions, turn on Developer mode, then click Load unpacked. Paste the copied folder path in the folder chooser.')
        state.set_text('Collection is paused. Resume to detect project tabs and capture.' if app.paused else 'Collector connected. Reload its extension card to use the latest app features.' if stale else f"Collector connected · {len(ready)} ready project tab(s)." if ready else 'Collector connected. Approve the project origin and open its site.' if connected else 'Waiting for the selected browser. Load the collector in the profile you use.')
        resume.set_visible(app.paused)
        permissions.set_sensitive(connected and project is not None);open_site.set_sensitive(project is not None);test.set_sensitive(bool(ready) and not app.paused)
    def closed(*_):
        if getattr(app,'setup_window',None)==window:app.setup_window=None;app.setup_update=None
        return False
    window.connect('close-request',closed)
    window.connect('destroy',closed)
    picker.connect('notify::selected',lambda *_:update())
    app.setup_update=update;update()
    content.append(message);content.append(app.button('Refresh connection',lambda:app.send('bootstrap')));content.append(app.button('Done',window.close))
    window.present();return window
