#!/usr/bin/env python3
"""GTK notebook; the Swift helper owns storage, evidence and external requests."""
import copy
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import uuid
import time
import shutil
import threading
import tempfile
import re
import maintenance
import sqlite3
from evidence import EvidenceBrowser
import onboarding
import updates

from media import DesktopCapture, save_png, save_video, tab_key
from speech import SpeechCapture
from theme import Appearance
from shortcuts import CaptureShortcut

import cairo
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
from gi.repository import Gdk, Gio, GLib, Gtk, Pango


def image_point(x, y, width, height, image_width, image_height, clamp=False):
    scale = min(width / image_width, height / image_height)
    left, top = (width - image_width * scale) / 2, (height - image_height * scale) / 2
    px, py = (x - left) / (image_width * scale), (y - top) / (image_height * scale)
    if not clamp and not (0 <= px <= 1 and 0 <= py <= 1):
        return None
    return {'x': min(1, max(0, px)), 'y': min(1, max(0, py))}


def draw_annotations(context, width, height, annotations):
    for annotation in annotations:
        points = [(p['x'] * width, p['y'] * height) for p in annotation['points']]
        if len(points) < 2:
            continue
        context.new_path()
        context.set_line_width(max(2, min(width, height) / 250))
        context.set_source_rgb(.99, .32, .22)
        (x, y), (end_x, end_y) = points[0], points[-1]
        kind = annotation['kind']
        if kind in ('mask', 'rectangle'):
            if kind == 'mask':
                left, top = math.floor(min(x, end_x)), math.floor(min(y, end_y))
                context.rectangle(left, top, math.ceil(max(x, end_x))-left, math.ceil(max(y, end_y))-top)
                context.set_source_rgb(0, 0, 0)
                context.fill()
            else:
                context.rectangle(min(x, end_x), min(y, end_y), abs(end_x - x), abs(end_y - y))
                context.stroke()
        else:
            context.move_to(x, y)
            for px, py in points[1:]:
                context.line_to(px, py)
            context.stroke()
            if kind == 'arrow':
                angle = math.atan2(end_y - y, end_x - x)
                length = max(12, min(width, height) / 35)
                context.move_to(end_x - length * math.cos(angle - .5), end_y - length * math.sin(angle - .5))
                context.line_to(end_x, end_y)
                context.line_to(end_x - length * math.cos(angle + .5), end_y - length * math.sin(angle + .5))
                context.stroke()


def render_derivative(original, destination, annotations):
    image = cairo.ImageSurface.create_from_png(str(original))
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, image.get_width(), image.get_height())
    context = cairo.Context(surface)
    context.set_source_surface(image)
    context.paint()
    draw_annotations(context, image.get_width(), image.get_height(), annotations)
    temporary = Path(str(destination) + '.tmp')
    try:
        with temporary.open('xb') as output:
            os.chmod(temporary, 0o600)
            surface.write_to_png(output)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def box(vertical=True, spacing=10):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL if vertical else Gtk.Orientation.HORIZONTAL, spacing=spacing)


def margins(widget, amount=16):
    for edge in ('top', 'bottom', 'start', 'end'):
        getattr(widget, 'set_margin_' + edge)(amount)
    return widget


def text_view(editable=True):
    view = Gtk.TextView(editable=editable, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
    view.set_top_margin(12); view.set_bottom_margin(12)
    view.set_left_margin(14); view.set_right_margin(14)
    return view


def text(view):
    buffer = view.get_buffer()
    return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)


def scrolled(widget):
    return Gtk.ScrolledWindow(child=widget, hexpand=True, vexpand=True)


