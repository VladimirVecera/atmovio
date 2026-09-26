"""Offline checks for fixed-length source clips and device-local OD–DO corrections."""
import os, sys, tempfile, shutil, json, copy, datetime as dt, re
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo
base=Path(tempfile.mkdtemp(prefix='atmovio-range-test-'))
os.environ['ATMOVIO_DIR']=str(base);os.environ['ATMOVIO_ADMIN_PASSWORD']='range-fixture-password'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'/'atmovio'))
import app as a
from fastapi.testclient import TestClient
checks=[]
try:
 a.db_init();cfg=a.load_config()
 cfg.update(snapshot_dir=str(base/'snapshots'),recordings_path=str(base/'recordings'),frigate_config_path=str(base/'frigate.yml'))
 Path(cfg['snapshot_dir']).mkdir();Path(cfg['recordings_path']).mkdir()
 cfg['ai']['auto_export'].update(enabled=True,cameras=['camera'],length_mode='fixed',duration_min=120,before_min=2,after_min=60,playback='timelapse_25x')
 a.save_config(cfg);a.frigate_write_yaml(cfg,{'cameras':{'camera':{}}})
 now=dt.datetime(2026,9,26,12,0,tzinfo=ZoneInfo(cfg['tz']))
 evidence={'ts':now.isoformat(),'camera':'camera','score':8,'description':'Fixture','phenomena':['cervanky']}
 rid=a.watcher.record(evidence)
 def jobs():
  with a.db() as con:return [dict(r) for r in con.execute('SELECT * FROM auto_exports ORDER BY id')]
 with patch.object(a.time,'time',return_value=now.timestamp()),patch.object(a,'storage_ready',return_value=True),patch.object(a,'run',return_value=(1,'')),patch('requests.sessions.Session.request',side_effect=RuntimeError('External HTTP disabled')):
  a.schedule_auto_export(cfg,rid,'camera',now,'Červánky')
  assert jobs()[-1]['end_ts']-jobs()[-1]['start_ts']==7200 and jobs()[-1]['playback']=='timelapse_25x'
  with a.db() as con:con.execute('DELETE FROM auto_exports')
  film={'mode':'batch','film_id':1,'start':now.timestamp()-3600,'end':now.timestamp(),'event_start':now.timestamp()-600,'event_end':now.timestamp(),'sample_min':5,'duration_min':60,'frames':13,'ongoing':True}
  evidence['film_context']=json.dumps(film)
  a.schedule_film_export(cfg,evidence,['cervanky']);first=jobs()[0]
  assert first['start_ts']==now.timestamp()-720 and first['end_ts']-first['start_ts']==7200 and not first['film_open']
  next_e=dict(evidence,id=rid+1);next_f=dict(film,film_id=2,event_start=now.timestamp(),event_end=now.timestamp()+3600,start=now.timestamp(),end=now.timestamp()+3600)
  next_e['film_context']=json.dumps(next_f)
  a.schedule_film_export(cfg,next_e,['cervanky']);assert len(jobs())==1
  next_f.update(event_start=now.timestamp()+3600,event_end=now.timestamp()+7200,end=now.timestamp()+7200)
  next_e.update(id=rid+2,film_context=json.dumps(next_f));a.schedule_film_export(cfg,next_e,['cervanky'])
  assert len(jobs())==2 and jobs()[1]['start_ts']==first['end_ts'] and jobs()[1]['end_ts']-jobs()[1]['start_ts']==7200
  checks.append('Fixed 120-minute range includes before-margin, ignores after-margin, works for both AI modes and timelapse, and splits continuing events without overlap')
  assert a.exact_clip_bounds(cfg,'2026-09-25T23:30','2026-09-26T01:30')[1]-a.exact_clip_bounds(cfg,'2026-09-25T23:30','2026-09-26T01:30')[0]==7200
  assert a.exact_clip_bounds(cfg,'2026-03-29T01:30','2026-03-29T03:30')[1]-a.exact_clip_bounds(cfg,'2026-03-29T01:30','2026-03-29T03:30')[0]==3600
  for values in [('', '2026-09-26T10:00'),('wrong','wrong'),('2026-09-26T10:00','2026-09-26T09:00'),('2026-09-26T09:00','2026-09-26T11:01'),('2026-03-29T02:30','2026-03-29T03:30'),('2026-09-27T10:00','2026-09-27T11:00'),('2025-10-26T02:15','2025-10-26T03:15')]:
   try:a.exact_clip_bounds(cfg,*values);raise AssertionError(values)
   except ValueError:pass
  checks.append('Device timezone, midnight and DST; reject absent/reversed/overlong/nonexistent/future-start ranges')
  client=TestClient(a.app,raise_server_exceptions=True)
  token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
  client.post('/login',data={'csrf_token':token,'password':'range-fixture-password'})
  token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/videos/settings').text)[1]
  form={'csrf_token':token,'ax_enabled':'1','ax_cam_camera':'1','ax_before':'2','ax_after':'3','ax_length_mode':'fixed','ax_duration':'120','days':'30'}
  client.post('/videos/settings',data=form)
  assert a.load_config()['ai']['auto_export']['duration_min']==120
  saved=a.load_config();client.post('/videos/settings',data=dict(form,ax_duration='121'));assert a.load_config()==saved
  client.post('/videos/settings',data=dict(form,ax_duration='not-a-number'));assert a.load_config()==saved
  client.post('/videos/settings',data=dict(form,ax_duration='2',ax_before='2'));assert a.load_config()==saved
  assert a.configured_clip_before({'length_mode':'fixed','duration_min':1},3600)==0
  checks.append('Video settings save fixed duration and reject invalid values without partially changing configuration')
  with patch.object(a,'recording_state',return_value='ok'),patch.object(a,'list_videos',return_value=[]),patch.object(a,'camera_info',return_value={'ip':'','via':''}),patch.object(a,'frigate_start_export',return_value='range-export') as export:
   url=f'/detection/{rid}'
   params={'from_time':'2026-09-26T09:00','to_time':'2026-09-26T11:00'}
   page=client.get(url,params=params);assert page.status_code==200 and '2026-09-26T09:00:00' in page.text
   assert client.post(url+'/export',data=params).status_code==403
   r=client.post(url+'/export',data=dict(params,csrf_token=token),follow_redirects=False);assert r.status_code==303
   bounds=a.exact_clip_bounds(cfg,**params);assert export.call_args.args[2:4]==bounds
   with a.db() as con:originals=con.execute('SELECT COUNT(*) FROM exports').fetchone()[0]
   client.post(url+'/export',data=dict(params,csrf_token=token,to_time='2026-09-26T09:30'),follow_redirects=False)
   with a.db() as con:assert con.execute('SELECT COUNT(*) FROM exports').fetchone()[0]==originals+1
   calls=export.call_count
   for bad in [dict(params,to_time='2026-09-26T08:00'),dict(params,to_time=''),dict(params,to_time='2026-09-26T11:01')]:
    client.post(url+'/export',data=dict(bad,csrf_token=token));assert export.call_count==calls
   planned=client.post(url+'/export',data={'csrf_token':token,'from_time':'2026-09-26T11:30','to_time':'2026-09-26T13:30'},follow_redirects=False)
   assert planned.status_code==303 and export.call_count==calls and jobs()[-1]['end_ts']==a.clip_time(cfg,'2026-09-26T13:30')
   assert jobs()[-1]['due_ts']==jobs()[-1]['end_ts']+45 and jobs()[-1]['ai_context']
   checks.append('Authenticated preview/export use exact OD–DO; correction creates a new clip; invalid requests never export; future end is queued with evidence')
 print(json.dumps({'version':a.APP_VERSION,'checks':checks},indent=2,ensure_ascii=False))
finally:shutil.rmtree(base,ignore_errors=True)
