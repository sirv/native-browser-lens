"""Application-local Tokyo Night palettes; no desktop theme files are changed."""
from string import Template
import gi
gi.require_version('Gtk','4.0')
gi.require_version('Gdk','4.0')
from gi.repository import Gdk, Gio, GLib, Gtk

# Adapted from folke/tokyonight.nvim; secondary text and Day blue meet normal-text contrast.
PALETTES = {
    'dark':dict(bg='#24283b',surface='#1f2335',inset='#292e42',fg='#c0caf5',muted='#a9b1d6',line='#3b4261',accent='#7aa2f7',accent_fg='#1f2335',success='#9ece6a',warning='#e0af68',error='#f7768e'),
    'light':dict(bg='#e1e2e7',surface='#f5f6fa',inset='#d0d5e3',fg='#343b58',muted='#526184',line='#b4b9ce',accent='#245fbd',accent_fg='#ffffff',success='#47652f',warning='#82541d',error='#b52d4e'),
}


def stylesheet(palette):
    return Template('''
@define-color window_bg_color $bg;
@define-color window_fg_color $fg;
@define-color view_bg_color $surface;
@define-color view_fg_color $fg;
@define-color theme_bg_color $bg;
@define-color theme_fg_color $fg;
@define-color theme_base_color $surface;
@define-color theme_text_color $fg;
@define-color theme_selected_bg_color $accent;
@define-color theme_selected_fg_color $accent_fg;
@define-color accent_color $accent;
@define-color accent_bg_color $accent;
@define-color accent_fg_color $accent_fg;
@define-color borders $line;
window { background: $bg; color: $fg; font-family: "Noto Sans", sans-serif; font-size: 13px; }
headerbar { background: $surface; color: $fg; border-bottom: 1px solid $line; box-shadow: none; }
headerbar .title { font-size: 14px; font-weight: 650; }
.title-2 { font-size: 21px; font-weight: 650; }
.heading { font-weight: 650; }
.dim-label { color: $muted; opacity: 1; }
.sidebar { background: $surface; border-right: 1px solid $line; }
.toolbar { background: $surface; border-bottom: 1px solid $line; }
.statusbar { background: $surface; border-top: 1px solid $line; color: $muted; }
.canvas { background: $surface; border: 1px solid $line; border-radius: 8px; }
.notice { background: $inset; padding: 12px; border-radius: 8px; }
.success { color: $success; }
.warning { color: $warning; }
.error { color: $error; }
button { background: $inset; color: $fg; border: 1px solid $line; border-radius: 7px; box-shadow: none; padding: 6px 10px; min-height: 24px; text-shadow: none; }
button:hover { background: alpha($accent,0.16); border-color: $accent; }
button:active,button:checked { background: alpha($accent,0.24); border-color: $accent; }
button.suggested-action { background: $accent; color: $accent_fg; border-color: $accent; }
button.suggested-action:hover { background: shade($accent,1.08); }
button.flat { background: transparent; border-color: transparent; }
button:disabled { opacity: 0.5; }
windowcontrols button { min-height: 16px; min-width: 16px; padding: 3px; border-color: transparent; }
button:focus-visible,entry:focus-within,textview:focus-visible,dropdown:focus-visible,checkbutton:focus-visible { outline: 2px solid $accent; outline-offset: 2px; }
entry,searchentry { background: $surface; color: $fg; caret-color: $accent; border: 1px solid $line; border-radius: 7px; padding: 7px 10px; box-shadow: none; }
textview,textview text { background: $surface; color: $fg; caret-color: $accent; }
textview { border-radius: 7px; }
textview.monospace { font-family: "Noto Sans Mono", monospace; font-size: 12px; }
textview text selection,entry selection { background: $accent; color: $accent_fg; }
list,viewport { background: transparent; color: $fg; }
list row { border-radius: 7px; margin-bottom: 3px; }
list row:hover { background: $inset; }
list row:selected { background: $inset; color: $fg; box-shadow: inset 3px 0 $accent; }
popover contents { background: $surface; color: $fg; border: 1px solid $line; border-radius: 9px; }
popover modelbutton:hover,dropdown popover row:selected { background: $inset; color: $fg; }
checkbutton check { background: $surface; border: 1px solid $line; border-radius: 4px; color: $accent_fg; }
checkbutton check:checked { background: $accent; border-color: $accent; }
separator,paned > separator { background: $line; min-width: 1px; min-height: 1px; }
scrollbar { background: transparent; }
scrollbar slider { background: alpha($muted,0.45); border-radius: 6px; min-width: 6px; min-height: 6px; }
scrollbar slider:hover { background: $muted; }
stack switcher button:checked { border-bottom: 2px solid $accent; }
link,label link { color: $accent; }
tooltip { background: $surface; color: $fg; border: 1px solid $line; }
''').substitute(palette)


class Appearance:
    def __init__(self):
        self.mode = 'dark'; self.applied = None; self.system_dark = True
        self.provider = Gtk.CssProvider(); self.bus = None; self.subscription = None
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(),self.provider,Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION+1)
        try:
            self.bus = Gio.bus_get_sync(Gio.BusType.SESSION,None)
            value = self.bus.call_sync('org.freedesktop.portal.Desktop','/org/freedesktop/portal/desktop','org.freedesktop.portal.Settings','Read',GLib.Variant('(ss)',('org.freedesktop.appearance','color-scheme')),None,Gio.DBusCallFlags.NONE,500,None).unpack()[0]
            self.system_dark = value != 2
            self.subscription = self.bus.signal_subscribe('org.freedesktop.portal.Desktop','org.freedesktop.portal.Settings','SettingChanged','/org/freedesktop/portal/desktop',None,Gio.DBusSignalFlags.NONE,self.changed)
        except GLib.Error:
            pass
        settings = Gtk.Settings.get_default()
        settings.props.gtk_theme_name = 'Adwaita'
        self.set('dark')

    def set(self,mode):
        self.mode = mode if mode in ('dark','light','system') else 'dark'
        resolved = ('dark' if self.system_dark else 'light') if self.mode == 'system' else self.mode
        if self.applied != resolved:
            Gtk.Settings.get_default().props.gtk_application_prefer_dark_theme = resolved == 'dark'
            self.provider.load_from_data(stylesheet(PALETTES[resolved]).encode())
            self.applied = resolved

    def changed(self,connection,sender,path,interface,signal,parameters):
        namespace,key,value = parameters.unpack()
        if namespace == 'org.freedesktop.appearance' and key == 'color-scheme':
            self.system_dark = value != 2
            self.set(self.mode)

    def close(self):
        if self.subscription:
            self.bus.signal_unsubscribe(self.subscription)
        Gtk.StyleContext.remove_provider_for_display(Gdk.Display.get_default(),self.provider)
