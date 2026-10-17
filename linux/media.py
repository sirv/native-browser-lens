"""Window-only portal capture with a private, bounded in-memory video ring."""
import video_codecs
from collections import deque
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

import gi
gi.require_version('Gst', '1.0')
gi.require_version('GdkPixbuf', '2.0')
gi.require_version('Xdp', '1.0')
from gi.repository import GdkPixbuf, Gio, GLib, Gst, Xdp
Gst.init(None)


def tab_key(tab):
    return tuple(tab.get(key) for key in ('clientId', 'projectId', 'windowId', 'tabId', 'documentId', 'title'))


def same_selected_tab(tab, tabs):
    return any(tab_key(candidate) == tab_key(tab) and candidate.get('selectionEpoch') == tab.get('selectionEpoch') and candidate.get('selected') is True and candidate.get('mode') not in ('paused', 'unavailable') for candidate in tabs)


class FrameRing:
    def __init__(self):
        self.frames = deque()
        self.bytes = 0
        self.lock = threading.Lock()

    def add(self, jpeg, monotonic, wall_time, recording=True):
        with self.lock:
            self.frames.append((monotonic, wall_time, jpeg))
            self.bytes += len(jpeg)
            while self.frames and (monotonic-self.frames[0][0] >= 30 or self.bytes > 48*1024*1024 or len(self.frames) > (150 if recording else 1)):
                self.bytes -= len(self.frames.popleft()[2])

    def snapshot(self, wall_time):
        with self.lock:
            return [frame for frame in self.frames if frame[1] <= wall_time and wall_time-frame[1] <= 30]

    def clear(self):
        with self.lock:
            self.frames.clear(); self.bytes = 0


def save_png(jpeg, destination):
    loader = GdkPixbuf.PixbufLoader.new_with_type('jpeg')
    loader.write(jpeg); loader.close()
    image = loader.get_pixbuf()
    temporary = Path(str(destination) + '.tmp')
    try:
        image.savev(str(temporary), 'png', [], [])
        temporary.chmod(0o600)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return image.get_width(), image.get_height()


def save_video(frames, destination):
    if len(frames) < 2:
        raise ValueError('The recording has no usable video yet. Let it run for a moment and capture again.')
    destination = Path(destination)
    duration = min(30, frames[-1][0]-frames[0][0]+.2)
    with tempfile.TemporaryDirectory(prefix='.video-', dir=destination.parent) as directory:
        staging = Path(directory)
        lines = []
        for index, frame in enumerate(frames):
            (staging / f'{index}.jpg').write_bytes(frame[2])
            lines.append(f"file '{index}.jpg'")
            seconds = frames[index+1][0]-frame[0] if index+1 < len(frames) else .2
            lines.append(f'duration {max(.001, seconds):.6f}')
        lines.append(f"file '{len(frames)-1}.jpg'")
        manifest = staging / 'frames.txt'
        manifest.write_text('\n'.join(lines)+'\n')
        output = staging / 'video.mp4'
        result = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', str(manifest), '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-fps_mode', 'vfr', *video_codecs.arguments(video_codecs.encoder()), '-pix_fmt', 'yuv420p', '-an', '-t', str(duration), '-movflags', '+faststart', str(output)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
        if result.returncode or not output.is_file():
            raise RuntimeError('The video encoder could not save this recording. Its local capture remains available.')
        output.chmod(0o600); output.replace(destination)
    return duration


