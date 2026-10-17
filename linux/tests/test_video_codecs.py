import sys
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parents[1]))
import video_codecs

class VideoCodecTests(unittest.TestCase):
    def test_encoder_preference_and_distribution_fallback(self):
        for listing,expected in [('libx264 libopenh264','libx264'),('libopenh264','libopenh264'),('','')]:
            with patch.object(video_codecs.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=listing,stderr='')):
                self.assertEqual(video_codecs.encoder(),expected)
        self.assertIn('baseline',video_codecs.arguments('libx264'))
        self.assertIn('constrained_baseline',video_codecs.arguments('libopenh264'))
        self.assertNotIn('-crf',video_codecs.arguments('libopenh264'))
        with self.assertRaises(ValueError):video_codecs.arguments('unavailable')
    def test_decoder_accepts_available_standard_or_openh264_provider(self):
        for available in ('avdec_h264','openh264dec',''):
            def probe(command,**_):return subprocess.CompletedProcess(command,0 if command[-1] in (available,'h264parse') else 1)
            with patch.object(video_codecs.subprocess,'run',side_effect=probe):self.assertEqual(video_codecs.decoder(),available)
        def missing_parser(command,**_):return subprocess.CompletedProcess(command,0 if command[-1]=='openh264dec' else 1)
        with patch.object(video_codecs.subprocess,'run',side_effect=missing_parser):self.assertEqual(video_codecs.decoder(),'')
