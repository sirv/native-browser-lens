"""Explicit offline dictation with bounded in-memory audio and the bundled Whisper CPU helper."""
import io
import os
from pathlib import Path
import queue
import subprocess
import threading
import wave

import gi
gi.require_version('Gst','1.0')
from gi.repository import GLib,Gst
Gst.init(None)


class SpeechCapture:
    def __init__(self,on_changed,on_completed,audio_source='pulsesrc client-name="Native Browser Lens"',binary=None,model_path=None):
        self.on_changed,self.on_completed=on_changed,on_completed
        here=Path(__file__).resolve().parent
        runtime=here if (here/'whisper-cli').exists() else here.parent/'dist/linux'
        self.binary=Path(binary or runtime/'whisper-cli').resolve()
        self.model=Path(model_path or runtime/'dictation-model.bin').resolve()
        self.audio_source=audio_source
        self.state,self.partial='idle',''
        self.generation=0
        self.pipeline=self.process=None
        self.audio_timer=self.limit_timer=None
        self.audio=queue.Queue(maxsize=16)
        self.pcm=bytearray()
        self.lock=threading.Lock()

    def start(self):
        if self.state!='idle':return
        if self.partial:self.on_changed('Insert or discard the retained transcript before starting another session.');return
        if not os.access(self.binary,os.X_OK) or not self.model.is_file():
            self.on_changed('Offline dictation is missing. Install the Lens release bundle, which includes the speech model.');return
        self.cancel();generation=self.generation
        try:
            self.pipeline=Gst.parse_launch(self.audio_source+' ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved ! appsink name=audio emit-signals=true max-buffers=4 sync=false')
            self.pipeline.get_by_name('audio').connect('new-sample',self.sample,generation)
            bus=self.pipeline.get_bus();bus.add_signal_watch()
            bus.connect('message',lambda _,message:self.fail('Microphone capture stopped. Check your input device.',generation) if message.type==Gst.MessageType.ERROR else None)
            self.state='recording'
            if self.pipeline.set_state(Gst.State.PLAYING)==Gst.StateChangeReturn.FAILURE:raise RuntimeError('Microphone unavailable')
            self.audio_timer=GLib.timeout_add(40,self.flush,generation)
            self.limit_timer=GLib.timeout_add_seconds(120,self.finish)
            self.on_changed('Recording locally, up to two minutes. Press Finish dictation to transcribe. Audio stays in memory on this computer.')
        except (GLib.Error,RuntimeError):self.fail('The microphone could not start. Check the input device and GStreamer PulseAudio plugin.',generation)

    def sample(self,sink,generation):
        sample=sink.emit('pull-sample')
        if sample and generation==self.generation and self.state=='recording':
            buffer=sample.get_buffer();success,mapping=buffer.map(Gst.MapFlags.READ)
            if success:
                try:self.audio.put_nowait(bytes(mapping.data))
                except queue.Full:GLib.idle_add(self.fail,'Dictation could not keep up with audio. Capture stopped.',generation)
                finally:buffer.unmap(mapping)
        return Gst.FlowReturn.OK

    def flush(self,generation):
        if generation!=self.generation:return False
        while not self.audio.empty():
            self.pcm.extend(self.audio.get_nowait())
            if len(self.pcm)>16000*2*121:
                self.fail('The dictation audio limit was reached. Start a shorter recording.',generation);return False
        return self.state=='recording'

    def finish(self):
        if self.state!='recording':return False
        self.stop_microphone();self.flush(self.generation)
        if self.state!='recording':return False
        if len(self.pcm)<3200:self.fail('The audio turn was too short. Record at least a moment of speech.',self.generation);return False
        self.state='finishing';generation=self.generation
        output=io.BytesIO()
        with wave.open(output,'wb') as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(16000);audio.writeframes(self.pcm)
        self.pcm.clear();payload=output.getvalue()
        self.on_changed('Transcribing locally with Whisper. This can take a moment; your notebook stays editable.')
        def work():
            transcript='';error=None;process=None
            try:
                with self.lock:
                    if generation!=self.generation:return
                    # Backend discovery must not load code from an open project or an inherited override.
                    environment={key:value for key,value in os.environ.items() if key not in ('OPENAI_API_KEY','CODEX_API_KEY','GGML_BACKEND_PATH')}
                    process=subprocess.Popen([str(self.binary),'-m',str(self.model),'-f','-','-nt','-np','-otxt','-of','-','-t',str(min(4,os.cpu_count() or 1))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=environment,cwd=self.binary.parent)
                    self.process=process
                data,_=process.communicate(payload,timeout=180)
                if process.returncode:raise ValueError('Offline transcription stopped. Retry a shorter recording.')
                transcript=data.decode('utf-8').strip()
                if len(transcript)>64000:raise ValueError('The transcript exceeded its text limit.')
            except (OSError,ValueError,subprocess.SubprocessError) as failure:error=str(failure)
            finally:
                if process and process.poll() is None:process.kill();process.wait()
                with self.lock:
                    if self.process is process:self.process=None
            GLib.idle_add(self.deliver,transcript,error,generation)
        threading.Thread(target=work,daemon=True).start()
        return False

    def deliver(self,transcript,error,generation):
        if generation!=self.generation or self.state!='finishing':return False
        self.cancel()
        if error:self.on_changed(error);return False
        if not transcript:self.on_changed('No speech was recognized. Check your microphone and try again.');return False
        if self.on_completed(transcript) is False:
            self.partial=transcript;self.on_changed('The original observation is unavailable. The transcript is retained.')
        else:self.on_changed('Dictation added to its original observation.')
        return False

    def fail(self,message,generation):
        if generation==self.generation:self.cancel();self.on_changed(message)
        return False

    def clear_timer(self,name):
        value=getattr(self,name)
        if value is not None:GLib.source_remove(value);setattr(self,name,None)

    def stop_microphone(self):
        pipeline,self.pipeline=self.pipeline,None
        if pipeline:pipeline.get_bus().remove_signal_watch();pipeline.set_state(Gst.State.NULL)
        self.clear_timer('audio_timer');self.clear_timer('limit_timer')

    def cancel(self):
        with self.lock:
            self.generation+=1
            if self.process and self.process.poll() is None:self.process.terminate()
        self.stop_microphone();self.state='idle';self.pcm.clear();self.audio=queue.Queue(maxsize=16)
