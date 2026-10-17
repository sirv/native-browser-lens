#!/usr/bin/env python3
"""Build a pinned portable CPU dictation helper and verify its bundled model."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import urllib.request

REPO=Path(__file__).resolve().parent.parent
COMMIT='d1be6fde11ac6e0407606b4e42fe72d34add8037'
MODEL_SHA256='a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002'


def main():
    source=REPO/'.build/whisper.cpp'
    if not source.exists():subprocess.run(['git','clone','--depth','1','--branch','v1.9.5','https://github.com/ggml-org/whisper.cpp',str(source)],check=True)
    if subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()!=COMMIT:raise ValueError('The dictation source does not match its pinned release.')
    build=source/'build-lens-dispatch'
    subprocess.run(['cmake','-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=ON','-DGGML_BACKEND_DL=ON','-DGGML_CPU_ALL_VARIANTS=ON','-DGGML_NATIVE=OFF','-DGGML_OPENMP=OFF','-DGGML_CCACHE=OFF','-DWHISPER_BUILD_TESTS=OFF'],check=True)
    subprocess.run(['cmake','--build',str(build),'--target','whisper-cli','--parallel','4'],check=True)
    model=source/'models/ggml-base.en.bin'
    if not model.exists():
        temporary=model.with_suffix('.download')
        try:
            with urllib.request.urlopen('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin',timeout=60) as response,temporary.open('wb') as output:shutil.copyfileobj(response,output)
            with temporary.open('rb') as data:
                if hashlib.file_digest(data,'sha256').hexdigest()!=MODEL_SHA256:raise ValueError('The dictation model checksum did not match.')
            temporary.replace(model)
        finally:temporary.unlink(missing_ok=True)
    with model.open('rb') as data:
        if hashlib.file_digest(data,'sha256').hexdigest()!=MODEL_SHA256:raise ValueError('The dictation model is damaged.')
    destination=REPO/'dist/linux';destination.mkdir(parents=True,exist_ok=True)
    shutil.copy2(build/'bin/whisper-cli',destination/'whisper-cli')
    for pattern in ('libggml*.so*','libwhisper.so*'):
        for path in destination.glob(pattern):path.unlink()
        for path in (build/'bin').glob(pattern):shutil.copy2(path,destination/path.name)
    shutil.copy2(model,destination/'dictation-model.bin')
    shutil.copy2(source/'LICENSE',destination/'WHISPER-LICENSE')
    license=source/'models/OPENAI-LICENSE'
    if not license.exists():
        with urllib.request.urlopen('https://raw.githubusercontent.com/openai/whisper/main/LICENSE',timeout=20) as response:license.write_bytes(response.read())
    shutil.copy2(license,destination/'WHISPER-MODEL-LICENSE')


if __name__=='__main__':main()
