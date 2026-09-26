"""Offline checks for manual recordings, source sampling and editable Studio handoff."""
import os, sys, tempfile, shutil, json, re, time, io
from pathlib import Path
from unittest.mock import patch, Mock
from PIL import Image
base=Path(tempfile.mkdtemp(prefix='atmovio-recording-test-'))
os.environ['ATMOVIO_DIR']=str(base);os.environ['ATMOVIO_ADMIN_PASSWORD']='recording-fixture-password'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
from fastapi.testclient import TestClient
try:
 a.db_init();cfg=a.load_config();cfg.update(snapshot_dir=str(base/'snapshots'),recordings_path=str(base/'recordings'),frigate_config_path=str(base/'frigate.yml'))
 a.save_config(cfg);source=base/'source.mp4';source.write_bytes(b'fixture')
 client=TestClient(a.app)
 assert client.get('/camera/west/recording',follow_redirects=False).status_code==303
 with patch.object(a,'frigate_cameras',return_value=['west']),patch.object(a,'run',return_value=(1,'')),patch.object(a,'storage_ready',return_value=True),patch.object(a,'recording_state',return_value='ok'),patch.object(a,'frigate_start_export',return_value='fixture-id') as start_export,patch('requests.sessions.Session.request',side_effect=RuntimeError('External HTTP disabled')):
  token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
  client.post('/login',data={'csrf_token':token,'password':'recording-fixture-password'})
  page=client.get('/camera/west/recording');assert page.status_code==200
  token=re.search(r'name="csrf_token" value="([^"]+)"',page.text)[1]
  end=time.time()-60;start=end-5400
  form=dict(from_time=a.clip_local(cfg,start),to_time=a.clip_local(cfg,end),metadata='1',csrf_token=token)
  assert client.post('/camera/west/recording',data={k:v for k,v in form.items() if k!='csrf_token'}).status_code==403
  assert client.get('/camera/west/recording',params=form).status_code==200
  response=client.post('/camera/west/recording',data=form,follow_redirects=False)
  assert response.status_code==303 and response.headers['location'].startswith('/recording/')
  eid=int(response.headers['location'].split('/')[-1]);ex=a._studio_export(cfg,eid)
  assert ex['metadata_status']=='queued' and ex['detection_id'] is None
  assert start_export.call_args.args[-1]=='realtime'
  calls=start_export.call_count
  for changes in [dict(to_time=form['from_time']),dict(to_time=a.clip_local(cfg,end+86400)),dict(from_time=a.clip_local(cfg,end-7300)),dict(from_time='invalid')]:
   client.post('/camera/west/recording',data=dict(form,**changes),follow_redirects=False)
  assert start_export.call_count==calls
  # Render all preparation states without contacting any recorder.
  for ready,status in [(False,'queued'),(True,'working'),(True,'ready'),(True,'failed')]:
   video=dict(ex,ready=ready,in_progress=not ready,stuck=False,expired=False,range_h='12:00–13:30',duration_h='1 h 30 min',metadata_status=status,metadata_error='Fixture error')
   with patch.object(a,'list_videos',return_value=[video]):assert client.get(f'/recording/{eid}').status_code==200
  commands=[]
  def ffmpeg(cmd,**kwargs):
   commands.append(cmd);assert cmd[cmd.index('-i')+1]==str(source)
   Image.new('RGB',(720,405),(len(commands)*20,80,120)).save(cmd[-1]);return 0,''
  def evaluate(ai, image_bytes, strip):
   assert strip==9 and Image.open(io.BytesIO(image_bytes)).size==(2160,1305)
   return dict(score=7,description='Oblačnost se proměňuje.',evolution='Mraky se posouvají.',phenomenon='Oblačnost'), '{}'
  with patch.object(a,'ffprobe_info',return_value={'duration':90}),patch.object(a,'run',side_effect=ffmpeg),patch.object(a,'ai_evaluate',side_effect=evaluate),patch.object(a,'studio_metadata',return_value={'title':'Návrh z videa','description':'Popis z videa'}):
   context,proposal=a.recording_metadata_generate(cfg,ex,source)
  assert len(commands)==9 and all(0<float(c[c.index('-ss')+1])<90 for c in commands)
  assert context['source']=='recording_samples'
  # Background queue stores result; polling waits only in this bounded offline test.
  with patch.object(a,'frigate_exports',return_value={'fixture-id':{'video_path':str(source),'in_progress':False}}),patch.object(a,'frigate_media_path',return_value=source),patch.object(a,'recording_metadata_generate',return_value=(context,proposal)):
   a.recording_metadata_kick(cfg)
   assert a._recording_metadata_lock.acquire(timeout=3);a._recording_metadata_lock.release()
  saved=a._studio_export(cfg,eid);assert saved['metadata_status']=='ready'
  with patch.object(a,'frigate_exports',return_value={}),patch.object(a,'studio_music_files',return_value=[]):
   studio=client.get(f'/studio/new/{eid}');assert studio.status_code==200 and 'Návrh z videa' in studio.text and 'Popis z videa' in studio.text
  assert client.post(f'/recording/{eid}/text',data={'title':'Ručně upravený nadpis'}).status_code==403
  client.post(f'/recording/{eid}/text',data={'csrf_token':token,'title':'Ručně upravený nadpis','description':'Upravený popis AI videa'},follow_redirects=False)
  assert json.loads(a._studio_export(cfg,eid)['metadata_json'])['title']=='Ručně upravený nadpis'
  with patch.object(a,'frigate_exports',return_value={}):
   assert a.list_videos(cfg,thumbnails=False)[0]['metadata_description']=='Upravený popis AI videa'
  with a.db() as con:con.execute("UPDATE exports SET metadata_status='working' WHERE id=?",(eid,))
  client.post(f'/recording/{eid}/text',data={'csrf_token':token,'title':'Nesmí přepsat běžící úlohu'},follow_redirects=False)
  assert json.loads(a._studio_export(cfg,eid)['metadata_json'])['title']=='Ručně upravený nadpis' 
  a.db_init();assert a._studio_export(cfg,eid)['metadata_status']=='failed'
  client.post(f'/recording/{eid}/metadata',data={'csrf_token':token},follow_redirects=False)
  with patch.object(a,'frigate_exports',return_value={'fixture-id':{'video_path':str(source),'in_progress':False}}),patch.object(a,'frigate_media_path',return_value=source),patch.object(a,'recording_metadata_generate',side_effect=RuntimeError('AI unavailable')):
   a.recording_metadata_kick(cfg)
   assert a._recording_metadata_lock.acquire(timeout=3);a._recording_metadata_lock.release()
  assert a._studio_export(cfg,eid)['metadata_status']=='failed'
  assert a._studio_export(cfg,eid)['metadata_error']=='AI unavailable'
  # Proxy accepts 90 minutes, rejects invalid numbers, and closes streamed responses.
  remote=Mock(status_code=200,headers={'Content-Type':'video/mp4'},iter_content=lambda **kw:iter([b'video']))
  with patch.object(a.requests,'get',return_value=remote):
   assert client.get('/clip/west.mp4',params={'start':start,'end':end}).content==b'video'
   remote.close.assert_called_once()
   for invalid in ['nan','inf','-5']:
    assert client.get('/clip/west.mp4',params={'start':invalid,'end':end}).status_code==400
 print('PASS: auth/CSRF, 90-minute selection, invalid range rejection, persisted queue, nine ordered frames from exported source, editable AI defaults, restart recovery, proxy streaming cleanup')
finally:shutil.rmtree(base)
