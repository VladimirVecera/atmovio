"""New-project preferences and reversible effect library preserve existing edits."""
import json,os,re,sys,tempfile
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
with tempfile.TemporaryDirectory(prefix='atmovio-defaults-') as tmp:
 os.environ['ATMOVIO_DIR']=tmp;os.environ['ATMOVIO_ADMIN_PASSWORD']='defaults-fixture-only'
 sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
 import app as a
 a.db_init();cfg=a.load_config();cfg['snapshot_dir']=str(Path(tmp)/'snapshots');a.save_config(cfg)
 assets=a.studio_assets_dir();effects=a.studio_effect_dir()
 names=['a'*24+'.mp4','b'*24+'.mp4','c'*24+'.mp4']
 for i,name in enumerate(names):
  (effects/name).write_bytes(b'fixture animation')
  (effects/(name+'.json')).write_text(json.dumps(dict(asset=name,name='Effect '+str(i),duration=2,width=640,height=360,created=str(i))))
 (assets/'music'/'tone.mp3').write_bytes(b'fixture music')
 eid=a.record_export(cfg,'source',None,'east','Original',0,100)
 eid2=a.record_export(cfg,'source2',None,'west','Different',100,300)
 export=a._studio_export(cfg,eid)
 with patch.object(a,'studio_kick'):
  old=a.studio_enqueue(cfg,export,10,False,'','','Custom title','Own description',trim_start=12,trim_end=80,
    edit={'effect':'video','effect_asset':names[0],'effect_x':10,'effect_y':20},draft=True)
  busy=a.studio_enqueue(cfg,export,10,False,'','','Busy','',edit={'effect':'video','effect_asset':names[2]})
 client=TestClient(a.app)
 assert client.post('/studio/defaults',data={'speed':50},follow_redirects=False).status_code in (303,403)
 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 client.post('/login',data={'csrf_token':token,'password':os.environ['ATMOVIO_ADMIN_PASSWORD']},follow_redirects=False)
 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 def post(url,**data):return client.post(url,data={'csrf_token':token,**data},follow_redirects=False)
 assert client.post('/studio/defaults',data={'speed':50}).status_code==403
 assert client.post('/studio/effects/library/delete',data={'asset':names[0]}).status_code==403
 data=dict(speed=50,intro='1',music='tone.mp3',music_start=2,music_volume=.35,fade_in=1,fade_out=3,effect='video',
   effect_asset=names[0],effect_x=25,effect_y=75,effect_timing='manual',effect_at=7,effect_size=.6,effect_sound='',
   trim_start=99,trim_end=100,title='Never reuse',description='Source specific',text='East camera',project_id=old)
 with patch.object(a,'ffprobe_info',return_value={'duration':20}):
  response=post('/studio/defaults',**data);assert response.status_code==200,response.text
  saved=a.studio_cfg(a.load_config())['project_defaults']
  assert saved['speed']==50 and saved['edit']['effect_x']==25 and saved['edit']['effect_sound'] is False
  assert not any(k in saved for k in ('trim_start','trim_end','title','description','text','project_id','csrf_token'))
  invalid=post('/studio/defaults',**dict(data,effect_x='nan'));assert invalid.status_code==400
  assert a.studio_cfg(a.load_config())['project_defaults']==saved
  def capture(request,template,title,**ctx):
   return a.JSONResponse({k:ctx[k] for k in ('values','effects','effect_trash','has_defaults')})
  with patch.object(a,'render',side_effect=capture),patch.object(a,'frigate_exports',return_value={}):
   new=client.get(f'/studio/new/{eid2}').json()['values']
   assert new['speed']==50 and new['edit']['effect_asset']==names[0] and new['edit']['effect_y']==75
   assert new['edit']['effect_timing']=='manual' and new['edit']['effect_at']==7
   assert new['trim_start']==0 and new['trim_end']==200 and new['title']=='Different'
   prev=client.get(f'/studio/new/{eid}?again={old}').json()['values']
   assert prev['speed']==10 and prev['title']=='Custom title' and prev['trim_start']==12 and prev['edit']['effect_x']==10
  deleted=post('/studio/effects/library/delete',asset=names[0]);assert deleted.status_code==200
  assert a.studio_effect_path(names[0]).parent.name=='trash'
  assert a.studio_cfg(a.load_config())['project_defaults']['edit']['effect']==''
  assert a.studio_effect_meta(names[0])['archived']
  assert client.get('/studio/effects/asset/'+names[0],headers={'Range':'bytes=0-6'}).status_code==206
  with patch.object(a,'render',side_effect=capture),patch.object(a,'frigate_exports',return_value={}):
   page=client.get(f'/studio/new/{eid}?again={old}').json()
   assert any(m['asset']==names[0] and m['archived'] for m in page['effects'])
  assert post('/studio/defaults',**data).status_code==400
  post('/studio/effects/library/restore',asset=names[0]);assert a.studio_effect_path(names[0]).parent==effects
  post('/studio/defaults',**data)
  post('/studio/upload/music/delete',name='tone.mp3')
  assert a.studio_cfg(a.load_config())['project_defaults']['music']==''
 post('/studio/effects/library/delete',all_assets='1')
 assert a.studio_effect_path(names[2]).parent==effects # active render is protected
 assert len(a.studio_effects(True))==2
 post('/studio/effects/library/purge',all_assets='1')
 assert a.studio_effect_path(names[0]) and not a.studio_effect_path(names[1])
 post('/studio/effects/library/delete',asset='../config.json');assert a.CONFIG_FILE.is_file()
 assert a.studio_effect_path('../../config.json') is None
 post('/studio/defaults',reset='1');assert not a.studio_cfg(a.load_config()).get('project_defaults')
 print('PASS: explicit defaults, per-source isolation, saved-project precedence, validation, effect trash/restore/purge, protected jobs/projects, cleared defaults, auth and CSRF')