class DesktopCapture:
    def __init__(self, on_changed):
        self.on_changed = on_changed
        self.ring = FrameRing()
        self.tab = None
        self.recording = False
        self.pipeline = None
        self.session = None
        self.fd = None
        self.cancellable = None
        self.generation = 0
        self.starting = False
        self.allowed = False

    def start(self, tab, recording=False):
        self.stop()
        if tab.get('selected') is not True:
            raise ValueError('Select the target tab in Chrome first, and reload the updated extension if needed.')
        if not isinstance(tab.get('selectionEpoch'),str) or not tab['selectionEpoch']:
            raise ValueError('Reload the Lens browser extension to connect the updated native host before sharing a window.')
        self.tab = dict(tab); self.recording = recording; self.starting = True
        self.cancellable = Gio.Cancellable()
        generation = self.generation
        portal = Xdp.Portal.new()
        self.on_changed('Choose the browser window in the system sharing dialog.')
        def created(portal, result, *_):
            try:
                session = portal.create_screencast_session_finish(result)
                if generation != self.generation:
                    session.close(); return
                self.session = session
                session.connect('closed', lambda *_: self.fail('Window sharing ended.') if self.session is session else None)
                session.start(None, self.cancellable, started)
            except GLib.Error:
                if generation == self.generation:
                    self.fail('Window sharing was cancelled or the desktop portal is unavailable.')
        def started(session, result, *_):
            try:
                if not session.start_finish(result):
                    raise ValueError('Window sharing was cancelled.')
                if generation != self.generation:
                    session.close(); return
                streams = session.get_streams()
                streams = streams.unpack() if streams else []
                if len(streams) != 1 or streams[0][1].get('source_type') != int(Xdp.OutputType.WINDOW):
                    raise ValueError('Select one window for capture. Display capture is not used for browser evidence.')
                node, properties = streams[0]
                self.fd = session.open_pipewire_remote()
                size = properties.get('size', (1440, 900))
                self.start_source(f'pipewiresrc fd={self.fd} path={int(node)} always-copy=true do-timestamp=true', tab, recording, size)
            except (GLib.Error, ValueError, OSError, RuntimeError) as error:
                if generation == self.generation:
                    self.fail(str(error))
        portal.create_screencast_session(Xdp.OutputType.WINDOW, Xdp.ScreencastFlags(0), Xdp.CursorMode.EMBEDDED, Xdp.PersistMode.NONE, None, self.cancellable, created)

    def start_source(self, source, tab, recording, size):
        width, height = size
        scale = min(1, 1440/max(1,width), 900/max(1,height))
        width, height = max(2,int(width*scale)//2*2), max(2,int(height*scale)//2*2)
        self.tab = dict(tab); self.recording = recording; self.allowed = True
        self.pipeline = Gst.parse_launch(source + f' ! videoconvert ! videoscale ! videorate ! video/x-raw,width={width},height={height},framerate=5/1 ! jpegenc quality=70 ! appsink name=frames emit-signals=true max-buffers=1 drop=true sync=false')
        self.pipeline.get_by_name('frames').connect('new-sample', self.sample)
        bus = self.pipeline.get_bus(); bus.add_signal_watch(); bus.connect('message', self.message)
        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self.stop(); raise RuntimeError('The desktop video stream could not start.')
        self.starting = False
        self.on_changed('Rolling video is on; only the last 30 seconds stay in memory.' if recording else 'Window sharing is ready for native screenshot fallback.')

    def sample(self, sink):
        sample = sink.emit('pull-sample')
        if sample and self.allowed:
            buffer = sample.get_buffer()
            success, mapping = buffer.map(Gst.MapFlags.READ)
            if success:
                try:
                    self.ring.add(bytes(mapping.data), time.monotonic(), time.time(), self.recording)
                finally:
                    buffer.unmap(mapping)
        return Gst.FlowReturn.OK

    def frames_at(self, identity, captured_at):
        if self.tab is None or tab_key(identity) != tab_key(self.tab) or not self.allowed:
            return []
        return self.ring.snapshot(captured_at)

    def validate(self, tabs):
        if self.tab is not None and not same_selected_tab(self.tab, tabs):
            self.stop()
            self.on_changed('Window capture stopped because the selected tab, document or browser profile changed.')

    def message(self, _, message):
        if message.type in (Gst.MessageType.ERROR, Gst.MessageType.EOS):
            self.fail('The desktop video stream stopped. Share the window again to resume.')

    def fail(self, message):
        self.stop(); self.on_changed(message)

    def stop(self):
        self.generation += 1; self.allowed = False; self.starting = False
        if self.cancellable:
            self.cancellable.cancel(); self.cancellable = None
        pipeline, self.pipeline = self.pipeline, None
        if pipeline:
            pipeline.get_bus().remove_signal_watch()
            pipeline.set_state(Gst.State.NULL)
        session, self.session = self.session, None
        if session:
            session.close()
        if self.fd is not None:
            os.close(self.fd); self.fd = None
        self.tab = None; self.recording = False; self.ring.clear()
