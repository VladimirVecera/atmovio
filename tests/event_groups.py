"""Explicit event grouping and safe cascading deletion, without real media/network."""
import os, sys, tempfile, shutil
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
base=Path(tempfile.mkdtemp(prefix='atmovio-groups-'))
os.environ['ATMOVIO_DIR']=str(base);os.environ['ATMOVIO_ADMIN_PASSWORD']='isolated-event-groups'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
try:
 a.db_init();cfg=a.load_config()
 with a.db() as con:
  con.execute("INSERT INTO auto_exports(detection_id,camera,name,start_ts,end_ts,due_ts,created,status,message) VALUES(1,'camera','Event',100,200,201,datetime('now'),'done','main')")
 main=a.record_export(cfg,'main',1,'camera','Event',100,200,auto=1)
 part=a.record_export(cfg,'part',1,'camera','Part',100,150)
 other=a.record_export(cfg,'other',1,'camera','Unrelated',100,200)
 with a.db() as con:con.execute('UPDATE exports SET event_parent_id=1 WHERE id=?',(part,))
 a.db_init()
 with a.db() as con:rows=[dict(r) for r in con.execute('SELECT * FROM exports')]
 groups=a.group_event_videos(rows)
 assert len(groups)==1 and groups[1]['main']['id']==main and [v['id'] for v in groups[1]['parts']]==[part]
 assert groups[1]['main']['parts_count']==1
 assert a.group_event_videos([r for r in rows if r['id']!=main])[1]['main'] is None
 parent=groups[1]['main']
 # Preflight protects the entire group if any child is being used.
 with a.db() as con:
  con.execute("INSERT INTO studio_videos(export_id,camera,name,speed,intro,music,created,status) VALUES(?,'camera','Busy',25,0,'',datetime('now'),'rendering')",(part,))
 with patch.object(a.requests,'delete') as delete:
  assert not a.delete_export(cfg,parent);delete.assert_not_called()
 with a.db() as con:con.execute('DELETE FROM studio_videos')
 # API failures must retain group records so deletion can be retried.
 with patch.object(a.requests,'delete',return_value=SimpleNamespace(ok=False,status_code=503)):
  assert not a.delete_export(cfg,parent)
 with a.db() as con:assert con.execute('SELECT COUNT(*) FROM exports').fetchone()[0]==3
 with patch.object(a.requests,'delete',return_value=SimpleNamespace(ok=True,status_code=200)) as delete:
  assert a.delete_export(cfg,parent) and delete.call_count==2
 with a.db() as con:assert [r[0] for r in con.execute('SELECT id FROM exports')]==[other]
 print('PASS: migrated main association, grouped parts, orphan group visibility, unrelated clips preserved, group-wide busy check, failed deletion retry, cascade deletion')
finally:shutil.rmtree(base)
