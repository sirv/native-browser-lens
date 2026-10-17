import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0,str(Path(__file__).parents[1]))
spec=importlib.util.spec_from_file_location('lens_speech',Path(__file__).parents[1]/'speech.py')
speech=importlib.util.module_from_spec(spec);spec.loader.exec_module(speech)


class SpeechTests(unittest.TestCase):
    def wait(self,condition):
        from gi.repository import GLib
        deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
            if condition():return
            time.sleep(.01)
        self.fail('Offline dictation fixture timed out')

    def test_real_microphone_pipeline_sends_only_memory_wav_to_local_helper(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(speech.os.environ, {'GGML_BACKEND_PATH':'/untrusted/backend.so'}):
            root=Path(directory);binary=root/'whisper-cli';model=root/'model.bin';model.write_bytes(b'fixture')
            binary.write_text('#!'+sys.executable+'\nimport io,os,sys,wave\nassert "OPENAI_API_KEY" not in os.environ\nassert "GGML_BACKEND_PATH" not in os.environ\nassert os.getcwd()==os.path.dirname(os.path.abspath(sys.argv[0]))\nw=wave.open(io.BytesIO(sys.stdin.buffer.read()),"rb")\nassert (w.getframerate(),w.getnchannels(),w.getsampwidth())==(16000,1,2)\nassert len(w.readframes(w.getnframes()))>=3200\nprint("A local synthetic transcript")\n');binary.chmod(0o700)
            completed=[];changes=[]
            capture=speech.SpeechCapture(changes.append,completed.append,audio_source='audiotestsrc is-live=true wave=silence',binary=binary,model_path=model)
            capture.start()
            self.wait(lambda:len(capture.pcm)>=6400)
            capture.finish()
            self.wait(lambda:capture.state=='idle')
            self.assertEqual(completed,['A local synthetic transcript'])
            self.assertIsNone(capture.pipeline)
            self.assertIsNone(capture.process)
            self.assertFalse(capture.pcm)
            self.assertEqual(sorted(p.name for p in root.iterdir()),['model.bin','whisper-cli'])

    def test_missing_model_does_not_start_the_microphone_or_request_a_key(self):
        messages=[]
        capture=speech.SpeechCapture(messages.append,lambda _:None,binary='/missing/whisper-cli',model_path='/missing/model')
        capture.start()
        self.assertEqual(capture.state,'idle');self.assertIsNone(capture.pipeline)
        self.assertIn('release bundle',messages[-1]);self.assertNotIn('key',messages[-1])

    def test_cancelled_or_duplicate_completions_cannot_append_to_a_later_note(self):
        completed=[]
        capture=speech.SpeechCapture(lambda _:None,completed.append)
        capture.state='finishing';generation=capture.generation
        capture.deliver('First note',None,generation)
        capture.deliver('Duplicate',None,generation)
        self.assertEqual(completed,['First note'])
        capture.state='finishing';generation=capture.generation;capture.cancel()
        capture.deliver('Late text',None,generation)
        self.assertEqual(completed,['First note'])

    def test_failed_insertion_retains_transcript_for_explicit_recovery(self):
        capture=speech.SpeechCapture(lambda _:None,lambda _:False)
        capture.state='finishing'
        capture.deliver('Keep these words',None,capture.generation)
        self.assertEqual(capture.state,'idle');self.assertEqual(capture.partial,'Keep these words')
