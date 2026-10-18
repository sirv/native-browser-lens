"""Trusted browser runner and a separate filesystem sandbox for edited server code."""
import argparse
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import time


def sandbox(shared_network=False):
    args=['bwrap','--unshare-all','--die-with-parent','--new-session','--clearenv']
    if shared_network:args+=['--share-net']
    for name in ('/usr','/bin','/sbin','/lib','/lib64'):
        if Path(name).exists():args+=['--ro-bind',name,name]
    for name in ('/etc/passwd','/etc/group','/etc/nsswitch.conf','/etc/ld.so.cache','/etc/ld.so.conf','/etc/ld.so.conf.d','/etc/fonts','/etc/ssl/certs','/etc/hosts','/etc/localtime'):
        if Path(name).exists():args+=['--ro-bind',name,name]
    args+=['--proc','/proc','--dev','/dev','--tmpfs','/tmp','--dir','/tmp/home','--setenv','HOME','/tmp/home','--setenv','TMPDIR','/tmp','--setenv','PATH','/usr/local/bin:/usr/bin:/bin','--setenv','LANG','C.UTF-8']
    return args


def runtime_mounts(executables, forbidden=()):
    mounts=set();home=Path.home()
    private=Path(os.environ.get('LENS_DATA_DIR',str(Path(os.environ.get('XDG_DATA_HOME',str(home/'.local/share')))/'native-browser-lens'))).resolve()
    for executable in executables:
        located=shutil.which(executable)
        if not located:continue
        path=Path(located).resolve()
        if str(path).startswith(('/usr/','/bin/','/sbin/')):continue
        parent=path.parent;root=parent.parent if parent.name=='bin' else parent
        if root in (Path('/'),Path('/home'),home,home/'.local',home/'.config') or root==private or root in private.parents:root=path
        if any(root==blocked or root in blocked.parents or blocked in root.parents for blocked in map(lambda value:Path(value).resolve(),forbidden)):
            raise ValueError('A runtime mount overlaps private evidence or the original repository: '+str(root))
        mounts.add(str(root))
    return sorted(mounts)


def invocation(tree, project_relative, git_directory, dependencies, handoff, output, server, phase, port, browser, build, *, repository, base_commit, index):
    tree=Path(tree).resolve();dependencies=Path(dependencies).resolve();git_directory=Path(git_directory).resolve()
    repository=Path(repository).resolve();output=Path(output).resolve()
    server=list(server)
    executable=Path(server[0])
    located=(repository/project_relative/executable).absolute() if '/' in server[0] else Path(shutil.which(server[0]) or repository/project_relative/executable).absolute()
    local=located.is_relative_to(repository)
    server[0]=str(tree/located.relative_to(repository) if local else located.resolve())
    for position,argument in enumerate(server[1:],1):
        option,separator,value=argument.partition('=')
        path=Path(value if separator else argument)
        if path.is_absolute() and path.is_relative_to(repository):server[position]=(option+'=' if separator else '')+str(tree/path.relative_to(repository))
    # Expose source objects and a fresh index, never the user's Git configuration or credentials.
    view=output/'git';view.mkdir(mode=0o700)
    (view/'HEAD').write_text(base_commit+'\n');(view/'config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n')
    (view/'refs').mkdir();(view/'objects').mkdir()
    if Path(index).is_file():shutil.copyfile(index,view/'index')
    args=sandbox()
    python=str(Path(sys.executable).resolve());node=str(Path(shutil.which('node')).resolve())
    mounts=runtime_mounts([python,node,*([server[0]] if not local else [])],(repository,Path(handoff).parent,output))
    search_path=':'.join(dict.fromkeys([str(Path(node).parent),str(Path(python).parent),*([str(Path(server[0]).parent)] if not local else []),*os.environ.get('PATH','/usr/bin:/bin').split(':')]))
    for path in mounts:args+=['--ro-bind',path,path]
    args+=['--bind',str(tree),str(tree),'--ro-bind',str(view),'/lens/git','--ro-bind',str(git_directory/'objects'),'/lens/git/objects']
    args+=['--ro-bind',str(dependencies),'/lens/tools','--ro-bind',str(handoff),'/lens/handoff','--bind',str(output),'/lens/results','--ro-bind',str(Path(__file__).resolve()),'/lens/verify.py']
    browser=Path(browser).resolve()
    if not str(browser).startswith(('/usr/','/bin/')):args+=['--ro-bind',str(browser.parent),str(browser.parent)]
    args+=['--setenv','PATH',search_path,'--chdir',str(Path('/lens/tools')/project_relative),'--',python,'/lens/verify.py','--tree',str(tree),'--project-relative',project_relative,'--runtimes',json.dumps(mounts),'--server',json.dumps(server),'--phase',phase,'--port',str(port),'--browser',str(browser),'--build',build,'--node',node]
    return args


def stop(process):
    process.terminate()
    try:process.wait(timeout=2)
    except subprocess.TimeoutExpired:process.kill();process.wait()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('tree','project-relative','runtimes','server','phase','port','browser','build','node'):parser.add_argument('--'+name,required=True)
    args=parser.parse_args();tree=Path(args.tree);port=int(args.port)
    command=sandbox(shared_network=True)
    for path in json.loads(args.runtimes):command+=['--ro-bind',path,path]
    command+=['--bind',str(tree),str(tree),'--ro-bind',str(tree/'.git'),str(tree/'.git'),'--ro-bind','/lens/git','/lens/git','--chdir',str(tree/args.project_relative),'--setenv','PATH',os.environ['PATH'],'--setenv','PORT',str(port),'--setenv','HOST','127.0.0.1','--setenv','GIT_DIR','/lens/git','--setenv','GIT_WORK_TREE',str(tree),'--setenv','GIT_OPTIONAL_LOCKS','0','--']
    command += [part.replace('{port}',str(port)) for part in json.loads(args.server)]
    with Path('/lens/results/server.log').open('wb') as output:
        process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=output,stderr=output)
        try:
            deadline=time.monotonic()+60
            while True:
                if process.poll() is not None:raise RuntimeError('The isolated server stopped; inspect server.log.')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.2):break
                except OSError:
                    if time.monotonic()>deadline:raise RuntimeError('The isolated local server did not become ready.')
                    time.sleep(.1)
            environment={**os.environ,'LENS_REPRO_ORIGIN':'http://127.0.0.1:'+str(port),'LENS_REPRO_BROWSER':args.browser,'LENS_REPRO_BUILD':args.build,'LENS_REPRO_OUTPUT_DIR':'/lens/results'}
            result=subprocess.run([args.node,'/lens/handoff/reproduce.mjs',args.phase,'--reviewed'],env=environment,timeout=175)
            if result.returncode:raise RuntimeError('The frozen browser check failed. Partial results are retained.')
        finally:stop(process)


if __name__=='__main__':main()
