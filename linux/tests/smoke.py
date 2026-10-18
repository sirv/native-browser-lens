import sys
"""Run with GDK_BACKEND=x11 xvfb-run -a python3 linux/tests/smoke.py."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import zipfile
from unittest.mock import patch

repo = Path(__file__).resolve().parents[2]
if 'LENS_SERVICE_PATH' not in os.environ:
    binary_dir=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=repo,text=True).strip())
    os.environ['LENS_SERVICE_PATH']=str(binary_dir/'lens-service')
runtime=Path(os.environ.get('LENS_APP_DIR',repo/'linux'))
sys.path.insert(0,str(runtime))
spec = importlib.util.spec_from_file_location('notebook',runtime/'notebook.py')
notebook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notebook)


def wait_for(condition, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        while notebook.GLib.MainContext.default().pending():
            notebook.GLib.MainContext.default().iteration(False)
        if condition():
            return
        time.sleep(.02)
    raise AssertionError(label)


def screenshot(name):
    deadline=time.monotonic()+.5
    while time.monotonic()<deadline:
        while notebook.GLib.MainContext.default().pending():notebook.GLib.MainContext.default().iteration(False)
        time.sleep(.01)
    subprocess.run(['import','-window','root',str(repo/'.build'/name)],check=True)


def assert_mask_visible(app,name):
    valid,bounds=app.canvas.compute_bounds(app.window)
    assert valid and app.image is not None
    iw,ih=app.image.get_width(),app.image.get_height()
    width,height=app.canvas.get_width(),app.canvas.get_height()
    scale=min(width/iw,height/ih)
    x=round(bounds.get_x()+(width-iw*scale)/2+iw*scale*.25)
    y=round(bounds.get_y()+(height-ih*scale)/2+ih*scale*.25)
    shot=notebook.cairo.ImageSurface.create_from_png(str(repo/'.build'/name))
    pixel=bytes(shot.get_data()[y*shot.get_stride()+x*4:y*shot.get_stride()+x*4+4])
    assert pixel==b'\0\0\0\xff',f'{name}: the captured image and its mask must remain visible after a theme change ({x},{y}: {pixel})'


with tempfile.TemporaryDirectory(prefix='lens-linux-ui-') as directory:
    os.environ['LENS_DATA_DIR'] = directory
    os.environ['XDG_CONFIG_HOME'] = str(Path(directory) / 'config')
    os.environ['XDG_CACHE_HOME'] = str(Path(directory) / 'cache')
    app = notebook.Notebook(desktop=False)
    app.set_flags(notebook.Gio.ApplicationFlags.NON_UNIQUE)
    app.register(None)
    app.activate()
    wait_for(lambda: app.jobs == 0, 'bootstrap')
    profile = {'id': str(uuid.uuid4()), 'name': 'Linux fixture', 'origins': ['http://localhost:3000'], 'repositoryPath': str(repo), 'documentationPaths': [], 'recording': 'diagnostics', 'enabled': True, 'adapter': 'sirv-studio', 'ownership': [{'pattern':'src/**','memberId':'fixture-member','label':'Fixture owner'}], 'logPaths': []}
    app.send('configure', projects=[profile])
    wait_for(lambda: app.jobs == 0, 'project configuration')
    app.new_note()
    wait_for(lambda: app.jobs == 0 and app.current(), 'new note')
    app.title_entry.set_text('Linux notebook smoke')
    app.editor.get_buffer().set_text('## Observed\n\nA note saved from the GTK editor.')
    app.save()
    wait_for(lambda: app.jobs == 0, 'save note')
    assert app.current()['markdown'].endswith('GTK editor.')
    assert not app.dirty
    database = Path(directory) / 'notebook.sqlite'
    backup = database.with_suffix('.backup')
    database.rename(backup); database.mkdir()
    app.editor.get_buffer().set_text('Unsaved text survives a storage failure.')
    app.save()
    wait_for(lambda: app.jobs == 0, 'failed save')
    assert app.dirty and app.selected_id in app.drafts
    assert notebook.text(app.editor) == 'Unsaved text survives a storage failure.'
    database.rmdir(); backup.rename(database)
    app.save()
    wait_for(lambda: app.jobs == 0, 'retry save')
    assert not app.dirty and not app.drafts
    assert app.current()['markdown'] == 'Unsaved text survives a storage failure.'
    app.editor.get_buffer().place_cursor(app.editor.get_buffer().get_iter_at_offset(3))
    app.send('sync')
    wait_for(lambda:app.jobs==0,'status-only sync preserves editor position')
    assert app.editor.get_buffer().props.cursor_position==3,'Background browser status must not reset the editor cursor.'
    history_row=app.history.get_first_child()
    history_row.grab_focus()
    app.send('edit',observationId=app.selected_id,title='Updated Linux notebook smoke')
    wait_for(lambda:app.jobs==0,'saved history update')
    assert app.window.get_focus() is history_row,'Updating a saved note must preserve keyboard focus in history.'
    assert history_row.get_child().get_first_child().get_text()=='Updated Linux notebook smoke'
    assert app.editor.get_buffer().props.cursor_position==3,'An unchanged report must preserve its editor cursor when its title changes.'
    app.new_note()
    wait_for(lambda:app.jobs==0,'history insertion')
    assert app.history.get_row_at_index(1) is history_row,'A new capture or note must retain existing history rows.'
    app.history.select_row(history_row)
    assert app.current()['title']=='Updated Linux notebook smoke'
    app.investigate()
    wait_for(lambda: app.jobs == 0, 'local investigation')
    assert app.current()['findings']
    assert app.selected_id in app.suggestions
    before=notebook.text(app.editor)
    app.apply_suggestion()
    wait_for(lambda:app.jobs==0,'apply suggested report')
    assert app.current()['markdown']!=before
    observation_id, capture_id, client_id = app.selected_id, str(uuid.uuid4()), str(uuid.uuid4())
    (Path(directory)/'bridge/clients'/client_id).mkdir(parents=True)
    identity = {'projectId': profile['id'], 'tabId': 1, 'windowId': 1, 'documentId': 'fixture', 'url': 'http://localhost:3000/page', 'title': 'Captured Linux page', 'capturedAt': time.time()*1000, 'clientId': client_id}
    tab = {**identity, 'mode': 'deep', 'armedAt': time.time()*1000, 'capabilities': [], 'active': True, 'selected': True}
    diagnostic_events=[
        dict(id=str(uuid.uuid4()),projectId=profile['id'],tabId=1,documentId='fixture',timestamp=identity['capturedAt']-40,kind='console',data={'type':'warn','args':[{'value':'Fixture warning'}]}),
        dict(id=str(uuid.uuid4()),projectId=profile['id'],tabId=1,documentId='fixture',timestamp=identity['capturedAt']-30,kind='request',data={'requestId':'fixture','url':'http://localhost:3000/api','method':'GET','monotonicTime':10}),
        dict(id=str(uuid.uuid4()),projectId=profile['id'],tabId=1,documentId='fixture',timestamp=identity['capturedAt']-20,kind='response',data={'requestId':'fixture','status':503}),
        dict(id=str(uuid.uuid4()),projectId=profile['id'],tabId=1,documentId='fixture',timestamp=identity['capturedAt']-10,kind='network-complete',data={'requestId':'fixture','monotonicTime':10.02}),
    ]
    png = Path(directory) / 'fixture.png'
    surface = notebook.cairo.ImageSurface(notebook.cairo.FORMAT_ARGB32, 600, 300)
    cr = notebook.cairo.Context(surface); cr.set_source_rgb(.95, .95, .96); cr.paint()
    cr.set_source_rgb(.18, .2, .3); cr.set_font_size(28); cr.move_to(40, 80); cr.show_text('Captured Linux page')
    surface.write_to_png(str(png))
    import base64
    envelopes = [
        ('capture-started', {'initiatedBy': 'extension', 'identity': identity, 'tab': tab}),
        ('capture', {'identity': identity, 'events': diagnostic_events, 'gaps': [], 'context': {}, 'screenshotBase64': base64.b64encode(png.read_bytes()).decode()}),
    ]
    inbox = Path(directory) / 'bridge/inbox'
    for index, (kind, payload) in enumerate(envelopes):
        payload.update(observationId=observation_id, captureId=capture_id, clientId=client_id)
        (inbox / f'{index}.json').write_text(json.dumps({'version': 1, 'kind': kind, 'id': str(uuid.uuid4()), 'payload': payload}))
    wait_for(lambda: app.current_capture() is not None and app.jobs == 0, 'filesystem notification and capture save')
    assert app.image is not None
    app.evidence_stack.set_visible_child_name('evidence')
    browser=app.evidence_browser
    browser.severity.set_selected(2)
    assert browser.list.get_first_child().evidence['kind']=='console'
    browser.query.set_text('not present')
    wait_for(lambda:browser.list.get_first_child() is None,'console search')
    browser.query.set_text('');browser.mode.set_selected(1)
    wait_for(lambda:browser.list.get_first_child() is not None,'network rows')
    row=browser.list.get_first_child();browser.list.select_row(row)
    assert abs(row.evidence['durationMs']-20)<.01
    assert '503' in notebook.text(browser.detail)
    screenshot('linux-network-waterfall.png')
    browser.mode.set_selected(3)
    wait_for(lambda:app.jobs==0 and browser.list.get_first_child() is not None,'linked failure timeline')
    failure_row=browser.list.get_first_child()
    while failure_row and not failure_row.evidence['failure']:failure_row=failure_row.get_next_sibling()
    assert failure_row and any(link['relationship']=='request' for link in failure_row.evidence['links'])
    browser.list.select_row(failure_row)
    assert 'linkedArtifacts' in notebook.text(browser.detail)
    screenshot('linux-failure-timeline.png')
    app.evidence_stack.set_visible_child_name('capture')
    app.annotate([{'id': str(uuid.uuid4()), 'kind': 'mask', 'points': [{'x': .1, 'y': .1}, {'x': .4, 'y': .4}], 'color': '#FF643C'}])
    wait_for(lambda: app.jobs == 0 and app.current_capture()['annotations'], 'burned-in mask')
    previews=[]
    app.send('cloudPreview',callback=previews.append,observationId=observation_id,reviewedVersion=app.current()['editVersion'],captureIds=[capture_id])
    wait_for(lambda:app.jobs==0 and previews,'masked cloud selection preview')
    assert 'selection' in previews[0],previews[0]
    assert 'originalScreenshotPath' not in json.dumps(previews[0])
    export = Path(directory) / 'exports'; export.mkdir()
    app.send('export', observationId=observation_id, destination=str(export))
    wait_for(lambda: app.jobs == 0, 'export')
    evidence = json.loads(next(export.glob('*/evidence.json')).read_text())
    assert evidence['captures'][0]['screenshotPath'].endswith('.png')
    assert 'originalScreenshotPath' not in evidence['captures'][0]
    subprocess.run(['import', '-window', 'root', str(repo / '.build/linux-notebook.png')], check=True)
    profile['recording'] = 'video'
    app.send('configure', projects=[profile])
    wait_for(lambda: app.jobs == 0, 'allow rolling video')
    app.clients[client_id] = [tab]
    app.tabs = [tab]
    app.media.start_source('videotestsrc is-live=true pattern=ball', tab, True, (320,240))
    wait_for(lambda: len(app.media.ring.frames) >= 5, 'native window frames')
    native_id = str(uuid.uuid4())
    native_identity = {**identity, 'capturedAt':time.time()*1000}
    envelopes = [
        ('capture-started', {'initiatedBy':'extension','identity':native_identity,'tab':tab}),
        ('capture', {'identity':native_identity,'events':[],'gaps':[],'context':{},'screenshotOmission':'Fixture browser screenshot unavailable'}),
    ]
    for index, (kind, payload) in enumerate(envelopes):
        payload.update(observationId=observation_id,captureId=native_id,clientId=client_id)
        (inbox/f'native-{index}.json').write_text(json.dumps({'version':1,'kind':kind,'id':str(uuid.uuid4()),'payload':payload}))
    wait_for(lambda: app.jobs == 0 and any(c['id'] == native_id and c['context'].get('videoPath') for c in app.current()['captures']), 'native fallback and saved rolling video')
    native_capture = next(c for c in app.current()['captures'] if c['id'] == native_id)
    assert native_capture['screenshotPath']
    assert native_capture['context']['coordinateSpace'] == 'native-window'
    assert native_capture['context']['videoReviewed'] is False
    exports = []
    app.send('export', callback=exports.append, observationId=observation_id,destination=str(export))
    wait_for(lambda: app.jobs == 0, 'unreviewed recording export')
    assert not list(Path(exports[-1]['exportPath']).glob('*.mp4'))
    app.send('nativeMedia', observationId=observation_id, captureId=native_id, identity={**native_identity,'documentId':'wrong'}, video=Path(native_capture['context']['videoPath']).name, videoSeconds=1)
    wait_for(lambda: app.jobs == 0, 'reject media from another document')
    assert 'different browser capture' in app.status.get_text()
    app.capture_picker.set_selected(1)
    app.review_video()
    review_window = next(w for w in app.get_windows() if w.get_title() == 'Review recording')
    widget=review_window.get_child().get_first_child()
    while widget and not isinstance(widget,notebook.Gtk.Video):widget=widget.get_next_sibling()
    assert widget is not None
    stream=widget.get_media_stream();stream.play()
    wait_for(lambda:stream.is_prepared() or stream.get_error() is not None,'saved recording playback preparation')
    assert stream.get_error() is None,stream.get_error()
    assert stream.has_video(),'The reviewed recording must contain a decodable video track'
    review_window.close()
    app.send('reviewVideo',observationId=observation_id,captureId=native_id,reviewed=True)
    wait_for(lambda:app.jobs == 0,'recording review')
    app.send('export',callback=exports.append,observationId=observation_id,destination=str(export))
    wait_for(lambda:app.jobs == 0,'reviewed recording export')
    assert list(Path(exports[-1]['exportPath']).glob('*.mp4'))
    app.media.stop();app.media_changed('Window sharing stopped.')
    protected_tab={**tab,'selectionEpoch':'before'}
    app.clients[client_id]=[protected_tab];app.tabs=[protected_tab]
    app.media.start_source('videotestsrc is-live=true pattern=ball',protected_tab,True,(320,240))
    wait_for(lambda:len(app.media.ring.frames)>=3,'video before queued selection change')
    app.executor.submit(lambda:time.sleep(.3))
    status={'version':1,'kind':'status','id':str(uuid.uuid4()),'payload':{'clientId':client_id,'selectionEpoch':'after-switch-away-and-back','tabs':[tab]}}
    (inbox/'status-after-switch.json').write_text(json.dumps(status))
    app.sync()
    wait_for(lambda:app.jobs==0 and app.media.tab is None,'coalesced selection change clears video after queued helper work')
    assert app.media.ring.bytes==0 and not app.media.frames_at(native_identity,time.time())
    app.dictation_observation_id = observation_id
    app.new_note()
    wait_for(lambda:app.jobs == 0,'different observation during dictation')
    other_id = app.selected_id
    app.speech.partial = 'Retained interim text.'
    app.dictate()
    assert app.dictation_observation_id == observation_id, 'A rejected restart must retain the original dictation destination'
    app.insert_interim()
    wait_for(lambda:app.jobs == 0,'anchored interim transcript save')
    assert app.current()['markdown'] == ''
    assert next(o for o in app.state['observations'] if o['id'] == observation_id)['markdown'].endswith('Retained interim text.')
    app.append_transcript('Transcript returns to the original observation.')
    wait_for(lambda:app.jobs == 0,'anchored transcript save')
    assert app.current()['id'] == other_id and app.current()['markdown'] == ''
    assert next(o for o in app.state['observations'] if o['id'] == observation_id)['markdown'].endswith('original observation.')
    app.selected_id = observation_id; app.dirty=False;app.render()
    app.capture_picker.set_selected(0)
    screenshot('linux-tokyo-storm.png')
    assert_mask_visible(app,'linux-tokyo-storm.png')
    assert app.editor.get_height()>100 and app.canvas.get_height()>150
    app.send('settings',settings={'appearance':'light'})
    wait_for(lambda:app.jobs==0 and app.appearance.applied=='light','Tokyo Night Day')
    screenshot('linux-tokyo-day.png')
    assert_mask_visible(app,'linux-tokyo-day.png')
    app.send('settings',settings={'appearance':'dark'})
    wait_for(lambda:app.jobs==0 and app.appearance.applied=='dark','Tokyo Night Storm')
    screenshot('linux-tokyo-storm.png')
    app.window.set_default_size(1000,760)
    screenshot('linux-tokyo-compact.png')
    assert app.window.measure(notebook.Gtk.Orientation.HORIZONTAL,-1).minimum<=1000,'The native window minimum must fit the compact desktop layout'
    for widget in (app.project_picker,app.history.get_first_child().get_child().get_first_child(),app.tool):
        valid,bounds=widget.compute_bounds(app.window)
        assert valid and bounds.get_x()>=0,'Compact window controls must not be clipped off the left edge'
    assert app.editor.get_height()>100 and app.canvas.get_width()>200
    app.window.set_default_size(1280,850)
    app.history_search.set_text('not found in any note')
    wait_for(lambda:app.history.get_first_child() is None,'observation search')
    app.history_search.set_text('')
    wait_for(lambda:app.history.get_first_child() is not None,'clear search')
    with patch.object(notebook.onboarding,'available_browsers',return_value=[('Chromium','/not-launched'),('Firefox','/not-launched'),('Firefox (Flatpak)',['flatpak','run','org.mozilla.firefox'])]):app.browser_setup()
    setup=next(w for w in app.get_windows() if w.get_title()=='Connect your browser')
    def button_with_label(widget,label):
        if isinstance(widget,notebook.Gtk.Button) and widget.get_label()==label:return widget
        child=widget.get_first_child()
        while child:
            match=button_with_label(child,label)
            if match:return match
            child=child.get_next_sibling()
    button_with_label(setup,'Copy extension folder').emit('clicked')
    def descendants(widget):
        yield widget
        child=widget.get_first_child()
        while child:
            yield from descendants(child);child=child.get_next_sibling()
    for picker in [w for w in descendants(setup) if isinstance(w,notebook.Gtk.DropDown)]:
        model=picker.get_model()
        labels=[model.get_item(i).get_string() for i in range(model.get_n_items())]
        if 'Firefox' in labels:
            picker.set_selected(labels.index('Firefox'))
            button_with_label(setup,'Copy manifest path').emit('clicked')
            assert any(isinstance(w,notebook.Gtk.Label) and 'Mozilla signing' in (w.get_text() or '') for w in descendants(setup))
            picker.set_selected(labels.index('Firefox (Flatpak)'))
            button_with_label(setup,'Copy temporary add-on path').emit('clicked')
            with zipfile.ZipFile(Path(directory)/'cache/native-browser-lens/firefox-collector-unsigned.xpi') as archive:
                assert json.loads(archive.read('manifest.json'))['browser_specific_settings']['gecko']['id']=='native-browser-lens@sirv.studio'
                assert 'background.js' in archive.namelist()
            assert any(isinstance(w,notebook.Gtk.Label) and 'NativeMessagingProxy' in (w.get_text() or '') for w in descendants(setup))
            screenshot('linux-flatpak-setup.png')
            break
    setup.close()
    with __import__('unittest.mock',fromlist=['patch']).patch.object(notebook.updates,'check',return_value={'available':False,'message':'No public Linux release has been published yet.'}):
        update_window=notebook.updates.show(app)
        button_with_label(update_window,'Check for updates').emit('clicked')
        wait_for(lambda:app.jobs==0,'manual release check')
        assert not button_with_label(update_window,'Download and review installation').get_sensitive()
        update_window.close()
    app.settings()
    settings_window = next(window for window in app.get_windows() if window.get_title() == 'Lens Settings')
    def click_save(widget):
        if isinstance(widget, notebook.Gtk.Button) and widget.get_label() == 'Save settings':
            widget.emit('clicked')
            return True
        child = widget.get_first_child()
        while child:
            if click_save(child):
                return True
            child = child.get_next_sibling()
        return False
    assert click_save(settings_window)
    wait_for(lambda: app.jobs == 0, 'settings form save')
    assert settings_window not in app.get_windows(), app.status.get_text()
    assert app.state['projects'][0]['adapter']=='sirv-studio'
    assert app.state['projects'][0]['ownership']==profile['ownership']
    other_profile={**profile,'id':str(uuid.uuid4()),'name':'Other project','origins':['http://localhost:3001']}
    app.send('configure',projects=[profile,other_profile])
    wait_for(lambda:app.jobs==0,'second project')
    project_model=app.project_picker.get_model()
    app.render()
    assert app.project_picker.get_model() is project_model,'Unchanged pickers must not restart selection notifications'
    app.project_picker.set_selected(1)
    app.send('sync')
    wait_for(lambda:app.jobs==0,'empty project survives sync')
    assert app.current() is None and app.history.get_first_child() is None
    app.new_note();wait_for(lambda:app.jobs==0 and app.current(),'second project note')
    app.editor.get_buffer().set_text('Other project autosaved note')
    wait_for(lambda:app.jobs==0 and app.current()['markdown']=='Other project autosaved note','debounced autosave')
    app.project_picker.set_selected(0)
    assert app.current()['projectId']==profile['id']
    app.selected_id=observation_id;app.render()
    app.show_fix_review(app.selected_id)
    wait_for(lambda:app.jobs==0,'fix evidence preview')
    fix_window=next(window for window in app.get_windows() if window.get_title()=='Fix with Codex')
    assert button_with_label(fix_window,'Reproduce, fix and verify').get_sensitive()
    assert not button_with_label(fix_window,'Open fix files').get_sensitive()
    screenshot('linux-agent-fix-review.png')
    entries=[widget for widget in descendants(fix_window) if isinstance(widget,notebook.Gtk.Entry)]
    entries[0].set_text('200');entries[1].set_text('python3 app.py')
    with patch.object(app,'send') as start_fix:
        button_with_label(fix_window,'Reproduce, fix and verify').emit('clicked')
        assert not fix_window.get_modal(),'An active fix must allow main-notebook interaction.'
        assert start_fix.call_args.args[0]=='autofix'
        start_fix.call_args.kwargs['callback']({'error':'Stopped controlled UI check'})
    fix_window.close()
    app.agent_setup()
    agent_window=next(window for window in app.get_windows() if window.get_title()=='Agent / MCP setup')
    assert not button_with_label(agent_window,'Copy MCP configuration').get_sensitive()
    with patch.object(app,'choose_folder',side_effect=lambda title,callback:callback(str(export))):button_with_label(agent_window,'Choose reviewed exports folder').emit('clicked')
    assert button_with_label(agent_window,'Copy MCP configuration').get_sensitive()
    assert button_with_label(agent_window,'Copy Codex command').get_sensitive()
    screenshot('linux-agent-mcp-setup.png');agent_window.close()
    app.cloud_review()
    app.filing_review()
    wait_for(lambda: app.jobs == 0, 'review windows')
    assert len(app.get_windows()) >= 3
    for window in app.get_windows():
        if window is not app.window:window.destroy()
    app.change_lifecycle('archive')
    wait_for(lambda:app.jobs==0 and app.current() is None,'archive observation')
    app.history_scope.set_selected(1)
    wait_for(lambda:app.current() is not None,'archived history')
    archived_id=app.selected_id
    app.change_lifecycle('trash')
    wait_for(lambda:app.jobs==0 and app.current() is None,'move to Trash')
    app.history_scope.set_selected(2)
    assert app.current()['id']==archived_id
    app.change_lifecycle('restoreObservation')
    wait_for(lambda:app.jobs==0,'restore discarded observation')
    app.history_scope.set_selected(1)
    assert app.current()['id']==archived_id
    app.change_lifecycle('archive')
    wait_for(lambda:app.jobs==0,'unarchive')
    app.history_scope.set_selected(0)
    backups=[]
    app.send('backup',destination=str(Path(directory)/'backups'),callback=backups.append)
    wait_for(lambda:app.jobs==0,'private notebook backup')
    backup=backups[-1]['maintenance']['backupPath']
    app.send('edit',observationId=archived_id,markdown='Replace only after reviewed restore')
    wait_for(lambda:app.jobs==0,'change after backup')
    app.send('restoreBackup',source=backup)
    wait_for(lambda:app.jobs==0,'restore verified backup')
    assert next(item for item in app.state['observations'] if item['id']==archived_id)['markdown']!='Replace only after reviewed restore'
    app.storage_settings();wait_for(lambda:app.jobs==0,'storage management')
    storage=next(w for w in app.get_windows() if w.get_title()=='Storage and backups')
    storage.destroy()
    output = repo / '.build/linux-ui-smoke.png'
    subprocess.run(['import', '-window', 'root', str(output)], check=True)
    for window in app.get_windows():
        window.destroy()
    app.executor.shutdown(wait=True)
    print('Linux GTK smoke passed: notes, watched captures, masks, native fallback, rolling video, review-gated export, anchored dictation and settings.')
