"""Protect event parts before closure; notify only after a real saved file is confirmed."""
import os, sys, tempfile, shutil, json, datetime as dt, io
from pathlib import Path
from unittest.mock import patch
from PIL import Image
from zoneinfo import ZoneInfo
base=Path(tempfile.mkdtemp(prefix='atmovio-event-delivery-'))
os.environ['ATMOVIO_DIR']=str(base);os.environ['ATMOVIO_ADMIN_PASSWORD']='event-fixture-password'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
try:
 a.db_init();cfg=a.load_config();cfg['snapshot_dir']=str(base/'snapshots');Path(cfg['snapshot_dir']).mkdir()
 cfg['ai']['auto_export'].update(enabled=True,cameras=['west'],length_mode='event',before_min=2,after_min=3)
 start=1800950400.;clock=[start+3600];videos=[]
 def evidence(end, index):
  r=dict(camera='west',ts=dt.datetime.fromtimestamp(end,ZoneInfo(cfg['tz'])).isoformat(),description='Fixture clouds',score=8,phenomena=['cervanky'])
  r['film_context']=json.dumps(dict(mode='batch',film_id=index,start=end-3600,end=end,event_start=end-3600,event_end=end,frames=13,sample_min=5,duration_min=60,ongoing=True))
  a.watcher.record(r);return r
 with patch.object(a.time,'time',side_effect=lambda:clock[0]),patch.object(a,'recording_state',return_value='ok'),patch.object(a,'public_urls',return_value={'atmovio':'http://fixture.local','frigate':''}),patch.object(a,'list_videos',side_effect=lambda *args,**kwargs:videos),patch.object(a,'frigate_start_export',return_value='fixture-export'),patch.object(a,'deliver',return_value='fixture-mail') as mail:
  first=evidence(clock[0],1);a.schedule_film_export(cfg,first,['cervanky'])
  with a.db() as con:parts=[dict(r) for r in con.execute('SELECT * FROM event_parts')]
  assert len(parts)==1 and parts[0]['start_ts']==start-120 and parts[0]['end_ts']==start+3600
  a.queue_video_notification(first['id'],dict(subject='Fixture',body='Clouds',image='none.jpg',score=8,phenomena=['cervanky'],ts=first['ts']))
  a.process_video_notifications(cfg);mail.assert_not_called()
  clock[0]+=46;a.process_event_parts(cfg)
  with a.db() as con:ex=dict(con.execute('SELECT * FROM exports').fetchone())
  assert ex['auto']==0 and ex['event_parent_id']==1
  videos.append(dict(ex,ready=False,in_progress=True,expired=False,stuck=False,range_h='10:00–11:00'))
  a.process_video_notifications(cfg);mail.assert_not_called()
  videos[0].update(ready=True,in_progress=False)
  a.process_event_parts(cfg);a.process_video_notifications(cfg)
  assert mail.call_count==1 and mail.call_args.kwargs['link']==f"http://fixture.local/recording/{ex['id']}"
  assert 'video připravené' in mail.call_args.args[1]
  a.process_video_notifications(cfg);assert mail.call_count==1
  # Three observed hours stay in one full-event job, while parts are contiguous and immutable.
  for n in [2,3]:
   clock[0]=start+n*3600
   r=evidence(clock[0],n);a.schedule_film_export(cfg,r,['cervanky'])
  with a.db() as con:
   parts=[dict(r) for r in con.execute('SELECT * FROM event_parts ORDER BY id')]
   jobs=[dict(r) for r in con.execute('SELECT * FROM auto_exports')]
  assert len(jobs)==1 and jobs[0]['film_open'] and jobs[0]['end_ts']-jobs[0]['start_ts']>3*3600
  assert len(parts)==3 and all(parts[i]['end_ts']==parts[i+1]['start_ts'] for i in range(2))
  # A fresh alert in the third film must not point to the already saved first hour.
  a.queue_video_notification(r['id'],dict(subject='Later event',body='Later clouds',image='none.jpg',score=8,phenomena=['cervanky'],ts=r['ts']))
  a.process_video_notifications(cfg);assert mail.call_count==1
  videos.append(dict(videos[0],id=999,start_ts=start+7200,end_ts=start+10800,range_h='12:00–13:00'))
  a.process_video_notifications(cfg)
  assert mail.call_count==2 and mail.call_args.kwargs['link']=='http://fixture.local/recording/999'
  a.db_init();a.queue_event_part(jobs[0])
  with a.db() as con:assert con.execute('SELECT COUNT(*) FROM event_parts').fetchone()[0]==3
  state=a.detection_video_statuses(cfg,[first])[first['id']]
  assert 'část' in state['title'] and state['active']
 # Actual notification branch queues before delivery, including ordinary single-image mode.
 cfg['ai'].update(prefilter=False,skip_dark=False,threshold=7,phenomena=['cervanky'],any=True)
 cfg['ai']['strip']['enabled']=False
 now=dt.datetime.now(ZoneInfo(cfg['tz']))
 img=io.BytesIO();Image.new('RGB',(320,180),'white').save(img,'JPEG')
 with patch.object(a,'fetch_snapshot',return_value=img.getvalue()),patch.object(a,'ai_evaluate',return_value=({'score':8,'phenomena':['cervanky'],'description':'Fixture','phenomenon':'Červánky'},'{}')),patch.object(a,'camera_info',return_value={'ip':'','via':''}),patch.object(a,'public_urls',return_value={'atmovio':'http://fixture.local','frigate':''}),patch.object(a,'deliver') as mail:
  w=a.AtmovioWatcher();w.last_notify["west"]=0;result=w._check_camera(cfg,'west',now)
  mail.assert_not_called()
  with a.db() as con:assert con.execute('SELECT status FROM video_notifications WHERE detection_id=?',(result['id'],)).fetchone()[0]=='pending'
  assert result['notified']==0
 print('PASS: no notification before playable export, one delivery with direct clip link, three-hour continuous event with contiguous safety parts, restart idempotency, no automatic Studio trigger, actual deferred detection branch')
finally:shutil.rmtree(base)
