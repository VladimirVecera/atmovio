"""Offline upload protocol/progress checks; never contacts Google or publishes videos."""
import os, sys, tempfile, shutil
from pathlib import Path
from unittest.mock import Mock, patch
base=Path(tempfile.mkdtemp(prefix='atmovio-youtube-progress-'))
os.environ['ATMOVIO_DIR']=str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD']='youtube-fixture-only'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
import app as a
try:
 a.db_init();cfg=a.load_config();source=base/'video.mp4';size=2*1024*1024+123;source.write_bytes(b'x'*size)
 job=dict(id=7,file=str(source),title='Fixture',name='Fixture',description='Offline test',yt_meta='{}',yt_status='uploading')
 assert a.youtube_upload_state(job)['progress'] is None
 assert not a.youtube_upload_state(job)['eta']
 assert a.youtube_upload_state(dict(job,yt_status='queued'))['progress'] is None
 payloads=[];clock=[100.0];observed=[]
 def send(url, data, headers, **kw):
  assert url=='https://upload.invalid/fixture'
  observed.append(a.youtube_upload_state(job)['progress'])
  start=sum(map(len,payloads));assert headers['Content-Range']==f'bytes {start}-{start+len(data)-1}/{size}'
  assert int(headers['Content-Length'])==len(data)
  payloads.append(data);clock[0]+=2
  end=sum(map(len,payloads))
  return Mock(status_code=201,json=lambda:{'id':'fixtureID'}) if end==size else Mock(status_code=308,headers={'Range':f'bytes=0-{end-1}'})
 with patch.object(a,'yt_access_token',return_value='fixture-token'),patch.object(a,'add_event'),patch.object(a.time,'time',side_effect=lambda:clock[0]),patch.object(a.requests,'post',return_value=Mock(ok=True,headers={'Location':'https://upload.invalid/fixture'})),patch.object(a.requests,'put',side_effect=send):
  url=a.yt_upload(cfg,job)
  assert url=='https://youtu.be/fixtureID'
  assert [len(p) for p in payloads]==[1024*1024,1024*1024,123]
  assert b''.join(payloads)==source.read_bytes()
  assert observed==[None,49,99]
  assert a.youtube_upload_state(job)['progress']==100
  assert 'dokončuji' in a.youtube_upload_state(job)['label']
  a._yt_progress[7]=49;a._yt_eta[7]=100;a._yt_ack_time[7]=clock[0]
  assert a.youtube_upload_state(job)['eta']
  clock[0]+=40
  assert not a.youtube_upload_state(job)['eta']
  assert 'Čekám na potvrzení' in a.youtube_upload_state(job)['detail']
  assert a.youtube_upload_state(dict(job,yt_status='done',yt_url=url))['url']==url
  assert a.youtube_upload_state(dict(job,yt_status='failed',yt_error='Fixture failure'))['detail']=='Fixture failure'
 # Small files have no false intermediate 0%/ETA: final response confirms the entire file.
 source.write_bytes(b'x'*123);a._yt_progress.clear();a._yt_eta.clear();a._yt_ack_time.clear();payloads.clear();observed.clear();size=123
 with patch.object(a,'yt_access_token',return_value='fixture-token'),patch.object(a,'add_event'),patch.object(a.requests,'post',return_value=Mock(ok=True,headers={'Location':'https://upload.invalid/fixture'})),patch.object(a.requests,'put',side_effect=send):
  a.yt_upload(cfg,job);assert observed==[None] and a._yt_progress[7]==100
 print('PASS: exact chunk bytes/ranges, acknowledged percentages, small-file indeterminate state, final confirmation, measured-only/stale ETA, failure and completion states')
finally:shutil.rmtree(base)
