"""Real overlay pixels, audio timing, reusable uploads and saved effect configuration."""
import os,sys,tempfile,shutil,subprocess,json,re,hashlib,struct,math
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
from PIL import Image
if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
 print('SKIP: effect rendering requires ffmpeg and ffprobe');raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='atmovio-effects-') as tmp:
 base=Path(tmp);os.environ['ATMOVIO_DIR']=tmp;os.environ['ATMOVIO_ADMIN_PASSWORD']='effect-fixture-only'
 sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/atmovio'))
 import app as a
 def ff(*args):return subprocess.run(['ffmpeg','-v','error','-nostdin','-y',*map(str,args)],check=True,capture_output=True).stdout
 a.db_init();cfg=a.load_config();cfg['snapshot_dir']=str(base/'snapshots');cfg.setdefault('studio',{}).update(video_fade_in=0,video_fade_out=0);a.save_config(cfg)
 source=base/'source.mp4';ff('-f','lavfi','-i','color=blue:s=640x360:r=24','-t','8','-c:v','libx264',source)
 original=hashlib.sha256(source.read_bytes()).hexdigest()
 poster=base/'poster.jpg';Image.new('RGB',(640,360),'blue').save(poster)
 assets=a.studio_assets_dir();Image.new('RGB',(640,360),'yellow').save(assets/'intro.png')
 ff('-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','8',assets/'music'/'tone.wav')
 client=TestClient(a.app);token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 client.post('/login',data={'csrf_token':token,'password':os.environ['ATMOVIO_ADMIN_PASSWORD']},follow_redirects=False)
 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
 eid=a.record_export(cfg,'source',None,'east','Fixture',0,8)
 for background in ['green','black']:
  clip=base/(background+'.mp4')
  ff('-f','lavfi','-i',f'color={"0x00ff00" if background=="green" else "black"}:s=640x360:r=24','-f','lavfi','-i','sine=frequency=1000:sample_rate=44100',
     '-vf','drawbox=x=260:y=155:w=120:h=50:color=red:t=fill','-t','2','-c:v','libx264','-c:a','aac',clip)
  response=client.post('/studio/effects/upload',data={'csrf_token':token},files={'file':(clip.name,clip.read_bytes(),'video/mp4')})
  assert response.status_code==200,response.text
  meta=response.json();assert meta['background']==background and meta['crop'][2]-meta['crop'][0]<.5,meta
  assert client.get('/studio/effects/asset/'+meta['asset'],headers={'Range':'bytes=0-99'}).status_code==206
  pos=0 if background=='green' else 100
  point=(100,60) if pos==0 else (540,300)
  edit={'effect_x':pos,'effect_y':pos,'effect':'video','effect_asset':meta['asset'],'effect_timing':'auto','effect_background':'auto','effect_sound':True,'music_volume':.2,'fade_in':0,'fade_out':0}
  with patch.object(a,'studio_kick'):
   sid=a.studio_enqueue(cfg,a._studio_export(cfg,eid),1,True,'tone.wav','','Overlay','',edit=edit,draft=True)
  with a.db() as con:job=dict(con.execute('SELECT * FROM studio_videos WHERE id=?',(sid,)).fetchone())
  client.post('/studio/effects/library/delete',data={'csrf_token':token,'asset':meta['asset']})
  assert a.studio_effect_path(meta['asset']).parent.name=='trash'
  assert json.loads(job['edit_json'])['effect_asset']==meta['asset']
  assert json.loads(job['edit_json'])['effect_x']==pos and json.loads(job['edit_json'])['effect_y']==pos
  client.post('/studio/upload/music/delete',data={'csrf_token':token,'name':'tone.wav'},follow_redirects=False)
  assert a.studio_music_path('tone.wav').parent.name=='trash'
  with patch.object(a,'storage_ready',return_value=True),patch.object(a,'frigate_exports',return_value={'source':{'video_path':str(source),'thumb_path':str(poster)}}),patch.object(a,'frigate_media_path',side_effect=lambda p:Path(p)),patch.object(a,'studio_after_render'):
   preview=client.post('/studio/effects/preview',data={'csrf_token':token,'asset':meta['asset'],'vid':eid,'x':pos,'y':pos})
   assert preview.status_code==200,preview.text
   assert client.get(preview.json()['url']).status_code==200
   preview_path=a.studio_effect_dir()/'previews'/Path(preview.json()['url']).name
   raw=ff('-ss','1','-i',preview_path,'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1')
   sample=Image.frombytes('RGB',(640,360),raw)
   assert sample.getpixel(point)[0]>200 and sample.getpixel((320,180))[2]>200
   saved=client.post(f'/studio/new/{eid}',data={'csrf_token':token,'action':'draft','speed':1,'title':'Positioned','effect':'video','effect_asset':meta['asset'],'effect_x':25,'effect_y':75,'trim_end':8},follow_redirects=False)
   assert saved.status_code==303,saved.text
   with a.db() as con: saved_edit=json.loads(con.execute("SELECT edit_json FROM studio_videos WHERE title='Positioned' ORDER BY id DESC LIMIT 1").fetchone()[0])
   assert saved_edit['effect_x']==25 and saved_edit['effect_y']==75
   a.studio_render(cfg,job)
  out=a.studio_out_dir(cfg)/f'{sid}.mp4';info=a.ffprobe_info(out)
  assert info['audio'] and 11.9<info['duration']<12.2,info
  def pixel(t):
   raw=ff('-ss',t,'-i',out,'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','pipe:1')
   im=Image.frombytes('RGB',(640,360),raw);return im.getpixel(point),im.getpixel((320,180))
  before,_=pixel(5);during,outside=pixel(6.7);after,_=pixel(9)
  assert before[2]>200 and after[2]>200 and outside[2]>200,(before,during,after,outside)
  assert during[0]>200 and during[1]<50 and during[2]<50,during
  def rms(t):
   raw=ff('-ss',t,'-i',out,'-t','0.3','-vn','-ac','1','-ar','8000','-f','f32le','pipe:1')
   samples=struct.unpack('<'+'f'*(len(raw)//4),raw);return math.sqrt(sum(s*s for s in samples)/len(samples))
  assert rms(6.7)>rms(5)*2
 assert a.normalize_studio_edit({},a.studio_cfg(cfg))['effect_x']==50
 assert a.normalize_studio_edit({},a.studio_cfg(cfg))['effect_y']==100
 for key in ('effect_x','effect_y'):
  for bad in (-1,101,float('nan'),float('inf')):
   try:a.normalize_studio_edit({key:bad},a.studio_cfg(cfg))
   except ValueError:pass
   else:raise AssertionError('invalid coordinate accepted')
   response=client.post('/studio/effects/preview',data={'csrf_token':token,'asset':meta['asset'],'vid':eid,key[-1]:bad})
   assert response.status_code in (400,422),response.text
 assert a.studio_effect_start(60,5)==15 and a.studio_effect_start(3,5)==0
 assert a.studio_effect_start(10,4,'manual',9)==6
 assert hashlib.sha256(source.read_bytes()).hexdigest()==original
 assert client.post('/studio/effects/upload',files={'file':('bad.mp4',b'broken','video/mp4')}).status_code==403
 assert client.post('/studio/effects/upload',data={'csrf_token':token},files={'file':('bad.mp4',b'broken','video/mp4')}).status_code==400
 assert a.studio_effect_meta('../../config.json') is None
 print('PASS: green/black detection and removal, cropping, corner positions in preview/render, saved coordinates and bounds, effect+intro+music timing, delayed sound, saved assets, short clips, untouched source, auth/CSRF')