class Notebook(Gtk.Application):
    def __init__(self, desktop=True):
        super().__init__(application_id='studio.sirv.NativeBrowserLens',flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.add_main_option('setup',0,GLib.OptionFlags.NONE,GLib.OptionArg.NONE,'Connect Chrome and choose a project',None)
        self.initial_setup=False;self.setup_window=None;self.setup_update=None
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.service = Path(os.environ.get('LENS_SERVICE_PATH', Path(__file__).with_name('lens-service')))
        self.state = {'projects': [], 'observations': [], 'settings': {}}
        self.clients, self.tabs = {}, []
        self.selected_id = None
        self.dirty = False
        self.drafts = {}
        self.loading = False
        self.sync_scheduled = False
        self.jobs = 0
        self.monitor = None
        self.image = None
        self.image_path = None
        self.stroke = []
        self.paused = False
        self.annotating = False
        self.desktop = desktop
        self.media = DesktopCapture(self.media_changed)
        self.speech = SpeechCapture(self.speech_changed, self.append_transcript)
        self.dictation_observation_id = None
        self.native_snapshots = {}
        self.media_pending = set()
        self.tray_process = None
        self.last_tray_state = None
        self.appearance = None
        self.suggestions = {}
        self.progress_listeners = {}
        self.connected_clients = []
        self.client_versions={};self.client_browsers={}
        self.autosave_timer = None
        self.saving = set()
        self.save_callbacks = {}
        self.shortcuts=CaptureShortcut(lambda:self.capture(True),self.shortcut_changed)
        self.settings_loaded=False
        self.retention_timer=None
        self.shortcut_message='No desktop capture shortcut configured.'
        self.connect('activate', self.activate)
        self.connect('shutdown', self.shutdown)

    def button(self, label, callback):
        button = Gtk.Button(label=label)
        button.connect('clicked', lambda *_: callback())
        return button

    def do_command_line(self,command_line):
        self.activate()
        if command_line.get_options_dict().contains('setup'):
            if self.settings_loaded:self.browser_setup()
            else:self.initial_setup=True
        return 0

    def activate(self, *_):
        if hasattr(self, 'window'):
            self.window.present()
            return
        self.appearance = Appearance()
        self.window = Gtk.ApplicationWindow(application=self, title='Native Browser Lens', default_width=1280, default_height=850)
        self.window.connect('close-request', self.close)
        header = Gtk.HeaderBar()
        header.set_title_widget(Gtk.Label(label='Native Browser Lens', css_classes=['heading']))
        header.pack_start(self.button('New note', self.new_note))
        self.capture_button = self.button('Capture tab', self.capture)
        self.capture_button.add_css_class('suggested-action')
        header.pack_start(self.capture_button)
        header.pack_end(self.button('Settings', self.settings))
        notebook_menu=Gtk.MenuButton(label='Notebook')
        notebook_popover=Gtk.Popover();notebook_menu.set_popover(notebook_popover)
        notebook_actions=margins(box(spacing=6),10)
        for label,callback in [('Archive / unarchive',lambda:self.change_lifecycle('archive')),('Move to Trash',lambda:self.change_lifecycle('trash')),('Restore from Trash',lambda:self.change_lifecycle('restoreObservation')),('Storage and backups',self.storage_settings),('Import portable report',self.import_report),('App updates',lambda:updates.show(self))]:
            notebook_actions.append(self.button(label,lambda callback=callback:(notebook_popover.popdown(),callback())))
        notebook_popover.set_child(notebook_actions);header.pack_end(notebook_menu)
        self.pause_button = self.button('Pause', self.pause)
        header.pack_end(self.pause_button)
        self.window.set_titlebar(header)
        root = box()
        self.window.set_child(root)
        selectors = margins(box(False), 10)
        self.project_picker = Gtk.DropDown()
        self.project_picker.connect('notify::selected', self.project_changed)
        self.tab_picker = Gtk.DropDown(hexpand=True)
        self.tab_picker.connect('notify::selected', self.selected_tab_changed)
        selectors.append(Gtk.Label(label='Project'))
        selectors.append(self.project_picker)
        selectors.append(Gtk.Label(label='Browser tab'))
        selectors.append(self.tab_picker)
        selectors.append(self.button('Resume tab', self.resume_tab))
        selectors.append(self.button('Refresh', lambda: self.send('bootstrap')))
        root.append(selectors)
        selectors.add_css_class('toolbar')
        connection = margins(box(False), 10)
        connection.set_margin_top(0);connection.set_margin_bottom(0)
        self.connection_label = Gtk.Label(xalign=0, hexpand=True, wrap=True)
        connection.append(self.connection_label)
        connection.append(self.button('Browser setup', self.browser_setup))
        root.append(connection)
        panes = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, position=260, vexpand=True)
        panes.set_shrink_start_child(False);panes.set_shrink_end_child(False)
        root.append(panes)
        sidebar = margins(box(), 12)
        sidebar.add_css_class('sidebar')
        sidebar.set_size_request(210, -1)
        sidebar.append(Gtk.Label(label='Observations', xalign=0, css_classes=['heading']))
        self.history_search = Gtk.SearchEntry(placeholder_text='Find an observation')
        self.history_search.connect('search-changed',lambda *_: self.render())
        sidebar.append(self.history_search)
        self.history_scope=Gtk.DropDown.new_from_strings(['Active','Archived','Trash'])
        self.history_scope.connect('notify::selected',self.scope_changed)
        sidebar.append(self.history_scope)
        self.history = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.history.connect('row-selected', self.select_row)
        sidebar.append(scrolled(self.history))
        panes.set_start_child(sidebar)
        content = margins(box(), 12)
        panes.set_end_child(content)
        self.title_entry = Gtk.Entry(placeholder_text='Observation title')
        self.title_entry.add_css_class('title-2')
        self.title_entry.connect('changed', self.mark_dirty)
        content.append(self.title_entry)
        actions = box(False, 6)
        self.observation_buttons=[]
        for label, callback in [('Save note', self.save), ('Investigate locally', self.investigate), ('Review for AI', self.cloud_review), ('Export', self.export), ('Review for VibeQ', self.filing_review)]:
            button=self.button(label,callback);self.observation_buttons.append(button);actions.append(button)
        content.append(actions)
        native_controls = box(False, 6)
        self.share_button = self.button('Share window', self.share_window)
        self.video_button = self.button('Rolling video', lambda: self.share_window(True))
        self.dictate_button = self.button('Dictate', self.dictate)
        self.review_video_button=self.button('Review video',self.review_video)
        for button in [self.share_button, self.video_button, self.dictate_button, self.review_video_button]:
            native_controls.append(button)
        content.append(native_controls)
        self.speech_preview = Gtk.Label(xalign=0, wrap=True, selectable=True, lines=3, ellipsize=Pango.EllipsizeMode.END)
        self.speech_preview.set_visible(False)
        content.append(self.speech_preview)
        interim = box(False, 6)
        interim.append(self.button('Insert interim text', self.insert_interim))
        interim.append(self.button('Discard interim text', self.discard_interim))
        self.interim_controls = interim; interim.set_visible(False)
        content.append(interim)
        workspace_split = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, position=600, vexpand=True)
        workspace_split.set_shrink_start_child(False);workspace_split.set_shrink_end_child(False)
        content.append(workspace_split)
        evidence = box()
        self.capture_picker = Gtk.DropDown()
        self.capture_picker.connect('notify::selected', lambda *_: None if self.loading else self.render_capture())
        evidence.append(self.capture_picker)
        stack = Gtk.Stack(vexpand=True)
        self.evidence_stack = stack
        switcher = Gtk.StackSwitcher(stack=stack, halign=Gtk.Align.START)
        evidence.append(switcher); evidence.append(stack)
        image_box = box()
        tools = box(False, 6)
        self.tool = Gtk.DropDown.new_from_strings(['rectangle', 'arrow', 'pen', 'mask'])
        tools.append(Gtk.Label(label='Draw'))
        tools.append(self.tool)
        tools.append(self.button('Undo mark', self.undo_annotation))
        tools.append(Gtk.Label(label='Masks are burned into exports and AI images.', xalign=0, wrap=True))
        image_box.append(tools)
        self.canvas = Gtk.DrawingArea(hexpand=True, vexpand=True, content_width=300, content_height=230)
        self.canvas.set_draw_func(self.draw)
        self.canvas.update_property([Gtk.AccessibleProperty.LABEL], ['Captured screenshot; drag to annotate with the selected tool'])
        drag = Gtk.GestureDrag()
        drag.connect('drag-begin', self.drag_begin)
        drag.connect('drag-update', self.drag_update)
        drag.connect('drag-end', self.drag_end)
        self.canvas.add_controller(drag)
        overlay = Gtk.Overlay(child=self.canvas, hexpand=True, vexpand=True)
        overlay.add_css_class('canvas')
        self.empty_label = Gtk.Label(label='Capture a browser tab to start an observation.', wrap=True, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        overlay.add_overlay(self.empty_label)
        image_box.append(overlay)
        stack.add_titled(image_box, 'capture', 'Capture')
        self.evidence_text, self.findings_text = text_view(False), text_view(False)
        self.finding_links=box(spacing=8)
        findings_content=box(spacing=8);findings_content.append(self.finding_links);findings_content.append(self.findings_text)
        self.evidence_browser=EvidenceBrowser(self.evidence_text,lambda capture,callback:self.send('timeline',callback=callback,observationId=self.selected_id,captureId=capture))
        stack.add_titled(self.evidence_browser, 'evidence', 'Evidence')
        stack.add_titled(scrolled(findings_content), 'findings', 'Investigation')
        diagnostics=box(spacing=8)
        diagnostics.append(Gtk.Label(label='Import agent-browser / Playwright diagnostics. Raw files stay local until you review each attachment for export. Imported runs retain their tool provenance.',xalign=0,wrap=True))
        diagnostic_tools=box(False,6)
        self.diagnostic_type=Gtk.DropDown.new_from_strings(['HAR','Trace ZIP','CPU profile JSON','Runner result.json'])
        diagnostic_tools.append(self.diagnostic_type);diagnostic_tools.append(self.button('Import file',self.import_diagnostic))
        diagnostics.append(diagnostic_tools)
        diagnostics.append(self.button('Create reproduction handoff',self.reproduction_handoff))
        diagnostics.append(self.button('Compare before / after runs',self.verification_summary))
        self.diagnostic_list=box(spacing=6);diagnostics.append(self.diagnostic_list)
        self.verification_text=text_view(False);diagnostics.append(scrolled(self.verification_text))
        stack.add_titled(diagnostics,'diagnostics','Diagnostics')
        workspace_split.set_start_child(evidence)
        notes = box(spacing=6)
        notes.set_size_request(240,-1)
        notes.append(Gtk.Label(label='Markdown note', xalign=0, css_classes=['heading']))
        self.editor = text_view()
        self.editor.get_buffer().connect('changed', self.mark_dirty)
        notes.append(scrolled(self.editor))
        self.suggestion_box = box(spacing=6)
        self.suggestion_box.add_css_class('notice')
        self.suggestion_box.append(Gtk.Label(label='Suggested report',xalign=0,css_classes=['heading']))
        self.suggestion_text = text_view(False)
        suggestion_scroll = scrolled(self.suggestion_text); suggestion_scroll.set_max_content_height(160); suggestion_scroll.set_propagate_natural_height(True); suggestion_scroll.set_vexpand(False)
        self.suggestion_box.append(suggestion_scroll)
        suggestion_actions=box(False,6)
        suggestion_actions.append(self.button('Use this draft',self.apply_suggestion))
        suggestion_actions.append(self.button('Dismiss',self.dismiss_suggestion))
        self.suggestion_box.append(suggestion_actions)
        notes.append(self.suggestion_box)
        workspace_split.set_end_child(notes)
        footer = margins(box(False), 10)
        footer.add_css_class('statusbar')
        self.spinner = Gtk.Spinner()
        self.status = Gtk.Label(label='Add a project in Settings, then enable its origins in the browser extension.', xalign=0, hexpand=True, wrap=True, selectable=True)
        footer.append(self.spinner); footer.append(self.status)
        root.append(footer)
        for name, callback, keys in [('setup',self.browser_setup,[]),('save', self.save, ['<Control>s']), ('new', self.new_note, ['<Control>n']), ('show', self.activate, []), ('capture', lambda:self.capture(True), ['<Control><Alt><Shift>l']), ('pause', self.pause, []), ('dictate', self.dictate, ['<Control><Alt>d']), ('settings', self.settings, ['<Control>comma']), ('export',self.export,['<Control><Shift>e']), ('quit', self.quit_requested, ['<Control>q'])]:
            action = Gio.SimpleAction.new(name, None)
            action.connect('activate', lambda _, __, fn=callback: fn())
            self.add_action(action); self.set_accels_for_action('app.' + name, keys)
        self.add_action(Gio.SimpleAction.new_stateful('connection-status',None,GLib.Variant('s','{}')))
        self.window.present()
        self.send('bootstrap')
        if self.desktop:
            self.start_tray()

    def request(self, action, payload, progress=None):
        try:
            if action=='codexLogin':
                binary=onboarding.codex_binary()
                if not binary:return {'error':'Codex was not found. Install the Lens release bundle, which includes Codex.'}
                with tempfile.TemporaryFile() as output:
                    environment={key:value for key,value in os.environ.items() if key not in ('OPENAI_API_KEY','CODEX_API_KEY')}
                    result=subprocess.run([binary,'login'],stdout=output,stderr=output,timeout=180,env=environment)
                if result.returncode:return {'error':'Codex sign-in did not finish. Retry and complete the ChatGPT sign-in in your browser.'}
                return self.request('codexStatus',{})
            if action=='bootstrap':
                base=os.environ.get('XDG_DATA_HOME','')
                root=Path(os.environ.get('LENS_DATA_DIR') or (Path(base) if base.startswith('/') else Path.home()/'.local/share')/'native-browser-lens')
                if root.exists():maintenance.recover(root)
            if action in ('backup','inspectBackup','restoreBackup','storage','cleanupPlan','deleteTrash','retention'):
                root=Path(self.state['root'])
                if action=='backup':result={'backupPath':str(maintenance.create_backup(root,Path(payload['destination'])))}
                elif action=='inspectBackup':
                    info=maintenance.inspect_backup(Path(payload['source']));result={key:info[key] for key in ('observations','createdAt','originalRoot')}
                elif action=='restoreBackup':result=maintenance.restore_backup(root,Path(payload['source']),self.service)
                elif action=='storage':result=maintenance.storage_usage(root)
                elif action=='cleanupPlan':result=maintenance.cleanup_plan(root)
                elif action=='deleteTrash':result={'deleted':maintenance.delete_trashed(root,payload['versions'])}
                else:result=maintenance.apply_retention(root,int(self.state['settings'].get('trashRetentionDays','0')),int(self.state['settings'].get('trashMaxMiB','0')))
                response=self.request('bootstrap',{})
                response['maintenance']=result
                if action=='restoreBackup':response['selectedObservationId']=next((o['id'] for o in response.get('observations',[]) if not o.get('trashedAt') and not o.get('archivedAt')),None)
                return response
            response = None
            with tempfile.TemporaryFile() as errors, subprocess.Popen([str(self.service)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True) as process:
                timer=threading.Timer(600,process.kill); timer.daemon=True;timer.start()
                try:
                    process.stdin.write(json.dumps({'action':action,'stream':bool(progress),**payload}));process.stdin.close()
                    for line in process.stdout:
                        value=json.loads(line)
                        if 'progress' in value:
                            if progress:GLib.idle_add(progress,value['progress'])
                        else:response=value
                    process.wait()
                finally:timer.cancel()
            if response is None:
                return {'error':'The notebook helper stopped or timed out. Your saved evidence remains local.'}
            if process.returncode and 'error' not in response:
                return {'error': 'The notebook helper stopped. Retry the operation.'}
            return response
        except (OSError, subprocess.SubprocessError, ValueError, sqlite3.Error) as error:
            return {'error': str(error)}

    def send(self, action, callback=None, **payload):
        self.jobs += 1; self.spinner.start()
        def work():
            GLib.idle_add(self.completed, self.request(action, payload,lambda event:self.progress(action,payload,event)), callback)
        self.executor.submit(work)

    def completed(self, response, callback):
        self.jobs -= 1
        if not self.jobs:
            self.spinner.stop()
        if 'error' in response:
            self.status.set_text(response['error'])
            if callback:
                callback(response)
            return False
        content_changed='observations' in response or bool(response.get('observationUpdates')) or any(key in response and response[key]!=self.state.get(key) for key in ('projects','settings'))
        self.state.update({key: response[key] for key in ('projects', 'observations', 'settings', 'root') if key in response})
        if 'observationUpdates' in response:
            observations={item['id']:item for item in self.state['observations']}
            observations.update((item['id'],item) for item in response['observationUpdates'])
            self.state['observations']=sorted(observations.values(),key=lambda item:item['createdAt'],reverse=True)
        if 'connectedClientIDs' in response:
            self.connected_clients=response['connectedClientIDs']
            self.clients={key:value for key,value in self.clients.items() if key in self.connected_clients}
        self.appearance.set(self.state['settings'].get('appearance','dark'))
        if not self.settings_loaded and 'settings' in response:
            self.settings_loaded=True
            self.paused=self.state['settings'].get('capturePaused')=='true'
            self.pause_button.set_label('Resume' if self.paused else 'Pause')
            if self.desktop and self.state['settings'].get('shortcutEnabled')=='true':self.shortcuts.start()
            if not self.retention_timer:self.retention_timer=GLib.timeout_add_seconds(3600,self.run_retention)
            self.run_retention()
        for status in response.get('update', {}).get('statuses', []):
            self.clients[status.get('clientId', 'default')] = [{**tab,'selectionEpoch':status.get('selectionEpoch')} for tab in status.get('tabs', [])]
            self.client_versions[status.get('clientId','default')]=status.get('extensionVersion')
            self.client_browsers[status.get('clientId','default')]=status.get('browser','chromium')
        self.tabs = sorted([tab for tabs in self.clients.values() for tab in tabs], key=lambda tab: tab.get('title', ''))
        if 'suggestedDraft' in response:
            self.suggestions[response['investigationObservationId']]=response['suggestedDraft']
        self.media.validate(self.tabs)
        if self.media.tab and not any(p['id'] == self.media.tab['projectId'] and p['enabled'] and (not self.media.recording or p['recording'] == 'video') for p in self.state['projects']):
            self.media.stop(); self.media_changed('Window capture stopped because the project is disabled.')
        for start in response.get('update', {}).get('captureStarts', []):
            identity = start['identity']
            if start['captureId'] not in self.native_snapshots and abs(time.time()*1000-identity['capturedAt']) < 2000:
                frames = self.media.frames_at(identity, identity['capturedAt']/1000)
                if frames and identity['capturedAt']/1000-frames[-1][1] <= 2:
                    self.native_snapshots[start['captureId']] = frames[-1]
                    while len(self.native_snapshots) > 32:
                        del self.native_snapshots[next(iter(self.native_snapshots))]
        captured = response.get('update', {}).get('capturedObservationIDs', [])
        selected = response.get('selectedObservationId') or (captured[-1] if captured else self.selected_id)
        if selected is None and self.state['observations']:
            index=self.project_picker.get_selected()
            project_id=self.state['projects'][index]['id'] if index<len(self.state['projects']) else None
            selected=next((o['id'] for o in self.state['observations'] if self.in_scope(o) and (project_id is None or o['projectId']==project_id)),None)
        if selected != self.selected_id:
            content_changed=True
            self.save()
            self.selected_id = selected
            self.dirty = False
        self.render(content_changed)
        if self.desktop and (self.initial_setup or ('settings' in response and not self.state['projects'] and not getattr(self,'setup_shown',False))):
            self.initial_setup=False;self.setup_shown=True;self.browser_setup()
        if self.setup_update:self.setup_update()
        if captured and self.current():
            self.capture_picker.set_selected(len(self.current()['captures']) - 1)
        errors = response.get('update', {}).get('errors', [])
        if errors:
            self.status.set_text('\n'.join(errors))
        if captured:
            self.status.set_text('Capture saved. Review the image and coverage notes.')
            pending = False
            for observation in self.state['observations']:
                if observation['id'] in captured:
                    for capture in observation['captures']:
                        if capture['id'] in self.native_snapshots or self.media.recording:
                            pending = self.save_native_media(observation, capture) or pending
            if not pending:
                self.window.present()
        if not self.monitor and 'root' in self.state:
            directory = Path(self.state['root']) / 'bridge' / 'inbox'
            self.monitor = Gio.File.new_for_path(str(directory)).monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect('changed', lambda *_: self.schedule_sync())
        if callback:
            callback(response)
        return False

    def schedule_sync(self):
        if not self.sync_scheduled:
            self.sync_scheduled = True
            GLib.timeout_add(200, self.sync)

    def sync(self):
        self.sync_scheduled = False
        self.send('sync')
        return False

    def current(self):
        return next((o for o in self.state['observations'] if o['id'] == self.selected_id), None)

    def current_capture(self):
        captures = (self.current() or {}).get('captures', [])
        index = self.capture_picker.get_selected()
        return captures[index] if index < len(captures) else None

    def set_picker(self, picker, labels, identities):
        if not hasattr(picker,'lens_factory'):
            factory=Gtk.SignalListItemFactory()
            factory.connect('setup',lambda _,item:item.set_child(Gtk.Label(xalign=0,ellipsize=Pango.EllipsizeMode.END,max_width_chars=36)))
            def bind(_,item):
                label=item.get_child();value=item.get_item().get_string();label.set_text(value);label.set_tooltip_text(value)
            factory.connect('bind',bind);picker.set_factory(factory);picker.lens_factory=factory
            picker.set_enable_search(True)
        old = getattr(picker, 'identities', [])
        index = picker.get_selected()
        identity = old[index] if index < len(old) else None
        model=picker.get_model()
        if old==identities and model is not None and [model.get_string(i) for i in range(model.get_n_items())]==labels:
            return
        picker.set_model(Gtk.StringList.new(labels))
        picker.identities = identities
        picker.set_selected(identities.index(identity) if identity in identities else (0 if identities else Gtk.INVALID_LIST_POSITION))

    def render(self, content=True):
        self.loading = True
        if self.current() and not self.in_scope(self.current()):self.selected_id=None;self.dirty=False
        connection=self.lookup_action('connection-status')
        if connection:connection.set_state(GLib.Variant('s',json.dumps({'connectedProfiles':len(self.connected_clients),'tabs':[{key:tab.get(key) for key in ('tabId','clientId','projectId','mode','active','selected')} for tab in self.tabs]})))
        self.set_picker(self.project_picker, [p['name'] for p in self.state['projects']], [p['id'] for p in self.state['projects']])
        if self.current():
            ids=[p['id'] for p in self.state['projects']]
            if self.current()['projectId'] in ids:self.project_picker.set_selected(ids.index(self.current()['projectId']))
        old_tab=self.tab_picker.get_selected()
        had_tab=old_tab<len(getattr(self.tab_picker,'identities',[]))
        self.set_picker(self.tab_picker, [f"{t['title'] or t['url']} ({t['mode']})" for t in self.tabs], [f"{t.get('clientId')}:{t['tabId']}" for t in self.tabs])
        active=[index for index,tab in enumerate(self.tabs) if tab.get('active')]
        if not had_tab and len(active)==1:self.tab_picker.set_selected(active[0])
        if self.connected_clients:
            count=len(self.connected_clients);tabs=len(self.tabs)
            self.connection_label.set_text(f"{count} browser profile{'s' if count!=1 else ''} connected · {tabs} project tab{'s' if tabs!=1 else ''}." if self.tabs else 'Browser connected. Open an enabled project origin and grant its access in the extension Options.')
        else:
            self.connection_label.set_text('Browser collector is not connected. Load the extension to discover project tabs.')
        if not content:
            self.loading=False;self.update_controls();self.update_tray();return
        rows = {}
        child = self.history.get_first_child()
        while child:
            rows[child.observation_id] = child
            child = child.get_next_sibling()
        project_index=self.project_picker.get_selected()
        project_id=self.state['projects'][project_index]['id'] if project_index<len(self.state['projects']) else None
        query=self.history_search.get_text().casefold().strip()
        visible = [o for o in self.state['observations'] if self.in_scope(o) and (not project_id or o['projectId']==project_id) and (not query or query in (o['title']+'\n'+o['markdown']).casefold())]
        visible_ids = {o['id'] for o in visible}
        for identity, row in rows.items():
            if identity not in visible_ids:self.history.remove(row)
        selected_row = None
        for index, observation in enumerate(visible):
            row = rows.get(observation['id'])
            if row is None:
                row = Gtk.ListBoxRow()
                row.observation_id = observation['id']
                item = margins(box(spacing=4), 10)
                item.append(Gtk.Label(xalign=0, wrap=True))
                item.append(Gtk.Label(xalign=0, css_classes=['dim-label']))
                row.set_child(item)
            title = row.get_child().get_first_child()
            count = f"{len(observation['captures'])} capture{'s' if len(observation['captures']) != 1 else ''}"
            if title.get_text() != (observation['title'] or 'Untitled observation'):title.set_text(observation['title'] or 'Untitled observation')
            if title.get_next_sibling().get_text() != count:title.get_next_sibling().set_text(count)
            if self.history.get_row_at_index(index) is not row:
                if row.get_parent() is self.history:self.history.remove(row)
                self.history.insert(row,index)
            if row.observation_id == self.selected_id:selected_row = row
        if selected_row:
            self.history.select_row(selected_row)
        current = self.current()
        draft = self.drafts.get(self.selected_id)
        if not self.dirty:
            title = (draft or current or {}).get('title', '')
            markdown = (draft or current or {}).get('markdown', '')
            if self.title_entry.get_text() != title:self.title_entry.set_text(title)
            if text(self.editor) != markdown:self.editor.get_buffer().set_text(markdown)
        self.dirty = draft is not None
        suggestion=self.suggestions.get(self.selected_id)
        self.suggestion_box.set_visible(bool(suggestion))
        self.suggestion_text.get_buffer().set_text(suggestion or '')
        self.title_entry.set_sensitive(current is not None)
        self.editor.set_editable(current is not None)
        captures = (current or {}).get('captures', [])
        self.set_picker(self.capture_picker, [f"Capture {i+1}: {c['identity'].get('title') or c['identity']['url']}" for i, c in enumerate(captures)], [c['id'] for c in captures])
        self.findings_text.get_buffer().set_text('\n\n'.join(f"{f['kind']}: {f['text']}\n{f.get('source') or ''}" for f in (current or {}).get('findings', [])) or 'Run a local investigation to read captured errors and configured source files.')
        child=self.finding_links.get_first_child()
        while child:
            following=child.get_next_sibling();self.finding_links.remove(child);child=following
        for finding in (current or {}).get('findings',[]):
            source=finding.get('source')
            if source:
                button=self.button('Open '+source,lambda source=source:self.open_source(source))
                button.get_child().set_ellipsize(Pango.EllipsizeMode.END);button.get_child().set_max_width_chars(36)
                button.set_tooltip_text(source);self.finding_links.append(button)
        self.loading = False
        self.render_capture()
        self.update_controls()
        self.update_tray()

    def render_capture(self):
        capture = self.current_capture()
        path = (capture or {}).get('screenshotPath')
        if path != self.image_path:
            self.image = None; self.image_path = path
            if path:
                try:
                    self.image = cairo.ImageSurface.create_from_png(path)
                except (OSError, cairo.Error) as error:
                    self.status.set_text('Could not open the saved screenshot: ' + str(error))
        self.evidence_text.get_buffer().set_text(json.dumps(capture, indent=2) if capture else 'Capture a tab with the extension button or Alt+Shift+L. Browser permissions must be enabled for this project.')
        self.evidence_browser.set_capture(capture)
        child=self.diagnostic_list.get_first_child()
        while child:
            following=child.get_next_sibling();self.diagnostic_list.remove(child);child=following
        self.verification_text.get_buffer().set_text('Import before and after runner results, then compare the same condition and steps. Imported checks do not establish whole-app correctness.')
        for artifact in (capture or {}).get('context',{}).get('diagnosticArtifacts',[]):
            label=artifact.get('type','Diagnostic')+' · '+('reviewed for export' if artifact.get('reviewed') else 'local only')
            self.diagnostic_list.append(self.button(label,lambda artifact=copy.deepcopy(artifact):self.review_diagnostic(artifact)))
        self.empty_label.set_visible(self.image is None)
        self.empty_label.set_text(next((gap['reason'] for gap in (capture or {}).get('gaps', []) if gap['channel'] == 'screenshot'), 'Capture a browser tab to start an observation.'))
        self.canvas.queue_draw()
        self.review_video_button.set_sensitive(bool((capture or {}).get('context',{}).get('videoPath')))

    def select_row(self, _, row):
        if self.loading or not row or row.observation_id == self.selected_id:
            return
        self.save(); self.selected_id = row.observation_id; self.dirty = False; self.render()

    def mark_dirty(self, *_):
        if not self.loading and self.current():
            self.dirty = True
            self.drafts[self.selected_id] = {'title': self.title_entry.get_text(), 'markdown': text(self.editor)}
            if self.autosave_timer:GLib.source_remove(self.autosave_timer)
            def autosave():
                self.autosave_timer=None;self.save();return False
            self.autosave_timer=GLib.timeout_add(800,autosave)

    def save(self, observation_id=None, callback=None):
        observation_id = observation_id or self.selected_id
        if callback:self.save_callbacks.setdefault(observation_id,[]).append(callback)
        if observation_id in self.saving:return
        def notify(result):
            for fn in self.save_callbacks.pop(observation_id,[]):fn(result)
        if observation_id in self.drafts:
            draft = self.drafts[observation_id].copy()
            self.saving.add(observation_id)
            def saved(result):
                self.saving.discard(observation_id)
                if 'error' not in result and self.drafts.get(observation_id) == draft:
                    del self.drafts[observation_id]
                    if self.selected_id == observation_id:
                        self.dirty = False
                        self.render()
                if 'error' not in result and observation_id in self.drafts:
                    self.save(observation_id);return
                notify(result)
            self.send('edit', callback=saved, observationId=observation_id, **draft)
        else:notify({})

    def new_note(self):
        self.save()
        index = self.project_picker.get_selected()
        if index >= len(self.state['projects']):
            self.settings(); return
        self.send('new', projectId=self.state['projects'][index]['id'])

    def selected_tab(self):
        index = self.tab_picker.get_selected()
        if index >= len(self.tabs):
            self.status.set_text('No enabled browser tab. Enable project origins in the extension Options page.')
            return None
        return self.tabs[index]

    def capture(self, prefer_foreground=False):
        self.save()
        if self.paused:
            self.status.set_text('Resume collection before capturing.');return
        if prefer_foreground:
            active=[tab for tab in self.tabs if tab.get('active') and tab['mode'] in ('deep','devtools','limited')]
            if len(active)!=1:
                self.activate();self.status.set_text('Select the browser tab explicitly; its foreground window is not uniquely identified.');return
            tab=active[0]
        else:tab = self.selected_tab()
        if not tab:
            return
        payload = {key: tab[key] for key in ('tabId', 'clientId', 'projectId')}
        if self.current() and not self.current().get('trashedAt') and self.current()['projectId'] == tab['projectId']:
            payload['observationId'] = self.selected_id
        self.send('capture', payload=payload)
        self.status.set_text('Capture requested. Keep the browser tab open until its image arrives.')

    def resume_tab(self):
        tab = self.selected_tab()
        if tab:
            self.send('resumeTab', payload={key: tab[key] for key in ('tabId', 'clientId')})

    def pause(self):
        self.paused = not self.paused
        self.send('pause', payload={'paused': self.paused})
        self.send('settings', settings={'capturePaused':str(self.paused).lower()})
        self.pause_button.set_label('Resume' if self.paused else 'Pause')
        if self.paused:
            self.media.stop(); self.media_changed('Collection and native window capture are paused.')
        self.update_tray()

    def draw(self, _, context, width, height):
        if not self.image:
            return
        iw, ih = self.image.get_width(), self.image.get_height()
        scale = min(width / iw, height / ih)
        context.save()
        context.translate((width-iw*scale)/2, (height-ih*scale)/2)
        context.scale(scale, scale)
        context.set_source_surface(self.image); context.paint()
        if self.stroke:
            draw_annotations(context, iw, ih, [{'kind': self.tool.get_selected_item().get_string(), 'points': self.stroke}])
        context.restore()

    def drag_begin(self, _, x, y):
        self.stroke = []
        self.drag_start = x, y
        if self.image:
            point = image_point(x, y, self.canvas.get_width(), self.canvas.get_height(), self.image.get_width(), self.image.get_height())
            if point:
                self.stroke = [point]

    def drag_update(self, _, dx, dy):
        if not self.stroke or not self.image:
            return
        point = image_point(self.drag_start[0]+dx, self.drag_start[1]+dy, self.canvas.get_width(), self.canvas.get_height(), self.image.get_width(), self.image.get_height(), True)
        if self.tool.get_selected() == 2:
            if len(self.stroke) < 10_000:
                self.stroke.append(point)
        else:
            self.stroke = [self.stroke[0], point]
        self.canvas.queue_draw()

    def drag_end(self, gesture, dx, dy):
        self.drag_update(gesture, dx, dy)
        if len(self.stroke) >= 2 and self.current_capture():
            annotation = {'id': str(uuid.uuid4()), 'kind': self.tool.get_selected_item().get_string(), 'points': self.stroke, 'color': '#FF643C'}
            self.annotate(self.current_capture()['annotations'] + [annotation])
        self.stroke = []; self.canvas.queue_draw()

    def annotate(self, annotations):
        capture = self.current_capture()
        if not capture or self.annotating:
            return
        filename = capture['id'] + '-reviewed-' + str(uuid.uuid4()) + '.png'
        destination = Path(self.state['root']) / 'observations' / self.selected_id / filename
        try:
            render_derivative(capture.get('originalScreenshotPath') or capture['screenshotPath'], destination, annotations)
            self.annotating = True; self.canvas.set_sensitive(False)
            def saved(_):
                self.annotating = False; self.canvas.set_sensitive(True)
            self.send('annotate', callback=saved, observationId=self.selected_id, captureId=capture['id'], annotations=annotations, filename=filename)
        except (OSError, cairo.Error, KeyError) as error:
            self.status.set_text('Could not save annotation: ' + str(error))

    def undo_annotation(self):
        capture = self.current_capture()
        if capture and capture['annotations']:
            self.annotate(capture['annotations'][:-1])

    def investigate(self):
        self.save()
        if self.current():
            self.status.set_text('Investigating local evidence…')
            self.send('investigate', observationId=self.selected_id)

    def review_window(self, title, description):
        window = Gtk.Window(application=self, title=title, transient_for=self.window, modal=True, default_width=760, default_height=760)
        content = margins(box())
        content.append(Gtk.Label(label=description, xalign=0, wrap=True))
        window.set_child(content)
        return window, content

    def cloud_review(self):
        identity=self.selected_id
        self.save(callback=lambda result:self.show_cloud_review(identity) if 'error' not in result else None)

    def show_cloud_review(self,identity):
        if self.selected_id!=identity:return
        if not self.current():
            return
        snapshot = copy.deepcopy(self.current())
        snapshot['title'] = self.title_entry.get_text()
        snapshot['markdown'] = text(self.editor)
        window, content = self.review_window('Review evidence for Codex', 'Use your existing Codex subscription to analyze this notebook text, checked captures and bounded source references. Review masks before continuing. Video stays local; manual notes are preserved.')
        preview = text_view(False); preview.get_buffer().set_text(snapshot['title'] + '\n\n' + snapshot['markdown'])
        content.append(scrolled(preview))
        checks = []
        captures = box()
        for capture in snapshot['captures']:
            check = Gtk.CheckButton(label=capture['identity'].get('title') or capture['id'])
            captures.append(check); checks.append((check, capture['id']))
            if capture.get('screenshotPath'):
                picture = Gtk.Picture.new_for_filename(capture['screenshotPath'])
                picture.set_size_request(-1, 160)
                picture.set_can_shrink(True)
                captures.append(picture)
            captures.append(Gtk.Label(label=f"{len(capture['events'])} events, {len(capture['gaps'])} coverage notes", xalign=0))
        content.append(scrolled(captures))
        reviewed=Gtk.CheckButton(label='I reviewed the notebook and selected captures for private content')
        content.append(reviewed)
        def confirm():
            self.send('cloud', observationId=snapshot['id'], reviewedVersion=snapshot['editVersion'], reviewed=True, captureIds=[id for check, id in checks if check.get_active()])
            window.close()
        submit=self.button('Investigate with Codex', confirm);submit.add_css_class('suggested-action');submit.set_sensitive(False)
        selection_ready=[False]
        selection_preview=text_view(False)
        selection_expander=Gtk.Expander(label='Evidence selection and omissions');selection_expander.set_child(scrolled(selection_preview));content.append(selection_expander)
        def selection_changed(*_):
            selection_ready[0]=False;reviewed.set_active(False);submit.set_sensitive(False)
            selection_preview.get_buffer().set_text('Preview the selected evidence before sending. Failures and their request context are prioritized; omitted evidence stays local.')
        def preview_selection():
            ids=[id for check,id in checks if check.get_active()]
            def loaded(result):
                if ids!=[id for check,id in checks if check.get_active()]:return
                selection_ready[0]='selection' in result
                selection_preview.get_buffer().set_text(json.dumps(result.get('selection',result),indent=2,ensure_ascii=False));selection_expander.set_expanded(True)
                submit.set_sensitive(selection_ready[0] and reviewed.get_active())
            self.send('cloudPreview',callback=loaded,observationId=snapshot['id'],reviewedVersion=snapshot['editVersion'],captureIds=ids)
        reviewed.connect('toggled',lambda *_:submit.set_sensitive(reviewed.get_active() and selection_ready[0]))
        for check,_ in checks:check.connect('toggled',selection_changed)
        selection_changed()
        content.append(self.button('Preview evidence selection',preview_selection))
        content.append(submit)
        content.append(self.button('Cancel', window.close)); window.present()

    def export(self):
        self.save()
        if not self.current():
            return
        observation_id = self.selected_id
        chooser = Gtk.FileChooserNative(title='Export observation', transient_for=self.window, action=Gtk.FileChooserAction.SELECT_FOLDER, accept_label='Export', cancel_label='Cancel')
        def chosen(dialog, response):
            if response == Gtk.ResponseType.ACCEPT:
                self.send('export', callback=lambda result: self.status.set_text('Exported to ' + result['exportPath']) if 'exportPath' in result else None, observationId=observation_id, destination=dialog.get_file().get_path())
            dialog.destroy()
        chooser.connect('response', chosen); chooser.show()

    def import_diagnostic(self):
        capture=self.current_capture()
        if not capture:self.status.set_text('Select a saved capture before importing diagnostics.');return
        observation=self.selected_id;identity=capture['id'];kind=['har','trace','profile','verification'][self.diagnostic_type.get_selected()]
        chooser=Gtk.FileChooserNative(title='Import '+kind,transient_for=self.window,action=Gtk.FileChooserAction.OPEN,accept_label='Import locally',cancel_label='Cancel')
        def chosen(dialog,response):
            if response==Gtk.ResponseType.ACCEPT:
                self.send('importVerification' if kind=='verification' else 'importDiagnostic',observationId=observation,captureId=identity,source=dialog.get_file().get_path(),type=kind)
            dialog.destroy()
        chooser.connect('response',chosen);chooser.show()

    def review_diagnostic(self,artifact):
        item=self.current();capture=self.current_capture()
        if not item or not capture or not artifact.get('path'):return
        version=item['editVersion'];observation=item['id'];identity=capture['id']
        window,content=self.review_window('Review diagnostic attachment','This raw diagnostic may contain credentials, personal data, page content or source. Open it locally and inspect it before enabling export or VibeQ filing. It is excluded from Codex image/text requests. Masks on screenshots do not redact trace/HAR contents.')
        preview=text_view(False);preview.get_buffer().set_text(json.dumps(artifact,indent=2,ensure_ascii=False));content.append(scrolled(preview))
        content.append(self.button('Open local file',lambda:Gio.AppInfo.launch_default_for_uri(Path(artifact['path']).as_uri(),None)))
        reviewed=Gtk.CheckButton(label='I reviewed this raw file for export and filing');reviewed.set_active(artifact.get('reviewed',False));content.append(reviewed)
        def save_review():
            self.send('reviewDiagnostic',observationId=observation,captureId=identity,artifactId=artifact['id'],reviewedVersion=version,reviewed=reviewed.get_active());window.close()
        content.append(self.button('Save attachment review',save_review));content.append(self.button('Cancel',window.close));window.present()

    def verification_summary(self):
        capture=self.current_capture()
        if not capture:return
        identity=capture['id']
        def loaded(result):
            if (self.current_capture() or {}).get('id')==identity:self.verification_text.get_buffer().set_text(json.dumps(result,indent=2,ensure_ascii=False))
        self.send('verificationSummary',callback=loaded,observationId=self.selected_id,captureId=identity)

    def reproduction_handoff(self):
        item=self.current();capture=self.current_capture()
        if not item or not capture:return
        failures=[event for event in capture['events'] if isinstance(event.get('data',{}).get('status'),(int,float)) and event['data']['status']>=400]
        if not failures:self.status.set_text('Select a capture with an HTTP failure. Other failure conditions need a manually authored regression test.');return
        version=item['editVersion'];observation=item['id']
        window,content=self.review_window('Reproduce and verify','Select the failure and its expected success status. Lens exports an editable Playwright handoff. Review and fill the exact steps, reproduce the failure, fix the application, then run the same steps again. No browser action runs during export. Nearby clicks are suggestions only.')
        failure=Gtk.DropDown.new_from_strings([str(event['data']['status'])+' '+event['data'].get('url',event['id']) for event in failures]);content.append(failure)
        success=Gtk.Entry(placeholder_text='Expected HTTP status, for example 200');content.append(success)
        def choose():
            try:status=int(success.get_text())
            except ValueError:self.status.set_text('Enter the explicit expected HTTP success status (200–399).');return
            if not 200<=status<=399:self.status.set_text('Expected success status must be 200–399.');return
            event=failures[failure.get_selected()]['id']
            def chosen(folder):
                destination=str(Path(folder)/('lens-repro-'+uuid.uuid4().hex[:8]))
                self.send('handoff',callback=lambda result:self.status.set_text('Handoff saved: '+result['handoffPath']) if 'handoffPath' in result else None,observationId=observation,reviewedVersion=version,eventId=event,successStatus=status,destination=destination);window.close()
            self.choose_folder('Choose a parent folder for the reproduction handoff',chosen)
        content.append(self.button('Export reviewed handoff',choose));content.append(self.button('Cancel',window.close));window.present()

    def filing_review(self):
        self.save()
        if self.current():
            self.send('reviewFiling', callback=self.show_filing, observationId=self.selected_id)

    def show_filing(self, result):
        if 'review' not in result:
            return
        snapshot = result['review']
        window, content = self.review_window('Review VibeQ submission', 'Review this report and its attachments. Filing sends the frozen revision to your configured VibeQ endpoint. A saved uncertain submission is retried with its original identity.')
        preview = text_view(False)
        summary = snapshot['title'] + '\n\n' + snapshot['markdown'] + '\n\nAttachments:\n'
        summary += '\n'.join(c.get('screenshotPath') or 'No screenshot' for c in snapshot['captures'])
        summary += '\n\nEvidence and findings:\n' + json.dumps(snapshot, indent=2)
        preview.get_buffer().set_text(summary); content.append(scrolled(preview))
        frozen=result.get('frozen',False)
        ids=[''];names=['Leave unassigned']
        if result.get('assigneeId'):ids.append(result['assigneeId']);names.append('Saved owner: '+result['assigneeId'])
        assignee=Gtk.DropDown.new_from_strings(names);assignee.set_selected(len(ids)-1);assignee.set_sensitive(not frozen)
        owner_row=box(False,6);owner_row.append(Gtk.Label(label='Assign to'));owner_row.append(assignee)
        error_label=Gtk.Label(xalign=0,wrap=True);error_label.add_css_class('warning')
        def members_loaded(response):
            if 'error' in response:error_label.set_text(response['error']);return
            ids[:]=['']+[member['id'] for member in response.get('members',[])]
            assignee.set_model(Gtk.StringList.new(['Leave unassigned']+[member['name'] for member in response.get('members',[])]))
            proposed=response.get('suggestedAssigneeId','')
            assignee.set_selected(ids.index(proposed) if proposed in ids else 0)
        load_members=self.button('Load members and owner suggestion',lambda:self.send('members',observationId=snapshot['id'],callback=members_loaded))
        load_members.set_sensitive(not frozen);owner_row.append(load_members);content.append(owner_row)
        stages=[('prepare','Prepare reviewed revision'),('reconcile','Check existing submission'),('attachments','Upload reviewed evidence'),('submit','Record defect in VibeQ'),('receipt','Confirm durable receipt')]
        progress_box=box(spacing=10);labels={}
        for stage,title in stages:
            label=Gtk.Label(label='○ '+title,xalign=0,wrap=True);labels[stage]=(label,title);progress_box.append(label)
        disclosure=Gtk.Expander(label='Filing progress',expanded=True);disclosure.set_child(progress_box);content.append(disclosure)
        def progressed(event):
            if event.get('stage') not in labels:return
            label,title=labels[event['stage']]
            state=event.get('state','pending')
            label.set_text({'completed':'✓','failed':'×','active':'●'}.get(state,'○')+' '+title+'\n'+event.get('detail','')+(f" ({event['completed']}/{event['total']})" if event.get('total') else ''))
            for name in ('success','error','dim-label'):label.remove_css_class(name)
            label.add_css_class({'completed':'success','failed':'error'}.get(state,'dim-label'))
        self.progress_listeners[snapshot['id']]=progressed
        if frozen:
            progressed(dict(stage='prepare',state='completed',detail='Reviewed revision restored from local storage'))
            progressed(dict(stage='reconcile',state='failed',detail='Retry recovers this exact saved submission'))
        content.append(error_label)
        approved=Gtk.CheckButton(label='I reviewed the report, assignment, and attachments',active=frozen)
        content.append(approved)
        busy=False
        receipt_box=box(False,6);content.append(receipt_box)
        def show_receipt(receipt):
            missing=receipt.get('missingAttachments',[])
            error_label.set_text('Task saved; some attachments need recovery.' if missing else 'Task and attachments confirmed. Receipt saved locally.')
            receipt_box.append(self.button('Open in VibeQ',lambda:self.open_source(receipt['taskUrl'])))
        def filed(response):
            nonlocal busy,frozen
            busy=False
            if 'error' in response:
                error_label.set_text(response['error'])
                confirm.set_label('Retry saved submission')
            else:
                show_receipt(response['receipt'])
                confirm.set_label('Retry missing attachments')
                confirm.set_visible(bool(response['receipt'].get('missingAttachments')))
            frozen=True;assignee.set_sensitive(False);load_members.set_sensitive(False)
            confirm.set_sensitive(True)
        def file_reviewed():
            nonlocal busy
            if busy:return
            busy=True;confirm.set_sensitive(False);approved.set_sensitive(False);assignee.set_sensitive(False);load_members.set_sensitive(False)
            self.send('file',observationId=snapshot['id'],revision=snapshot['draftRevision'],reviewedVersion=snapshot['editVersion'],reviewed=True,assigneeId=ids[assignee.get_selected()],callback=filed)
        confirm=self.button('Retry saved submission' if frozen else 'File reviewed report', file_reviewed)
        confirm.add_css_class('suggested-action');confirm.set_sensitive(frozen or (approved.get_active() and bool(snapshot['markdown'].strip())))
        approved.connect('toggled',lambda *_:confirm.set_sensitive(not busy and approved.get_active() and bool(snapshot['markdown'].strip())))
        content.append(confirm)
        receipt=snapshot.get('receipt')
        if receipt and receipt['revision']==snapshot['draftRevision'] and not receipt.get('missingAttachments'):
            for stage,_ in stages:progressed(dict(stage=stage,state='completed',detail='Confirmed in the saved receipt'))
            show_receipt(receipt);confirm.set_visible(False);approved.set_visible(False);assignee.set_sensitive(False);load_members.set_sensitive(False)
        def close(*_):
            if busy:return True
            if self.progress_listeners.get(snapshot['id'])==progressed:self.progress_listeners.pop(snapshot['id'],None)
            return False
        window.connect('close-request',close)
        content.append(self.button('Cancel', window.close)); window.present()

    def settings(self):
        window, content = self.review_window('Lens Settings', 'Add project origins and grant their browser access. AI investigation uses your existing Codex sign-in and preserves manual notes.')
        window.set_child(None); window.set_child(scrolled(content))
        appearance_row=box(False)
        appearance_row.append(Gtk.Label(label='Appearance',width_chars=26,xalign=0))
        appearance=Gtk.DropDown.new_from_strings(['Tokyo Night Storm','Tokyo Night Day','Follow system'])
        modes=['dark','light','system']
        appearance.set_selected(modes.index(self.state['settings'].get('appearance','dark')))
        appearance.connect('notify::selected',lambda *_:self.send('settings',settings={'appearance':modes[appearance.get_selected()]}))
        appearance_row.append(appearance);content.append(appearance_row)
        content.append(Gtk.Label(label='Ctrl+Alt+Shift+L captures while Lens is focused. Use the desktop shortcut setup for capture from Chrome.',wrap=True,xalign=0,css_classes=['dim-label']))
        shortcut_row=box(False,6)
        shortcut_row.append(self.button('Set desktop capture shortcut',self.shortcuts.start))
        def disable_shortcut():
            self.shortcuts.stop();self.send('settings',settings={'shortcutEnabled':'false'});self.status.set_text('Portal shortcut disabled. Compositor bindings are managed separately in your desktop configuration.')
        shortcut_row.append(self.button('Disable portal shortcut',disable_shortcut));content.append(shortcut_row)
        self.shortcut_status=Gtk.Label(label=self.shortcut_message,xalign=0,wrap=True,selectable=True)
        content.append(self.shortcut_status)
        command='gapplication action studio.sirv.NativeBrowserLens capture'
        content.append(Gtk.Label(label='For desktops such as Hyprland that assign keys in their own settings, bind your preferred shortcut to:\n'+command,xalign=0,wrap=True,selectable=True,css_classes=['dim-label']))
        content.append(self.button('Copy desktop shortcut command',lambda:Gdk.Display.get_default().get_clipboard().set(command)))
        profiles = copy.deepcopy(self.state['projects'])
        picker = Gtk.DropDown.new_from_strings([p['name'] for p in profiles] + ['Add project…'])
        content.append(picker)
        project_fields = {}
        for label, key in [('Project name', 'name'), ('Exact origins (one per line)', 'origins'), ('Repository directory', 'repositoryPath'), ('Documentation paths (one per line)', 'documentationPaths'), ('Log paths (one per line)', 'logPaths')]:
            row = box(False)
            row.append(Gtk.Label(label=label, width_chars=26, xalign=0))
            entry = text_view() if key in ('origins', 'documentationPaths', 'logPaths') else Gtk.Entry(hexpand=True)
            project_fields[key] = entry
            if isinstance(entry, Gtk.TextView):
                scroll = scrolled(entry); scroll.set_min_content_height(48); scroll.set_vexpand(False)
                row.append(scroll)
            else:
                row.append(entry)
                if key=='repositoryPath':
                    def choose(entry=entry):
                        chooser=Gtk.FileChooserNative(title='Choose repository',transient_for=window,action=Gtk.FileChooserAction.SELECT_FOLDER,accept_label='Choose',cancel_label='Cancel')
                        def selected(dialog,response):
                            if response==Gtk.ResponseType.ACCEPT:entry.set_text(dialog.get_file().get_path())
                            dialog.destroy()
                        chooser.connect('response',selected);chooser.show()
                    row.append(self.button('Choose…',choose))
            content.append(row)
        enabled = Gtk.CheckButton(label='Enable capture for this project')
        content.append(enabled)
        video_enabled = Gtk.CheckButton(label='Allow a local 30-second video ring for this project')
        content.append(video_enabled)
        adapter=Gtk.DropDown.new_from_strings(['Generic adapter','Sirv Studio adapter'])
        content.append(adapter)
        ownership=box(spacing=6);ownership_rows=[]
        content.append(Gtk.Label(label='Ownership mappings',xalign=0,css_classes=['heading']))
        content.append(Gtk.Label(label='Match source globs to VibeQ member IDs. Suggestions are checked against the member list before filing.',xalign=0,wrap=True,css_classes=['dim-label']))
        content.append(ownership)
        def add_owner(rule=None):
            rule=rule or {};row=box(False,6);entries=[]
            for key,label in [('pattern','src/**'),('memberId','Member ID'),('label','Name')]:
                entry=Gtk.Entry(text=rule.get(key,''),placeholder_text=label,hexpand=True);row.append(entry);entries.append(entry)
            item=(row,entries);ownership_rows.append(item)
            def remove():ownership.remove(row);ownership_rows.remove(item)
            row.append(self.button('Remove',remove));ownership.append(row)
        content.append(self.button('Add ownership mapping',add_owner))
        def load_project(*_):
            index = picker.get_selected()
            profile = profiles[index] if index < len(profiles) else {'name': 'My project', 'origins': ['http://localhost:3000'], 'documentationPaths': ['docs']}
            for key, entry in project_fields.items():
                if isinstance(entry, Gtk.TextView):
                    entry.get_buffer().set_text('\n'.join(profile.get(key, [])))
                else:
                    entry.set_text(profile.get(key, ''))
            enabled.set_active(profile.get('enabled', False))
            video_enabled.set_active(profile.get('recording') == 'video')
            adapter.set_selected(1 if profile.get('adapter') in ('sirv','sirv-studio') else 0)
            for row,_ in ownership_rows:ownership.remove(row)
            ownership_rows.clear()
            for rule in profile.get('ownership',[]):add_owner(rule)
        picker.connect('notify::selected', load_project)
        load_project()
        fields = {}
        codex_status=Gtk.Label(label='Checking Codex sign-in…',xalign=0,wrap=True)
        content.append(codex_status)
        def checked(result):
            state=result.get('codexStatus')
            codex_status.set_text(result['error'] if 'error' in result else 'Codex subscription connected. No API key is needed.' if state=='ready' else 'Sign in to Codex with your ChatGPT account.' if state=='signIn' else 'Codex could not be found. Install the Lens release bundle, which includes Codex.')
            sign_in.set_sensitive(state!='ready')
        def login():
            sign_in.set_sensitive(False);codex_status.set_text('Continue the ChatGPT sign-in in your browser…')
            self.send('codexLogin',callback=checked)
        sign_in=self.button('Sign in with ChatGPT',login);content.append(sign_in)
        content.append(self.button('Check Codex connection',lambda:self.send('codexStatus',callback=checked)))
        self.send('codexStatus',callback=checked)
        for label, key in [('Codex model (blank = automatic)', 'codexModel'), ('VibeQ URL', 'vibeqURL')]:
            row = box(False); row.append(Gtk.Label(label=label, width_chars=20, xalign=0))
            entry = Gtk.Entry(text=self.state['settings'].get(key, ''), hexpand=True)
            row.append(entry); content.append(row); fields[key] = entry
        secrets = {}
        for label, key in [('VibeQ token', 'vibeq')]:
            row = box(False); row.append(Gtk.Label(label=label, width_chars=20, xalign=0))
            entry = Gtk.Entry(hexpand=True, visibility=False, input_purpose=Gtk.InputPurpose.PASSWORD)
            entry.set_placeholder_text('Leave blank to keep the saved credential')
            row.append(entry); content.append(row); secrets[key] = entry
            clear=Gtk.CheckButton(label='Remove saved '+label)
            clear.connect('toggled',lambda check,entry=entry:entry.set_sensitive(not check.get_active()))
            content.append(clear);secrets[key+'Clear']=clear
        error_label = Gtk.Label(xalign=0, wrap=True); content.append(error_label)
        def save_settings():
            index = picker.get_selected()
            projects = copy.deepcopy(profiles)
            profile = projects[index] if index < len(projects) else {'id': str(uuid.uuid4()), 'adapter': 'generic', 'ownership': []}
            for key, entry in project_fields.items():
                profile[key] = [line.strip() for line in text(entry).splitlines() if line.strip()] if isinstance(entry, Gtk.TextView) else entry.get_text().strip()
            profile.update(enabled=enabled.get_active(), recording='video' if video_enabled.get_active() else 'diagnostics')
            profile['origins']=[origin.rstrip('/') for origin in profile['origins']]
            profile['adapter']='sirv-studio' if adapter.get_selected()==1 else 'generic'
            profile['ownership']=[dict(zip(('pattern','memberId','label'),[entry.get_text().strip() for entry in entries])) for _,entries in ownership_rows]
            if any(not rule['pattern'] or not rule['memberId'] for rule in profile['ownership']):
                error_label.set_text('Each ownership mapping needs a source glob and member ID.');return
            if not profile['name'] or not profile['origins']:
                error_label.set_text('Enter a project name and at least one exact HTTP or HTTPS origin.'); return
            if index >= len(projects):
                projects.append(profile)
            def configured(result):
                if 'error' in result:
                    error_label.set_text(result['error']); return
                def saved(response):
                    if 'error' in response:
                        error_label.set_text(response['error'])
                    else:
                        window.close(); self.status.set_text('Settings saved. Enable the project origins in the browser extension.')
                credentials={key:('' if secrets[key+'Clear'].get_active() else secrets[key].get_text().strip()) for key in ('vibeq',) if secrets[key+'Clear'].get_active() or secrets[key].get_text().strip()}
                self.send('settings', callback=saved, settings={key: entry.get_text() for key, entry in fields.items()}, **credentials)
            self.send('configure', callback=configured, projects=projects)
        content.append(self.button('Save settings', save_settings))
        content.append(self.button('Cancel', window.close)); window.present()

    def media_changed(self, message):
        self.share_button.set_label('Stop sharing' if self.media.tab else 'Share window')
        self.video_button.set_label('Stop video' if self.media.recording else 'Rolling video')
        self.status.set_text(message)
        self.update_tray()

    def selected_tab_changed(self, *_):
        if not self.loading and self.media.tab:
            index = self.tab_picker.get_selected()
            if index >= len(self.tabs) or tab_key(self.tabs[index]) != tab_key(self.media.tab):
                self.media.stop(); self.media_changed('Window capture stopped because another tab was selected in Lens.')
        if not self.loading:self.update_controls()

    def update_controls(self):
        for button in self.observation_buttons:button.set_sensitive(self.current() is not None)
        index=self.tab_picker.get_selected();tab=self.tabs[index] if index<len(self.tabs) else None
        available=tab is not None and tab['mode'] in ('deep','devtools','limited') and not self.paused
        self.capture_button.set_sensitive(available)
        self.share_button.set_sensitive(available or self.media.tab is not None)
        self.video_button.set_sensitive(available or self.media.tab is not None)
        self.dictate_button.set_sensitive(self.current() is not None or self.speech.state!='idle')

    def share_window(self, recording=False):
        if self.media.tab or self.media.starting:
            self.media.stop(); self.media_changed('Window sharing and the video ring are off.'); return
        if self.paused:
            self.status.set_text('Resume collection before sharing a window.'); return
        tab = self.selected_tab()
        if not tab:
            return
        project = next((p for p in self.state['projects'] if p['id'] == tab['projectId'] and p['enabled']), None)
        if not project:
            self.status.set_text('Enable this project before sharing its window.'); return
        if recording and project['recording'] != 'video':
            self.status.set_text('Allow video for this project in Settings, then press Rolling video.'); return
        try:
            self.media.start(tab, recording)
        except (ValueError, GLib.Error) as error:
            self.media_changed(str(error))

    def save_native_media(self, observation, capture):
        identity, capture_id = capture['identity'], capture['id']
        frames = self.media.frames_at(identity, identity['capturedAt']/1000) if self.media.recording and not capture['context'].get('videoPath') else []
        image = self.native_snapshots.get(capture_id) if not capture.get('screenshotPath') else None
        if capture_id in self.media_pending or (not image and len(frames) < 2):
            return False
        self.media_pending.add(capture_id); self.jobs += 1; self.spinner.start()
        destination = Path(self.state['root']) / 'observations' / observation['id']
        def work():
            payload = {'observationId':observation['id'], 'captureId':capture_id, 'identity':identity}
            try:
                if image:
                    filename = capture_id+'-native-'+str(uuid.uuid4())+'.png'
                    width, height = save_png(image[2], destination/filename)
                    payload.update(screenshot=filename, nativeCapturedAt=image[1]*1000, pixelWidth=width, pixelHeight=height)
                if len(frames) >= 2:
                    filename = capture_id+'-video-'+str(uuid.uuid4())+'.mp4'
                    payload.update(video=filename, videoSeconds=save_video(frames, destination/filename))
                result = self.request('nativeMedia', payload)
            except (OSError, RuntimeError, ValueError, GLib.Error, subprocess.SubprocessError) as error:
                result = {'error':'Native media could not be saved: '+str(error)}
            GLib.idle_add(self.completed, result, saved)
        def saved(result):
            self.media_pending.discard(capture_id)
            if 'error' not in result:
                self.native_snapshots.pop(capture_id, None)
                self.status.set_text('Capture and native media saved. Review any recording before export or filing.')
            self.window.present()
        self.executor.submit(work)
        return True

    def review_video(self):
        capture = self.current_capture()
        path = (capture or {}).get('context', {}).get('videoPath')
        if not path:
            self.status.set_text('Start Rolling video, then capture the selected tab to save its recent recording.'); return
        observation_id, capture_id = self.selected_id, capture['id']
        window, content = self.review_window('Review recording', 'Watch the complete recording for private content. Mark it reviewed to include it in exports and VibeQ attachments. Recordings never enter AI investigation.')
        video = Gtk.Video.new_for_filename(path)
        video.set_hexpand(True); video.set_vexpand(True); content.append(video)
        review = Gtk.CheckButton(label='I reviewed this recording for export and filing', active=capture['context'].get('videoReviewed', False))
        content.append(review)
        def save_review():
            self.send('reviewVideo', observationId=observation_id, captureId=capture_id, reviewed=review.get_active())
            window.close()
        def stop_preview(*_):
            stream = video.get_media_stream()
            if stream:
                stream.pause()
                if isinstance(stream, Gtk.MediaFile):
                    stream.clear()
                video.set_media_stream(None)
            return False
        window.connect('close-request', stop_preview)
        content.append(self.button('Save review', save_review))
        content.append(self.button('Cancel', window.close)); window.present()

    def dictate(self):
        if self.speech.state == 'recording':
            self.speech.finish(); return
        if self.speech.state != 'idle':
            self.speech.cancel(); self.speech_changed('Dictation cancelled. Interim text is retained.'); return
        if self.speech.partial:
            self.speech_changed('Insert or discard the unfinished dictation before starting another session.'); return
        if not self.current():
            self.status.set_text('Create or select an observation before dictating.'); return
        self.dictation_observation_id = self.selected_id
        self.speech.start()

    def speech_changed(self, message):
        self.dictate_button.set_label('Finish dictation' if self.speech.state == 'recording' else ('Cancel dictation' if self.speech.state != 'idle' else 'Dictate'))
        self.speech_preview.set_text(self.speech.partial)
        self.speech_preview.set_visible(bool(self.speech.partial))
        self.interim_controls.set_visible(bool(self.speech.partial) and self.speech.state == 'idle')
        self.status.set_text(message); self.update_tray()

    def append_transcript(self, transcript):
        identity = self.dictation_observation_id
        observation = next((item for item in self.state['observations'] if item['id'] == identity), None)
        if not observation:
            self.speech.partial = transcript; self.speech_changed('The original observation is unavailable. The transcript is retained.'); return False
        draft = self.drafts.get(identity, {'title':observation['title'], 'markdown':observation['markdown']}).copy()
        draft['markdown'] += ('\n\n' if draft['markdown'] else '')+transcript
        self.drafts[identity] = draft
        if identity == self.selected_id:
            self.loading = True
            self.editor.get_buffer().set_text(draft['markdown'])
            self.loading = False; self.dirty = True
        self.save(identity)
        return True

    def insert_interim(self):
        if self.speech.state == 'idle' and self.speech.partial:
            if self.append_transcript('[Unfinished dictation]\n'+self.speech.partial):
                self.speech.partial = ''; self.speech_changed('Interim text added to its original observation.')

    def discard_interim(self):
        if self.speech.state == 'idle':
            self.speech.partial = ''; self.speech_changed('Interim text discarded.')

    def start_tray(self):
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            available = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NameHasOwner', GLib.Variant('(s)', ('org.kde.StatusNotifierWatcher',)), GLib.VariantType.new('(b)'), Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
            if not available:
                return
            self.tray_process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('tray.py')), self.get_application_id()], stdin=subprocess.PIPE, text=True)
            self.update_tray()
        except (OSError, GLib.Error):
            self.status.set_text('The desktop tray is unavailable. Keep the notebook open for capture controls.')

    def update_tray(self):
        state = {'paused':self.paused, 'recording':self.media.recording, 'dictating':self.speech.state != 'idle','connected':len(self.connected_clients),'tabs':len(self.tabs)}
        if self.tray_process and self.tray_process.poll() is None and state != self.last_tray_state:
            try:
                self.tray_process.stdin.write(json.dumps(state)+'\n'); self.tray_process.stdin.flush()
                self.last_tray_state = state
            except (BrokenPipeError, OSError):
                self.tray_process = None

    def quit_requested(self):
        if any(window is not self.window and window.get_modal() for window in self.get_windows()):
            self.status.set_text('Close settings and review windows before quitting or installing an update.');return
        if self.jobs or self.drafts or self.speech.state != 'idle' or self.speech.partial:
            self.window.present()
            self.status.set_text('Save edited notes and finish, insert or discard dictation before quitting.'); return
        self.quit()

    def shutdown(self, *_):
        if self.retention_timer:GLib.source_remove(self.retention_timer)
        if self.autosave_timer:GLib.source_remove(self.autosave_timer)
        if self.appearance:self.appearance.close()
        self.shortcuts.stop()
        self.media.stop(); self.speech.cancel()
        if self.tray_process and self.tray_process.stdin:
            try:
                self.tray_process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        self.executor.shutdown(wait=False)

    def project_changed(self,*_):
        if self.loading:return
        index=self.project_picker.get_selected()
        if index>=len(self.state['projects']):return
        identity=self.state['projects'][index]['id']
        if self.current() and self.current()['projectId']!=identity:
            self.save()
            self.selected_id=next((o['id'] for o in self.state['observations'] if o['projectId']==identity and self.in_scope(o)),None)
            self.dirty=False
        self.render()

    def in_scope(self,item):
        scope=self.history_scope.get_selected()
        return bool(item.get('trashedAt')) if scope==2 else not item.get('trashedAt') and bool(item.get('archivedAt'))==(scope==1)

    def scope_changed(self,*_):
        if self.loading:return
        self.save();self.selected_id=None;self.dirty=False;self.render()
        first=self.history.get_first_child()
        if first:self.history.select_row(first)

    def change_lifecycle(self,action):
        item=self.current()
        if not item:return
        identity=item['id']
        def saved(result):
            if 'error' not in result:self.send(action,observationId=identity)
        self.save(identity,callback=saved)

    def choose_folder(self,title,callback):
        chooser=Gtk.FileChooserNative(title=title,transient_for=self.window,action=Gtk.FileChooserAction.SELECT_FOLDER,accept_label='Choose',cancel_label='Cancel')
        def chosen(dialog,response):
            if response==Gtk.ResponseType.ACCEPT:callback(dialog.get_file().get_path())
            dialog.destroy()
        chooser.connect('response',chosen);chooser.show()

    def import_report(self):
        index=self.project_picker.get_selected()
        if index>=len(self.state['projects']):self.status.set_text('Add a project before importing a report.');return
        identity=self.state['projects'][index]['id']
        def chosen(source):
            def saved(result):
                if 'error' not in result:
                    self.history_scope.set_selected(0)
                    self.send('importExport',source=source,projectId=identity)
            self.save(callback=saved)
        self.choose_folder('Choose a portable report folder containing evidence.json',chosen)

    def run_retention(self):
        settings=self.state['settings']
        if not self.jobs and not self.drafts and self.speech.state=='idle' and not self.speech.partial and (int(settings.get('trashRetentionDays','0')) or int(settings.get('trashMaxMiB','0'))):self.send('retention')
        return True

    def storage_settings(self):
        window,content=self.review_window('Storage and backups','Backups contain private originals, notes and filing recovery records. Keep them in a trusted folder. Credentials stay in your desktop keyring.')
        totals=Gtk.Label(label='Reading notebook storage…',xalign=0,wrap=True);content.append(totals)
        def refreshed(result):
            if 'error' not in result:
                info=result['maintenance'];totals.set_text(f"{info['observations']} observations · {info['archived']} archived · {info['trashed']} in Trash\n{info['bytes']/1024/1024:.1f} MiB of saved media")
        def refresh():self.send('storage',callback=refreshed)
        refresh()
        def backup():
            def chosen(destination):
                def saved(result):
                    if 'error' not in result:
                        self.send('backup',destination=destination,callback=lambda result:totals.set_text('Backup saved: '+result['maintenance']['backupPath']) if 'error' not in result else None)
                self.save(callback=saved)
            self.choose_folder('Choose a private backup destination',chosen)
        content.append(self.button('Back up notebook',backup))
        content.append(self.button('Restore notebook backup…',self.restore_notebook))
        content.append(Gtk.Label(label='Trash retention',xalign=0,css_classes=['heading']))
        content.append(Gtk.Label(label='These rules permanently delete discarded items only. Active and archived notes, and unresolved filings, are preserved. Zero disables a limit.',xalign=0,wrap=True))
        fields={}
        for label,key in [('Delete Trash older than days','trashRetentionDays'),('Keep Trash below MiB','trashMaxMiB')]:
            row=box(False,6);row.append(Gtk.Label(label=label,xalign=0,hexpand=True))
            entry=Gtk.Entry(text=self.state['settings'].get(key,'0'),width_chars=8);row.append(entry);fields[key]=entry;content.append(row)
        approved=Gtk.CheckButton(label='Allow automatic permanent deletion using these Trash limits');content.append(approved)
        def save_limits():
            values={key:entry.get_text().strip() for key,entry in fields.items()}
            if any(value!='0' for value in values.values()) and not approved.get_active():totals.set_text('Review and enable the automatic deletion rules first.');return
            def saved(result):
                if 'error' not in result:self.run_retention();totals.set_text('Trash retention settings saved.')
            self.send('settings',settings=values,callback=saved)
        content.append(self.button('Save Trash limits',save_limits))
        content.append(self.button('Review emptying Trash…',self.review_trash))
        content.append(self.button('Refresh storage totals',refresh));content.append(self.button('Close',window.close));window.present()

    def review_trash(self):
        def planned(result):
            if 'error' in result:return
            plan=result['maintenance'];items=plan['items']
            window,content=self.review_window('Permanently delete discarded observations',f"Delete {len(items)} observations and {plan['bytes']/1024/1024:.1f} MiB of media. This cannot be undone. {len(plan['blocked'])} unresolved filings will be kept.")
            content.append(scrolled(Gtk.Label(label='\n'.join(item['title'] for item in items),xalign=0,yalign=0,wrap=True)))
            approved=Gtk.CheckButton(label='Permanently delete these discarded observations and their private media');content.append(approved)
            def confirm():
                if self.jobs or self.drafts or self.speech.state!='idle' or self.speech.partial:self.status.set_text('Save notebook changes and settle dictation before permanent deletion.');return
                button.set_sensitive(False)
                self.send('deleteTrash',versions={item['id']:item['editVersion'] for item in items},callback=lambda response:window.close() if 'error' not in response else button.set_sensitive(True))
            button=self.button('Delete permanently',confirm);button.add_css_class('destructive-action');button.set_sensitive(False)
            approved.connect('toggled',lambda *_:button.set_sensitive(bool(items) and approved.get_active()))
            content.append(button);content.append(self.button('Cancel',window.close));window.present()
        self.send('cleanupPlan',callback=planned)

    def restore_notebook(self):
        if self.speech.state!='idle' or self.speech.partial:self.status.set_text('Finish or settle dictation before restoring a notebook.');return
        def chosen(source):
            def inspected(result):
                if 'error' in result:return
                info=result['maintenance']
                window,content=self.review_window('Restore notebook backup',f"Replace this notebook with {info['observations']} backed-up observations. Lens will first save a recovery backup of the current notebook. Collection will pause; credentials will stay in the keyring.")
                content.append(Gtk.Label(label=source,xalign=0,wrap=True,selectable=True))
                approved=Gtk.CheckButton(label='Replace this notebook with the verified backup');content.append(approved)
                def restore():
                    if self.jobs or self.drafts:self.status.set_text('Wait for notebook work to finish before restoring.');return
                    button.set_sensitive(False);self.media.stop();self.paused=True;self.pause_button.set_label('Resume')
                    def paused(response):
                        if 'error' in response:button.set_sensitive(True);return
                        def restored(response):
                            if 'error' not in response:
                                self.history_scope.set_selected(0);window.close();self.status.set_text('Notebook restored. Collection is paused; resume when ready.')
                            else:button.set_sensitive(True)
                        self.send('restoreBackup',source=source,callback=restored)
                    self.send('settings',settings={'capturePaused':'true'},callback=paused)
                button=self.button('Restore notebook',restore);button.set_sensitive(False)
                approved.connect('toggled',lambda *_:button.set_sensitive(approved.get_active()))
                content.append(button);content.append(self.button('Cancel',window.close));window.present()
            def saved(result):
                if 'error' not in result:self.send('inspectBackup',source=source,callback=inspected)
            self.save(callback=saved)
        self.choose_folder('Choose a Lens backup folder',chosen)

    def shortcut_changed(self,message):
        self.shortcut_message=message
        if hasattr(self,'shortcut_status'):self.shortcut_status.set_text(message)
        self.status.set_text(message)
        if self.shortcuts.registered:self.send('settings',settings={'shortcutEnabled':'true'})

    def apply_suggestion(self):
        suggestion=self.suggestions.pop(self.selected_id,None)
        if suggestion is not None:
            self.editor.get_buffer().set_text(suggestion);self.save();self.render()

    def dismiss_suggestion(self):
        self.suggestions.pop(self.selected_id,None);self.render()

    def progress(self,action,payload,event):
        if action=='file':
            listener=self.progress_listeners.get(payload['observationId'])
            if listener:listener(event)
        elif event.get('detail'):self.status.set_text(event['detail'])
        return False

    def browser_setup(self):
        return onboarding.show(self)

    def open_browser(self,binary,url):
        try:subprocess.Popen([*(binary if isinstance(binary,list) else [binary]),url],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        except OSError as error:self.status.set_text('Could not open the browser: '+str(error))

    def open_source(self,source):
        captures=(self.current() or {}).get('captures',[])
        for index,capture in enumerate(captures):
            if source==capture['id'] or (source.startswith('event:') and any(event['id']==source[6:] for event in capture['events'])):
                self.capture_picker.set_selected(index);self.evidence_stack.set_visible_child_name('evidence');return
        try:
            if source.startswith(('https://','http://')):
                Gio.AppInfo.launch_default_for_uri(source,None);return
            project=next((p for p in self.state['projects'] if p['id']==(self.current() or {}).get('projectId')),None)
            if not project:raise ValueError('Select the source project first.')
            root=Path(project['repositoryPath']).resolve()
            path=Path(re.sub(r':\d+(?::\d+)?$','',source))
            path=(path if path.is_absolute() else root/path).resolve()
            if not path.is_relative_to(root) or not path.exists():raise ValueError('The source is unavailable in the configured repository.')
            Gio.AppInfo.launch_default_for_uri(path.as_uri(),None)
        except (GLib.Error,OSError,ValueError) as error:self.status.set_text(str(error))

    def close(self, *_):
        if self.jobs:
            self.status.set_text('Wait for the current operation before closing. Your evidence remains local.')
            return True
        if self.drafts:
            self.save()
            self.status.set_text('Unsaved notes remain. Save each edited observation before closing.')
            return True
        if self.tray_process and self.tray_process.poll() is None:
            self.window.set_visible(False)
            return True
        if self.speech.state != 'idle' or self.speech.partial or self.media.tab:
            self.status.set_text('Finish dictation and stop window sharing before closing, or use Quit Lens from the tray.')
            return True
        return False


if __name__ == '__main__':
    raise SystemExit(Notebook().run(sys.argv))
