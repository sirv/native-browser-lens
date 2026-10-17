"""Private notebook backups and reviewed cleanup using SQLite's online backup API."""
import hashlib
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid


def write_json(path,value):
    temporary=path.with_name(path.name+'.tmp')
    with temporary.open('w') as output:
        os.chmod(temporary,0o600);json.dump(value,output,ensure_ascii=False)
        output.flush();os.fsync(output.fileno())
    temporary.replace(path)


def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as source:
        while chunk:=source.read(1024*1024):value.update(chunk)
    return value.hexdigest()


def copy_database(source,destination):
    with closing(sqlite3.connect(f'{source.as_uri()}?mode=ro',uri=True)) as src,closing(sqlite3.connect(destination)) as dst:
        src.backup(dst)
        dst.execute('PRAGMA journal_mode=DELETE')
    os.chmod(destination,0o600)


def records(root):
    with closing(sqlite3.connect(f'{(root/"notebook.sqlite").as_uri()}?mode=ro',uri=True)) as db:
        return [json.loads(row[0]) for row in db.execute('SELECT value FROM observations')]


def regular_files(directory):
    if directory.is_symlink():raise ValueError('Notebook backups cannot contain symbolic links.')
    for path in directory.rglob('*'):
        if path.is_symlink():raise ValueError('Notebook backups cannot contain symbolic links.')
        if path.is_file():yield path
        elif not path.is_dir():raise ValueError('Notebook contains an unsupported special file.')


def observation_id(value):
    uuid.UUID(value)
    if '/' in value or '\\' in value:raise ValueError('Invalid observation identity.')
    return value


