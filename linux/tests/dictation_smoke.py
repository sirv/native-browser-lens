"""Transcribe synthetic English speech with the actual bundled offline engine; no microphone."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser=argparse.ArgumentParser();parser.add_argument('bundle',type=Path);parser.add_argument('--baseline-cpu',action='store_true',help='Use qemu-x86_64 with no AVX/AVX2 to exercise the fallback');args=parser.parse_args()
bundle=args.bundle.resolve()
audio=subprocess.run(['espeak-ng','--stdout','-s','145','The save button returns a server error. Please keep my notebook text.'],capture_output=True,check=True).stdout
wav=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-ar','16000','-ac','1','-c:a','pcm_s16le','-f','wav','pipe:1'],input=audio,capture_output=True,check=True).stdout
started=time.monotonic()
binary=['qemu-x86_64','-cpu','qemu64',str(bundle/'lib/ld-linux-x86-64.so.2'),'--library-path',str(bundle/'lib'),str(bundle/'whisper-cli.bin')] if args.baseline_cpu else [str(bundle/'whisper-cli')]
result=subprocess.run(binary+['-m',str(bundle/'dictation-model.bin'),'-f','-','-nt','-np','-otxt','-of','-','-t','4'],input=wav,capture_output=True,timeout=180,check=True,cwd=bundle/'lib')
transcript=result.stdout.decode().strip()
assert 'server error' in transcript.lower(),transcript
assert 'notebook' in transcript.lower(),transcript
print(json.dumps(dict(passed=True,provider='bundled offline Whisper base.en',apiKeyRequired=False,audioSource='synthetic English speech',cpu='emulated x86-64 without AVX/AVX2' if args.baseline_cpu else 'automatic host CPU selection',transcript=transcript,elapsedSeconds=round(time.monotonic()-started,2))))
