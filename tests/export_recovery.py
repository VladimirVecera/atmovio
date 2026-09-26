"""Offline outage recovery must retain exact ranges and visible file creation state."""
import os, sys, tempfile, shutil, json
from pathlib import Path
from unittest.mock import patch
base=Path(tempfile.mkdtemp(prefix='atmovio-recovery-'))
os.environ['ATMOVIO_DIR']=str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD']='isolated-recovery-fixture'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
try:
 a.db_init();cfg=a.load_config();now=a.time.time()
 with a.db() as con:
  con.execute("INSERT INTO auto_exports(detection_id,camera,name,start_ts,end_ts,due_ts,created) VALUES(1,'fixture','Recovery',?,?,?,datetime('now'))",(now-18000,now-7200,now-7100))
  job=dict(con.execute('SELECT * FROM auto_exports').fetchone())
  con.execute("INSERT INTO event_parts(job_id,start_ts,end_ts) VALUES(?,?,?)",(job['id'],now-18000,now-14400))
 with patch.object(a,'recording_state',return_value='offline'),patch.object(a,'list_videos',return_value=[]):
  a.process_auto_exports(cfg);a.process_event_parts(cfg)
 with a.db() as con:
  j=dict(con.execute('SELECT * FROM auto_exports').fetchone());part=dict(con.execute('SELECT * FROM event_parts').fetchone())
 assert j['status']=='pending' and part['status']=='pending'
 assert (j['start_ts'],j['end_ts'])==(job['start_ts'],job['end_ts'])
 assert 'Frigate' in a.pending_auto_exports(cfg)[0]['part_error']
 # Upgrade requeues only legacy connectivity failures, idempotently.
 with a.db() as con:
  con.execute("UPDATE auto_exports SET status='failed',message='Frigate neodpovídal 15 minut po detekci'")
  con.execute("UPDATE event_parts SET status='failed',error='Frigate neodpovídá.'")
 a.db_init();a.db_init()
 with a.db() as con:
  assert con.execute('SELECT status FROM auto_exports').fetchone()[0]=='pending'
  assert con.execute('SELECT status FROM event_parts').fetchone()[0]=='pending'
 with patch.object(a,'recording_state',return_value='ok'),patch.object(a,'frigate_start_export',side_effect=['full-file','part-file']) as start,patch.object(a,'list_videos',return_value=[]):
  a.process_auto_exports(cfg);a.process_event_parts(cfg)
  assert start.call_count==2
  assert start.call_args_list[0].args[2:4]==(job['start_ts'],job['end_ts'])
  a.process_auto_exports(cfg);a.process_event_parts(cfg)
  assert start.call_count==2
 v=dict(id=1,name='Recovery',auto=1,detection_id=1,ready=False,expired=False,stuck=False)
 assert a.preparing_video_exports([v])[0]['video_status']['active']
 v['ready']=True;assert not a.preparing_video_exports([v])
 v.update(ready=False,stuck=True)
 assert a.preparing_video_exports([v])[0]['video_status']['tone']=='failed'
 for code in (401,403,404,500,502):
  class Response:
   ok=False;status_code=code
  with patch.object(a,'frigate_api',return_value=Response()):assert a.recording_state(cfg,'fixture',1,2)=='offline'
 print('PASS: old ranges survive outages, legacy failures recover once, export not duplicated, preparation remains visible until ready, HTTP errors never claim missing recordings')
finally:shutil.rmtree(base)
