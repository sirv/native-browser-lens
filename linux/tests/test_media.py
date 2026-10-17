import importlib.util
import json
import sys
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

sys.path.insert(0,str(Path(__file__).parents[1]))

spec = importlib.util.spec_from_file_location('lens_media', Path(__file__).parents[1] / 'media.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class FrameRingTests(unittest.TestCase):
    def test_ring_is_bounded_and_never_returns_frames_after_capture(self):
        ring = media.FrameRing()
        for index in range(200):
            ring.add(bytes([index % 256]), 1000 + index / 5, 2000 + index / 5)
        frames = ring.snapshot(2035)
        self.assertLessEqual(len(ring.frames), 150)
        self.assertTrue(all(frame[1] <= 2035 for frame in frames))
        self.assertLessEqual(ring.bytes, 48*1024*1024)
        ring.add(b'x' * (49*1024*1024), 1041, 2041)
        self.assertEqual(ring.bytes, 0)

    def test_identity_includes_document_profile_and_browser_selection(self):
        tab = dict(clientId='client-a', projectId='project', windowId=1, tabId=2, documentId='doc', title='Title', selected=True,selectionEpoch='before')
        self.assertNotEqual(media.tab_key(tab), media.tab_key({**tab, 'clientId':'client-b'}))
        self.assertNotEqual(media.tab_key(tab), media.tab_key({**tab, 'documentId':'new-doc'}))
        self.assertTrue(media.same_selected_tab(tab, [tab]))
        self.assertFalse(media.same_selected_tab(tab, [{**tab, 'selected':False}]))
        self.assertFalse(media.same_selected_tab(tab, [{**tab, 'selected':None}]))
        self.assertFalse(media.same_selected_tab(tab, [{**tab, 'selectionEpoch':'after-switch-away-and-back'}]))

    def test_actual_gstreamer_frames_encode_to_private_png_and_mp4(self):
        desktop = media.DesktopCapture(lambda *_: None)
        tab = dict(clientId='test',projectId='p',windowId=1,tabId=1,documentId='doc',title='Fixture',selected=True,selectionEpoch='before')
        desktop.start_source('videotestsrc is-live=true pattern=ball', tab, True, (320,240))
        deadline=time.monotonic()+5
        try:
            while time.monotonic()<deadline and len(desktop.ring.frames)<5:
                while media.GLib.MainContext.default().pending():
                    media.GLib.MainContext.default().iteration(False)
                time.sleep(.02)
            frames=desktop.frames_at(tab,time.time())
            self.assertGreaterEqual(len(frames),3)
            with tempfile.TemporaryDirectory() as directory:
                destination=Path(directory)
                png=destination/'native.png'
                video=destination/'video.mp4'
                media.save_png(frames[-1][2],png)
                duration=media.save_video(frames,video)
                self.assertTrue(png.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
                probe=subprocess.run(['ffprobe','-v','error','-show_entries','stream=codec_name,profile,width,height','-of','json',str(video)],capture_output=True,text=True,check=True)
                self.assertIn('h264',probe.stdout)
                self.assertIn(json.loads(probe.stdout)['streams'][0]['profile'],('Baseline','Constrained Baseline'))
                self.assertLessEqual(duration,30)
                self.assertEqual(video.stat().st_mode & 0o777,0o600)
            desktop.validate([{**tab,'selectionEpoch':'after-switch-away-and-back'}])
            self.assertIsNone(desktop.tab)
            self.assertEqual(desktop.ring.bytes,0)
        finally:
            desktop.stop()
