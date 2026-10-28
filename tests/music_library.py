"""Music removal is reversible, protects render jobs and keeps saved projects editable."""
import os,re,sys,tempfile,json
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
with tempfile.TemporaryDirectory(prefix='atmovio-library-') as tmp:
 os.environ['ATMOVIO_DIR']=tmp;os.environ['ATMOVIO_ADMIN_PASSWORD']='fixture-library-only'
 sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
 import app as a
 a.db_init();cfg=a.load_config();cfg['snapshot_dir']=str(Path(tmp)/'snapshots');a.save_config(cfg);folder=a.studio_assets_dir()/'music'
 for name in ['keep.mp3','unused.mp3','busy.mp3']:(folder/name).write_bytes(name.encode())
 a.music_meta_path('keep.mp3').write_text(json.dumps({'title':'Original','creator':'Author','license':'CC BY'}))
 cfg.setdefault('studio',{})['music_default']='keep.mp3';a.save_config(cfg)
 eid=a.record_export(cfg,'source',None,'east','Source',0,100)
 with patch.object(a,'ffprobe_info',return_value={'duration':10}),patch.object(a,'studio_kick'):
  sid=a.studio_enqueue(cfg,a._studio_export(cfg,eid),1,False,'keep.mp3','','Saved','',draft=True)
  busy=a.studio_enqueue(cfg,a._studio_export(cfg,eid),1,False,'busy.mp3','','Busy','')
 client=TestClient(a.app)
 assert client.post('/studio/upload/music/delete',data={'all_tracks':'1'},follow_redirects=False).status_code in (303,403)
 assert (folder/'unused.mp3').is_file()
 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 client.post('/login',data={'csrf_token':token,'password':os.environ['ATMOVIO_ADMIN_PASSWORD']},follow_redirects=False)
 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 def post(url,**data):return client.post(url,data={'csrf_token':token,**data},follow_redirects=False)
 assert client.post('/studio/upload/music/delete',data={'name':'keep.mp3'}).status_code==403
 assert post('/studio/upload/music/delete',name='keep.mp3').status_code==303
 assert not (folder/'keep.mp3').exists() and a.studio_music_path('keep.mp3').read_bytes()==b'keep.mp3'
 assert 'Author' in a.music_credit('keep.mp3') and a.studio_cfg(a.load_config())['music_default']==''
 with patch.object(a,'ffprobe_info',return_value={'duration':10}):
  assert [m['name'] for m in a.studio_music_files()]==['busy.mp3','unused.mp3']
  page=client.get('/studio/music');assert page.status_code==200 and 'Smazat vše' in page.text and 'Obnovit' in page.text
 assert post('/studio/music/restore',name='keep.mp3').status_code==303 and (folder/'keep.mp3').exists()
 post('/studio/upload/music/delete',all_tracks='1')
 assert (folder/'busy.mp3').exists() and not (folder/'unused.mp3').exists()
 assert a.studio_music_path('keep.mp3')
 post('/studio/music/trash/empty')
 assert a.studio_music_path('keep.mp3') and a.studio_music_path('unused.mp3') is None
 assert a.studio_music_path('../config.json') is None
 post('/studio/upload/music/delete',name='../config.json');assert a.CONFIG_FILE.is_file()
 with a.db() as con:assert con.execute('SELECT music FROM studio_videos WHERE id=?',(sid,)).fetchone()[0]=='keep.mp3'
 print('PASS: single/bulk music trash, restore, unused purge, project and active-job protection, metadata, defaults, auth and CSRF')