def create_backup(root,destination):
    root=Path(root).resolve();destination=Path(destination).resolve()
    if destination.is_relative_to(root/'observations'):raise ValueError('Choose a backup folder outside observation media.')
    destination.mkdir(parents=True,exist_ok=True,mode=0o700)
    final=destination/('lens-backup-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8])
    staging=Path(tempfile.mkdtemp(prefix='.lens-backup-',dir=destination))
    try:
        copy_database(root/'notebook.sqlite',staging/'notebook.sqlite')
        items=records(staging)
        if (root/'observations').is_symlink():raise ValueError('Notebook backups cannot contain symbolic links.')
        for item in items:
            source=root/'observations'/observation_id(item['id'])
            if source.exists():
                for path in regular_files(source):
                    target=staging/path.relative_to(root);target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
                    shutil.copyfile(path,target);target.chmod(0o600)
        files={str(p.relative_to(staging)):{'size':p.stat().st_size,'sha256':digest(p)} for p in regular_files(staging)}
        write_json(staging/'manifest.json',dict(formatVersion=1,originalRoot=str(root),createdAt=time.time()*1000,observations=len(items),files=files))
        staging.rename(final)
        return final
    finally:
        if staging.exists():shutil.rmtree(staging)


def inspect_backup(folder):
    folder=Path(folder).resolve()
    manifest_path=folder/'manifest.json'
    if manifest_path.is_symlink() or manifest_path.stat().st_size>16*1024*1024:raise ValueError('Invalid notebook backup manifest.')
    info=json.loads(manifest_path.read_text())
    if info.get('formatVersion')!=1 or not isinstance(info.get('files'),dict) or len(info['files'])>100_000:raise ValueError('Unsupported notebook backup.')
    if 'notebook.sqlite' not in info['files']:raise ValueError('The backup has no notebook database.')
    actual={str(p.relative_to(folder)) for p in regular_files(folder)}-{'manifest.json'}
    if actual!=set(info['files']):raise ValueError('The backup file list has changed.')
    for name,metadata in info['files'].items():
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts or '\\' in name or (name!='notebook.sqlite' and (len(relative.parts)<3 or relative.parts[0]!='observations')):raise ValueError('A backup path leaves its notebook.')
        if name!='notebook.sqlite':observation_id(relative.parts[1])
        path=folder/relative
        if path.stat().st_size!=metadata.get('size') or digest(path)!=metadata.get('sha256'):raise ValueError('A notebook backup file failed its checksum: '+name)
    with closing(sqlite3.connect(f'{(folder/"notebook.sqlite").as_uri()}?mode=ro',uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('The backup database is damaged.')
    if len(records(folder))!=info.get('observations'):raise ValueError('The backup observation count does not match.')
    return info


def pending_filing(directory):
    for attempt in directory.glob('submission-r*.json'):
        receipt=directory/attempt.name.replace('submission-','receipt-',1)
        try:
            if json.loads(receipt.read_text()).get('attachmentStatus')!='complete':return True
        except (OSError,ValueError):return True
    return False


def cleanup_plan(root,older_than=None):
    root=Path(root).resolve();items=[];blocked=[]
    for item in records(root):
        if item.get('trashedAt') is None or (older_than is not None and item['trashedAt']>older_than):continue
        directory=root/'observations'/observation_id(item['id'])
        entry=dict(id=item['id'],title=item['title'],editVersion=item['editVersion'],trashedAt=item['trashedAt'],bytes=sum(p.stat().st_size for p in regular_files(directory)) if directory.exists() else 0)
        (blocked if pending_filing(directory) else items).append(entry)
    return dict(items=items,blocked=blocked,bytes=sum(item['bytes'] for item in items))


def delete_trashed(root,versions):
    root=Path(root).resolve();moved=[]
    try:
        with closing(sqlite3.connect(root/'notebook.sqlite')) as db,db:
            db.execute('BEGIN IMMEDIATE')
            for identity,version in versions.items():
                observation_id(identity)
                row=db.execute('SELECT value FROM observations WHERE id=?',(identity,)).fetchone()
                item=json.loads(row[0]) if row else {}
                source=root/'observations'/identity;target=root/('.deleting-'+identity)
                if item.get('trashedAt') is None or item.get('editVersion')!=version:raise ValueError('The Trash selection changed. Review it again.')
                if pending_filing(source):raise ValueError('A discarded observation still has an unresolved filing. Recover its receipt first.')
                if source.exists():
                    list(regular_files(source))
                    if target.exists():raise ValueError('Restart Lens to recover an interrupted cleanup.')
                    source.rename(target);moved.append((source,target))
                db.execute('DELETE FROM observations WHERE id=?',(identity,))
        for _,target in moved:shutil.rmtree(target)
        return len(versions)
    except Exception:
        for source,target in moved:
            if target.exists() and not source.exists():target.rename(source)
        raise


def recover(root):
    root=Path(root).resolve()
    journal=root/'restore-journal.json'
    if journal.exists():
        state=json.loads(journal.read_text());old=root/state['oldMedia']
        if old.parent!=root or not old.name.startswith('.restore-old-'):raise ValueError('Invalid restore recovery path.')
        if state.get('committed'):
            if old.exists():shutil.rmtree(old)
        else:
            backup=Path(state['backup']);inspect_backup(backup)
            copy_database(backup/'notebook.sqlite',root/'notebook.sqlite')
            if old.exists():
                if (root/'observations').exists():shutil.rmtree(root/'observations')
                old.rename(root/'observations')
            elif not state.get('hadMedia',True) and (root/'observations').exists():shutil.rmtree(root/'observations')
        journal.unlink()
    if (root/'notebook.sqlite').exists():
        identities={item['id'] for item in records(root)}
        for path in root.glob('.deleting-*'):
            identity=observation_id(path.name.removeprefix('.deleting-'))
            target=root/'observations'/identity
            if identity in identities:
                if target.exists():raise ValueError('Cleanup recovery found two media folders; preserve both and inspect them.')
                path.rename(target)
            else:shutil.rmtree(path)


def restore_backup(root,folder,service):
    root=Path(root).resolve();folder=Path(folder).resolve();info=inspect_backup(folder)
    if folder.is_relative_to(root/'observations'):raise ValueError('Restore from a backup outside current observation media.')
    staging=Path(tempfile.mkdtemp(prefix='.lens-restore-',dir=root.parent))
    journal=root/'restore-journal.json'
    try:
        for name in info['files']:
            target=staging/name;target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            shutil.copyfile(folder/name,target);target.chmod(0o600)
        result=subprocess.run([str(service)],input=json.dumps(dict(action='rebaseBackup',oldRoot=info['originalRoot'],newRoot=str(root))),text=True,capture_output=True,timeout=120,env={**os.environ,'LENS_DATA_DIR':str(staging)})
        response=json.loads(result.stdout)
        if result.returncode or 'error' in response:raise ValueError(response.get('error','The backup could not be restored.'))
        safety=create_backup(root,root/'backups')
        old=root/('.restore-old-'+uuid.uuid4().hex)
        state=dict(backup=str(safety),oldMedia=old.name,committed=False,hadMedia=(root/'observations').exists())
        write_json(journal,state)
        try:
            if (root/'observations').exists():(root/'observations').rename(old)
            (staging/'observations').mkdir(exist_ok=True)
            (staging/'observations').rename(root/'observations')
            copy_database(staging/'notebook.sqlite',root/'notebook.sqlite')
            state['committed']=True;write_json(journal,state)
        except Exception:
            recover(root);raise
        recover(root)
        return dict(restored=info['observations'],safetyBackup=str(safety))
    finally:shutil.rmtree(staging)


def storage_usage(root):
    root=Path(root).resolve();items=records(root)
    media=root/'observations'
    return dict(observations=len(items),archived=sum(item.get('archivedAt') is not None for item in items),trashed=sum(item.get('trashedAt') is not None for item in items),bytes=sum(p.stat().st_size for p in regular_files(media)) if media.exists() else 0)


def apply_retention(root,days=0,max_mib=0):
    if not 0<=days<=3650 or not 0<=max_mib<=1_048_576:raise ValueError('Invalid Trash retention limits.')
    selected={}
    plan=cleanup_plan(root)
    remaining=sum(item['bytes'] for item in plan['items']+plan['blocked'])
    cutoff=time.time()*1000-days*86_400_000
    for item in sorted(plan['items'],key=lambda item:item['trashedAt']):
        if (days and item['trashedAt']<=cutoff) or (max_mib and remaining>max_mib*1024*1024):
            selected[item['id']]=item['editVersion'];remaining-=item['bytes']
    count=delete_trashed(root,selected) if selected else 0
    return dict(deleted=count,blocked=len(plan['blocked']),remainingBytes=remaining)
