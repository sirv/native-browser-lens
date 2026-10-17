#!/usr/bin/env python3
"""GTK 3 tray helper, isolated from the notebook's GTK 4 process."""
import json
import sys
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('AyatanaAppIndicator3', '0.1')
from gi.repository import AyatanaAppIndicator3 as AppIndicator, Gio, GLib, Gtk


def main():
    application_id = sys.argv[1]
    object_path = '/' + application_id.replace('.', '/')
    actions = Gio.DBusActionGroup.get(Gio.bus_get_sync(Gio.BusType.SESSION, None), application_id, object_path)
    indicator = AppIndicator.Indicator.new('native-browser-lens', 'camera-photo-symbolic', AppIndicator.IndicatorCategory.APPLICATION_STATUS)
    indicator.set_title('Native Browser Lens')
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    menu = Gtk.Menu()
    state_item = Gtk.MenuItem(label='Lens: capture ready')
    state_item.set_sensitive(False); menu.append(state_item)
    capture_item=None
    for label, action in [('Open notebook', 'show'), ('Capture focused browser tab', 'capture'), ('Pause / resume collection', 'pause'), ('Settings', 'settings'), ('Quit Lens', 'quit')]:
        item = Gtk.MenuItem(label=label)
        item.connect('activate', lambda _, name=action: actions.activate_action(name, None))
        menu.append(item)
        if action=='capture':capture_item=item;item.set_sensitive(False)
    menu.show_all(); indicator.set_menu(menu)
    def updated(stream, condition):
        if condition & (GLib.IO_HUP | GLib.IO_ERR):
            Gtk.main_quit(); return False
        line = sys.stdin.readline()
        if not line:
            Gtk.main_quit(); return False
        try:
            state = json.loads(line)
            icon = 'audio-input-microphone' if state.get('dictating') else ('media-record' if state.get('recording') else ('media-playback-pause' if state.get('paused') else 'camera-photo-symbolic'))
            label = 'Dictating' if state.get('dictating') else ('Recording' if state.get('recording') else ('Paused' if state.get('paused') else ('Ready' if state.get('tabs') else ('No project tabs' if state.get('connected') else 'Browser not connected'))))
            indicator.set_icon_full(icon, 'Lens: '+label)
            indicator.set_label('Lens', 'Lens')
            state_item.set_label('Lens: '+label)
            capture_item.set_sensitive(bool(state.get('tabs')) and not state.get('paused'))
        except (ValueError, TypeError):
            pass
        return True
    GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, updated)
    Gtk.main()


if __name__ == '__main__':
    main()
