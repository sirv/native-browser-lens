import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0,str(Path(__file__).parents[1]))
import maintenance


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)/'notebook';self.root.mkdir()
        self.id=str(uuid.uuid4());self.item=dict(id=self.id,projectId='p',createdAt=1,title='Keep this',markdown='Private note',draftRevision=1,editVersion=3,captures=[],findings=[],trashedAt=100)
        with closing(sqlite3.connect(self.root/'notebook.sqlite')) as db,db:
            db.executescript('CREATE TABLE observations(id TEXT PRIMARY KEY,created_at REAL,value BLOB); CREATE TABLE settings(id TEXT PRIMARY KEY,value BLOB);')
            db.execute('INSERT INTO observations VALUES(?,?,?)',(self.id,1,json.dumps(self.item).encode()))
            db.execute('INSERT INTO settings VALUES(?,?)',('projects',b'[]'))
        self.media=self.root/'observations'/self.id;self.media.mkdir(parents=True)
        (self.media/'original.png').write_bytes(b'private original')
        (self.root/'bridge').mkdir();(self.root/'bridge/credential-fixture').write_text('must not leave')

    def tearDown(self):self.temp.cleanup()

    def test_backup_is_consistent_private_verified_and_excludes_app_and_bridge(self):
        backup=maintenance.create_backup(self.root,Path(self.temp.name)/'backups')
        info=maintenance.inspect_backup(backup)
        self.assertEqual(info['observations'],1)
        self.assertEqual((backup/'observations'/self.id/'original.png').read_bytes(),b'private original')
        self.assertFalse((backup/'bridge').exists())
        self.assertEqual(backup.stat().st_mode&0o777,0o700)
        (backup/'observations'/self.id/'original.png').write_bytes(b'tampered')
        with self.assertRaises(ValueError):maintenance.inspect_backup(backup)

    def test_backup_rejects_links_and_restore_manifest_cannot_escape(self):
        (self.media/'linked').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):maintenance.create_backup(self.root,Path(self.temp.name)/'backups')
        (self.media/'linked').unlink()
        backup=maintenance.create_backup(self.root,Path(self.temp.name)/'backups')
        manifest=json.loads((backup/'manifest.json').read_text())
        manifest['files']['../outside']={'size':1,'sha256':'0'*64}
        (backup/'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):maintenance.inspect_backup(backup)

    def test_cleanup_requires_trash_reviewed_version_and_preserves_pending_filing(self):
        (self.media/'submission-r1.json').write_text('{}')
        self.assertTrue(maintenance.cleanup_plan(self.root,older_than=200)['blocked'])
        with self.assertRaises(ValueError):maintenance.delete_trashed(self.root,{self.id:3})
        (self.media/'receipt-r1.json').write_text(json.dumps({'attachmentStatus':'complete'}))
        with self.assertRaises(ValueError):maintenance.delete_trashed(self.root,{self.id:2})
        self.assertTrue((self.media/'original.png').exists())
        self.assertEqual(maintenance.delete_trashed(self.root,{self.id:3}),1)
        with closing(sqlite3.connect(self.root/'notebook.sqlite')) as db:self.assertEqual(db.execute('SELECT count(*) FROM observations').fetchone()[0],0)
        self.assertFalse(self.media.exists())

    def test_restore_failure_preserves_existing_notebook(self):
        backup=maintenance.create_backup(self.root,Path(self.temp.name)/'backups')
        with self.assertRaises((ValueError,OSError)):
            maintenance.restore_backup(self.root,backup,Path('/missing/lens-service'))
        with closing(sqlite3.connect(self.root/'notebook.sqlite')) as db:self.assertEqual(json.loads(db.execute('SELECT value FROM observations').fetchone()[0])['markdown'],'Private note')
        self.assertEqual((self.media/'original.png').read_bytes(),b'private original')

    def test_uncommitted_delete_is_recovered_after_restart(self):
        pending=self.root/('.deleting-'+self.id);self.media.rename(pending)
        maintenance.recover(self.root)
        self.assertTrue((self.media/'original.png').exists())
        self.assertFalse(pending.exists())

    def test_retention_preserves_active_notes_and_protected_filings(self):
        active={**self.item,'id':str(uuid.uuid4()),'trashedAt':None}
        with closing(sqlite3.connect(self.root/'notebook.sqlite')) as db,db:db.execute('INSERT INTO observations VALUES(?,?,?)',(active['id'],1,json.dumps(active).encode()))
        self.assertEqual(maintenance.apply_retention(self.root,days=1)['deleted'],1)
        self.assertEqual([item['id'] for item in maintenance.records(self.root)],[active['id']])
        with self.assertRaises(ValueError):maintenance.apply_retention(self.root,days=-1)
