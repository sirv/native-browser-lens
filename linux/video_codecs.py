"""Choose the installed H.264 provider without requiring a third-party package repository."""
import subprocess


def encoder():
    try:listing=subprocess.run(['ffmpeg','-v','error','-encoders'],capture_output=True,text=True,timeout=10).stdout
    except (OSError,subprocess.SubprocessError):return ''
    return next((name for name in ('libx264','libopenh264') if name in listing.split()),'')


def decoder():
    for name in ('avdec_h264','openh264dec'):
        try:
            plugins=(name,'h264parse') if name=='openh264dec' else (name,)
            if all(subprocess.run(['gst-inspect-1.0',plugin],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10).returncode==0 for plugin in plugins):return name
        except (OSError,subprocess.SubprocessError):return ''
    return ''


def arguments(name):
    if name not in ('libx264','libopenh264'):raise ValueError('Install FFmpeg with libx264 or libopenh264 to save recordings.')
    options=['-preset','veryfast','-crf','24'] if name=='libx264' else ['-b:v','1500k']
    return ['-c:v',name,*options,'-profile:v','baseline' if name=='libx264' else 'constrained_baseline','-maxrate','2M','-bufsize','4M']
