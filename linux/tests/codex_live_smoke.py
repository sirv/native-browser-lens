"""Opt-in live subscription check. Sends only the synthetic report/image built here."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import cairo
import importlib.util
import io
import wave

parser=argparse.ArgumentParser();parser.add_argument('--service',type=Path,required=True);parser.add_argument('--codex',type=Path);parser.add_argument('--speech',action='store_true',help='Include the packaged recognizer and synthetic appsrc audio; no physical microphone')
parser.add_argument('--report-output',type=Path,help='Save only the synthetic suggested report/findings for inspection')
parser.add_argument('--unmatched-build',action='store_true',help='Include a captured exception whose source build cannot be verified')
args=parser.parse_args()
service=args.service.resolve()
with tempfile.TemporaryDirectory(prefix='lens-codex-live-') as directory:
    root=Path(directory)
    environment={key:value for key,value in os.environ.items() if key not in ('OPENAI_API_KEY','CODEX_API_KEY')}
    environment.update(LENS_DATA_DIR=directory,XDG_CONFIG_HOME=directory+'/config')
    if args.codex:environment['LENS_CODEX_BINARY']=str(args.codex.resolve())
    def request(action,**payload):
        result=subprocess.run([str(service)],input=json.dumps(dict(action=action,**payload)),capture_output=True,text=True,env=environment,timeout=210)
        values=[json.loads(line) for line in result.stdout.splitlines()]
        if 'error' in values[-1]:raise ValueError(values[-1]['error'])
        return values[-1],values
    assert request('codexStatus')[0]['codexStatus']=='ready','Sign in to Codex with ChatGPT before running this check.'
    project=dict(id=str(uuid.uuid4()),name='Codex delivery fixture',origins=['http://localhost:3000'],repositoryPath='',documentationPaths=[],logPaths=[],ownership=[],enabled=True,adapter='generic',recording='diagnostics')
    request('configure',projects=[project])
    folder=root/'portable';folder.mkdir()
    surface=cairo.ImageSurface(cairo.FORMAT_ARGB32,480,180);context=cairo.Context(surface)
    context.set_source_rgb(.14,.16,.23);context.paint();context.set_source_rgb(.75,.8,.96)
    context.set_font_size(22);context.move_to(24,70);context.show_text('Fixture: Save returned HTTP 503');surface.write_to_png(str(folder/'fixture.png'))
    note='Observed: clicking Save produces HTTP 503. Expected: save succeeds. This is synthetic test evidence.'
    speech_started=None;speech_seconds=None
    if args.speech:
        spec=importlib.util.spec_from_file_location('lens_speech',service.parent/'speech.py');speech=importlib.util.module_from_spec(spec);spec.loader.exec_module(speech)
        audio=subprocess.run(['espeak-ng','--stdout','-s','145','The save button returns a server error. Please keep my notebook text.'],capture_output=True,check=True).stdout
        wav=subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-ar','16000','-ac','1','-c:a','pcm_s16le','-f','wav','pipe:1'],input=audio,capture_output=True,check=True).stdout
        with wave.open(io.BytesIO(wav),'rb') as recording:pcm=recording.readframes(recording.getnframes())
        completed=[];messages=[]
        capture=speech.SpeechCapture(messages.append,completed.append,audio_source='appsrc name=fixture is-live=true format=time caps="audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved"',binary=service.parent/'whisper-cli',model_path=service.parent/'dictation-model.bin')
        def wait_for(condition):
            deadline=time.monotonic()+185
            while time.monotonic()<deadline:
                while speech.GLib.MainContext.default().pending():speech.GLib.MainContext.default().iteration(False)
                if condition():return
                time.sleep(.005)
            raise AssertionError('Synthetic speech did not finish: '+str(messages[-1:]))
        try:
            capture.start();assert capture.state=='recording',messages
            buffer=speech.Gst.Buffer.new_allocate(None,len(pcm),None);buffer.fill(0,pcm)
            assert capture.pipeline.get_by_name('fixture').emit('push-buffer',buffer)==speech.Gst.FlowReturn.OK
            wait_for(lambda:len(capture.pcm)==len(pcm))
            speech_started=time.monotonic();capture.finish();wait_for(lambda:capture.state=='idle')
            speech_seconds=time.monotonic()-speech_started
            assert completed and 'server error' in completed[0].lower() and 'notebook' in completed[0].lower(),messages
            note+='\nDictated: '+completed[0]
        finally:capture.cancel()
    stamp=time.time()*1000
    identity=dict(projectId=project['id'],tabId=1,windowId=1,documentId='fixture',url='http://localhost:3000',title='Synthetic Save failure',capturedAt=stamp)
    event=dict(id=str(uuid.uuid4()),projectId=project['id'],tabId=1,documentId='fixture',timestamp=stamp,kind='response',data={'status':503,'url':'http://localhost:3000/api/save'})
    item=dict(id=str(uuid.uuid4()),projectId=project['id'],createdAt=stamp,title='Save failure fixture',markdown=note,draftRevision=1,editVersion=0,captures=[dict(id=str(uuid.uuid4()),identity=identity,events=[event],gaps=[],context={},screenshotPath='fixture.png',annotations=[])],findings=[])
    if args.unmatched_build:
        identity['buildId']='a'*40
        item['captures'][0]['context']['sourceBuildVerified']=False
        item['captures'][0]['events'].append(dict(id=str(uuid.uuid4()),projectId=project['id'],tabId=1,documentId='fixture',timestamp=stamp,kind='exception',data={'details':{'text':'Save failed','stackTrace':{'callFrames':[{'functionName':'save','url':'http://localhost:3000/assets/main.js','lineNumber':0,'columnNumber':42}]}}}))
    (folder/'evidence.json').write_text(json.dumps(item))
    result=request('importExport',source=str(folder),projectId=project['id'])[0]
    item=next(value for value in result['observationUpdates'] if value['id']==result['selectedObservationId'])
    start=time.monotonic()
    result,events=request('cloud',observationId=item['id'],reviewedVersion=item['editVersion'],reviewed=True,captureIds=[item['captures'][0]['id']],stream=True)
    saved=next(value for value in result['observationUpdates'] if value['id']==item['id'])
    assert saved['markdown']==note
    assert result['suggestedDraft'].strip()
    draft=result['suggestedDraft']
    assert '503' in draft and 'save' in draft.lower(),'The report must retain the observed failure.'
    if args.unmatched_build:
        assert any(finding['kind']=='coverage' and 'source map unresolved' in finding['text'].lower() for finding in saved['findings'])
        assert any(term in draft.lower() for term in ('unmatched','unresolved','unverified','source map','build')),'The report must retain the source/build gap.'
    if args.report_output:
        args.report_output.parent.mkdir(parents=True,exist_ok=True)
        args.report_output.write_text(json.dumps(dict(markdown=draft,findings=saved['findings'],unmatchedBuild=args.unmatched_build),indent=2)+'\n');args.report_output.chmod(0o600)
    timing=dict(speechSeconds=round(speech_seconds,2),finishToDraftSeconds=round(time.monotonic()-speech_started,2),timingBoundary='Synthetic appsrc Finish to complete suggestion; automatic test review, no human review delay or physical microphone') if args.speech else {}
    print(json.dumps(dict(passed=True,auth='existing ChatGPT subscription through Codex',apiKeyRequired=False,reviewedImages=1,manualNotesPreserved=True,draftCharacters=len(result['suggestedDraft']),findings=len(saved['findings']),progressEvents=sum('progress' in event for event in events),elapsedSeconds=round(time.monotonic()-start,2),**timing)))
