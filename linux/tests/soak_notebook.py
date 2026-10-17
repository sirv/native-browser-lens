"""Private GTK companion for the browser soak. Records counts/resources and actual canvas paints."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import signal
import sys
import time

parser=argparse.ArgumentParser();parser.add_argument('--app',type=Path,required=True);parser.add_argument('--root',type=Path,required=True);parser.add_argument('--status',type=Path,required=True);args=parser.parse_args()
os.environ['LENS_DATA_DIR']=str(args.root)
os.environ['LENS_SERVICE_PATH']=str(args.app/'lens-service')
os.environ['XDG_CONFIG_HOME']=str(args.root/'config')
sys.path.insert(0,str(args.app))
spec=importlib.util.spec_from_file_location('notebook',args.app/'notebook.py');notebook=importlib.util.module_from_spec(spec);spec.loader.exec_module(notebook)
app=notebook.Notebook(desktop=False);app.set_flags(notebook.Gio.ApplicationFlags.NON_UNIQUE);app.register(None)
sync_stages=[];request=app.request;completed=app.completed
def timed_request(action,payload,progress=None):
    started=time.time()*1000
    response=request(action,payload,progress)
    if action=='sync':response['soakTiming']={'helperStartedAtMs':started,'helperReturnedAtMs':time.time()*1000}
    return response
def timed_completed(response,callback):
    timing=response.pop('soakTiming',None)
    result=completed(response,callback)
    if timing is not None:
        captured=response.get('update',{}).get('capturedObservationIDs',[])
        timing.update(uiFinishedAtMs=time.time()*1000,captureIds=[capture['id'] for item in response.get('observationUpdates',[]) if item['id'] in captured for capture in item['captures']])
        sync_stages.append(timing);del sync_stages[:-32]
    return result
app.request=timed_request;app.completed=timed_completed;app.activate()
painted={};draw=app.draw

def paint(widget,context,width,height):
    draw(widget,context,width,height)
    capture=app.current_capture()
    if capture and app.image is not None and width>0 and height>0:painted.setdefault(capture['id'],time.time()*1000)
app.canvas.set_draw_func(paint)

def snapshot():
    own=resource.getrusage(resource.RUSAGE_SELF);children=resource.getrusage(resource.RUSAGE_CHILDREN)
    status=Path('/proc/self/status').read_text()
    rss=int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:')))
    values=list(app.state['observations'])
    captures=[capture['id'] for item in values for capture in item['captures']]
    size=0
    for path in args.root.rglob('*'):
        try:
            if path.is_file() and not path.is_symlink():size+=path.stat().st_size
        except FileNotFoundError:
            pass  # SQLite and bridge files can disappear between enumeration and stat.
    payload=dict(pid=os.getpid(),updatedAtMs=time.time()*1000,ready=app.settings_loaded,jobs=app.jobs,observations=len(values),captures=captures,painted=painted,syncStages=sync_stages,rssKiB=rss,cpuSeconds=own.ru_utime+own.ru_stime+children.ru_utime+children.ru_stime,helperPeakRssKiB=children.ru_maxrss,storageBytes=size)
    temporary=args.status.with_suffix('.tmp');temporary.write_text(json.dumps(payload));temporary.replace(args.status)
    return True
notebook.GLib.timeout_add(250,snapshot)
loop=notebook.GLib.MainLoop()
def stop():
    snapshot();app.shutdown(app)
    for window in app.get_windows():window.destroy()
    loop.quit();return False
signal.signal(signal.SIGTERM,lambda *_:notebook.GLib.idle_add(stop))
signal.signal(signal.SIGINT,lambda *_:notebook.GLib.idle_add(stop))
try:loop.run()
finally:app.executor.shutdown(wait=True)
