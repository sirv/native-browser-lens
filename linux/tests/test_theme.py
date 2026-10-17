import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('lens_theme', Path(__file__).parents[1]/'theme.py')
theme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(theme)


def luminance(color):
    channels = [int(color[i:i+2],16)/255 for i in (1,3,5)]
    return sum(weight*(value/12.92 if value<=.04045 else ((value+.055)/1.055)**2.4) for weight,value in zip((.2126,.7152,.0722),channels))


class ThemeTests(unittest.TestCase):
    def test_readable_text_and_focus_in_both_palettes(self):
        for palette in theme.PALETTES.values():
            for fg,bg in [('fg','bg'),('muted','bg'),('muted','surface'),('accent_fg','accent')]:
                values=sorted((luminance(palette[fg]),luminance(palette[bg])))
                self.assertGreaterEqual((values[1]+.05)/(values[0]+.05),4.5,(palette,fg,bg))
            self.assertIn(':focus-visible',theme.stylesheet(palette))

    def test_gtk_accepts_both_stylesheets(self):
        from gi.repository import Gtk
        for palette in theme.PALETTES.values():
            errors=[];provider=Gtk.CssProvider()
            provider.connect('parsing-error',lambda _,section,error:errors.append(str(error)))
            provider.load_from_data(theme.stylesheet(palette).encode())
            self.assertEqual(errors,[])
