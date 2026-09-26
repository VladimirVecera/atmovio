"""Offline integration regression checks; no real cameras, APIs or system services."""
import os, sys, tempfile, json, copy, re, io, datetime as dt, contextlib, subprocess
from pathlib import Path
from unittest.mock import patch, Mock
from html.parser import HTMLParser
from zoneinfo import ZoneInfo
base=Path(tempfile.mkdtemp(prefix='atmovio-47-fixtures-'))
os.environ['ATMOVIO_DIR']=str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD']='isolated-audit-fixture-only'
os.environ['PYTHONDONTWRITEBYTECODE']='1'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src' / 'atmovio'))
import app as a
from fastapi.testclient import TestClient
from PIL import Image
results={'version':a.APP_VERSION,'checks':[],'observations':[],'fixture_directory':'temporary, removed after tests'}
def ok(name):results['checks'].append(name)
def observe(name,detail):results['observations'].append({'name':name,'detail':detail})
a.db_init()
cfg=a.load_config()
cfg.update(frigate_config_path=str(base/'frigate.yml'),recordings_path=str(base/'recordings'),snapshot_dir=str(base/'snapshots'))
for key in ['recordings_path','snapshot_dir']:Path(cfg[key]).mkdir()
cfg['camera_names']={'test_cam':'Testovací kamera'}
cfg['ai'].update(enabled=True,provider='ollama',cameras=['test_cam'],cam_rules={'test_cam':{'custom':True,'threshold':8,'phenomena':['cervanky'],'any':False}})
cfg['ai']['auto_export'].update(enabled=True,cameras=['test_cam'])
a.save_config(cfg)
# Every built-in is reachable once; custom categories remain in their own group.
group_cfg=copy.deepcopy(cfg['ai'])
group_cfg['custom_phenomena']=[{'id':'custom_test','label':'Vlastní jev','desc':'Ukázka'}]
grouped=[p[0] for _,items in a.phenomena_groups(group_cfg) for p in items]
assert len(grouped)==len(set(grouped))==len(a.PHENOMENA)+1
assert set(a.PHENOMENA_IDS).issubset(grouped)
assert 'vice_vrstev' not in a.build_prompt(cfg['ai'],0)
assert 'vice_vrstev' in a.build_prompt(cfg['ai'],8)
response=Mock()
response.json.return_value={'response':json.dumps({'score':8,'phenomena':['vice_vrstev','cavum','unknown'],'timelapse':9})}
with patch.object(a.requests,'post',return_value=response):
    single,_=a._ai_evaluate_once(cfg['ai'],b'fixture',0)
    film,_=a._ai_evaluate_once(cfg['ai'],b'fixture',8)
assert single['phenomena']==['cavum']
assert film['phenomena']==['vice_vrstev','cavum']
old=copy.deepcopy(cfg);old['ai']['phenomena']=['cervanky'];old['ai']['phenomena_seen']=['2']
a.save_config(old)
assert a.load_config()['ai']['phenomena']==['cervanky']
assert a.load_config()['ai']['cam_rules']==old['ai']['cam_rules']
a.save_config(cfg)
ok('Grouped catalog preserves selections and filters unsupported single-image motion')
frigate={'cameras':{'test_cam':{'enabled':True,'ffmpeg':{'inputs':[{'path':'rtsp://192.0.2.1/live','roles':['record','detect']}]}}},'record':{'enabled':True,'continuous':{'days':7}},'go2rtc':{'streams':{'test_cam':['rtsp://192.0.2.1/live']}}}
a.frigate_write_yaml(cfg,frigate)
now=dt.datetime.now(ZoneInfo(cfg['tz']))
img=io.BytesIO();Image.new('RGB',(320,180),(100,130,180)).save(img,format='JPEG');jpg=img.getvalue()
Path(cfg['snapshot_dir'],'fixture.jpg').write_bytes(jpg)
rid=a.watcher.record({'ts':now.isoformat(),'camera':'test_cam','image':'fixture.jpg','score':8,'phenomenon':'Červánky','phenomena':['cervanky'],'description':'Testovací detekce','notified':1,'trend':'nastupuje','timelapse':9})
vid=a.record_export(cfg,'fixture-export',rid,'test_cam','Testovací klip',now.timestamp()-300,now.timestamp()+600,auto=1)
video=base/'fixture.mp4';video.write_bytes(b'fixture-only-not-real-video'*200)
with a.db() as con:
 con.execute("INSERT INTO studio_videos(export_id,camera,name,speed,title,description,status,file,duration,created,auto) VALUES(?,?,?,?,?,?,?,?,?,?,?)",(vid,'test_cam','Testovací video',20,'Testovací titulek','Testovací popis','ready',str(video),45,now.replace(tzinfo=None).isoformat(),1))
for name in a.TEMPLATES:a.jenv.get_template(name)
ok(f'{len(a.TEMPLATES)} Jinja templates compiled')
class Forms(HTMLParser):
 def __init__(self):super().__init__();self.post=False;self.token=False;self.forms=0;self.missing=0
 def handle_starttag(self,tag,attrs):
  d=dict(attrs)
  if tag=='form':self.post=d.get('method','').lower()=='post';self.token=False
  if tag=='input' and d.get('name')=='csrf_token' and d.get('value'):self.token=True
 def handle_endtag(self,tag):
  if tag=='form' and self.post:
   self.forms+=1;self.missing+=not self.token;self.post=False
with contextlib.ExitStack() as stack:
 stack.enter_context(patch('requests.sessions.Session.request',side_effect=RuntimeError('External HTTP disabled in audit')))
 stack.enter_context(patch('subprocess.run',return_value=subprocess.CompletedProcess([],1,'','Unavailable in fixture')))
 stack.enter_context(patch('subprocess.Popen',side_effect=RuntimeError('Process launch disabled in audit')))
 stack.enter_context(patch.object(a,'frigate_status',return_value={'online':True,'version':'fixture','uptime':3600,'cameras':{'test_cam':{'fps':15,'pid':1}}}))
 stack.enter_context(patch.object(a,'frigate_exports',return_value={'fixture-export':{'video_path':str(video),'in_progress':False}}))
 stack.enter_context(patch.object(a,'frigate_media_path',side_effect=lambda p:Path(p) if p else None))
 stack.enter_context(patch.object(a,'list_disks',return_value=[]))
 stack.enter_context(patch.object(a,'disk_health',return_value=[]))
 stack.enter_context(patch.object(a,'studio_kick'))
 stack.enter_context(patch.object(a,'yt_kick'))
 stack.enter_context(patch.object(a,'ffprobe_info',return_value={'duration':900,'width':1920,'height':1080,'fps':15}))
 client=TestClient(a.app,raise_server_exceptions=False)
 response=client.get('/');assert response.url.path=='/login';ok('Unauthenticated UI redirects to login')
 assert client.get('/api/v1/status').status_code==401;ok('Unauthenticated REST API rejected')
 login=client.get('/login');token=re.search(r'name="csrf_token" value="([^"]+)"',login.text)[1]
 assert client.post('/login',data={'password':os.environ['ATMOVIO_ADMIN_PASSWORD']}).status_code==403;ok('POST without CSRF rejected')
 assert client.post('/login',data={'password':os.environ['ATMOVIO_ADMIN_PASSWORD'],'csrf_token':token},follow_redirects=False).status_code==303
 ok('Session login with CSRF')
 for camera_count in (1, 2, 3, 4, 5, 8):
  names=[f'layout_cam_{i}' for i in range(camera_count)]
  with patch.object(a,'frigate_cameras',return_value=names), patch.object(a,'camera_info',return_value={'ip':'192.0.2.1','via':'LAN'}):
   page=client.get('/')
   assert page.status_code==200
   for name in names: assert f'href="/camera/{name}" title="Otevřít kameru"' in page.text
 ok('Dashboard includes every camera for 1, 2, 3, 4, 5 and 8 cameras')

 # Updater expressions must survive HTML attribute parsing, including quoted/multiline logs.
 class UpdaterAttrs(HTMLParser):
  expression = None
  def handle_starttag(self, tag, attrs):
   value = dict(attrs).get('x-data', '')
   if value.startswith('updater('): self.expression = value
 tricky_log = 'Instaluji "novou" verzi\n<script> & další řádek'
 with patch.object(a,'update_running',return_value=True), patch.object(a,'update_log_tail',return_value=tricky_log):
  parsed = UpdaterAttrs(); parsed.feed(client.get('/system/update').text)
  args = json.loads('[' + parsed.expression[len('updater('):-1] + ']')
  assert args == [True, a.APP_VERSION, tricky_log], args
 for running, log_text, outcome in [(True,'✔ Atmovio aktualizován:', 'running'), (False,'✔ Atmovio aktualizován:', 'done'), (False,'Aktualizace selhala, obnovuji původní aplikaci', 'failed'), (False,'nedokončený log', 'unknown')]:
  with patch.object(a,'update_running',return_value=running), patch.object(a,'update_log_tail',return_value=log_text):
   result=client.get('/system/update/status')
   assert result.json()['outcome']==outcome
   assert result.headers['cache-control']=='no-store'
 ok('Updater HTML quoting, running health-check, completion, failure and unconfirmed outcomes')
 assert 'name="pw1"' not in client.get('/system').text
 assert 'name="pw1"' in client.get('/system/access').text
 assert 'action="/system/api_key"' in client.get('/system/integrations').text
 assert 'value="reboot"' in client.get('/system/maintenance').text
 multiline='2026-09-26 09:00:00 old\n  detail one\n2026-09-26 10:00:00 new\n  detail two'
 assert a.newest_log_first(multiline)=='2026-09-26 10:00:00 new\n  detail two\n2026-09-26 09:00:00 old\n  detail one'
 assert len(a.log_rows(multiline))==2
 with patch.object(a,'storage_status',return_value={'mode':'switching','reason':'Přepínám režim Frigate'}):
  assert client.get('/system/runtime-status').json()['ready'] is False
  assert 'Disk pro záznamy není připojený' not in client.get('/storage').text
 with patch.object(a,'storage_status',return_value={'mode':'recording','reason':'OK'}):
  assert client.get('/system/runtime-status').json()['ready'] is True
 ok('System subpages, newest-first multiline logs and accurate transitioning storage state')


 token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/ai').text)[1]
 guard_marker=a.APP_DIR/'storage_guard.py'; guard_marker.touch()
 response=client.post('/system/ctl',data={'action':'restart_frigate','csrf_token':token},follow_redirects=False)
 assert response.status_code==303
 request_id=(a.APP_DIR/'storage-restart').read_text().strip()
 with patch.object(a,'storage_status',return_value={'mode':'recording','reason':'OK','checked_at':a.time.time()+1,'restart_request':'old'}):
  assert client.get('/system/runtime-status').json()['ready'] is False
 with patch.object(a,'storage_status',return_value={'mode':'recording','reason':'OK','checked_at':a.time.time()+1,'restart_request':request_id}):
  assert client.get('/system/runtime-status').json()['ready'] is True
 guard_marker.unlink()
 ok('Restart recovery waits for exact guard acknowledgement, not an old online recorder')

 pages=['/system/access','/system/integrations','/system/maintenance','/ai/guide','/youtube','/videos/settings','/','/live','/live/all','/live/test_cam','/camera/test_cam','/cameras','/cameras/edit/test_cam','/discover','/storage','/ai','/history','/history?show=all','/detection/1','/videos','/studio/new/1','/studio/v/1','/studio/settings','/email','/vpn','/logs','/system','/system/update']
 failed=[];form_count=0
 for page in pages:
  r=client.get(page)
  if r.status_code!=200:failed.append((page,r.status_code,r.text[:120]))
  else:
   f=Forms();f.feed(r.text);assert f.missing==0,(page,f.missing);form_count+=f.forms
 results['page_results']={'requested':len(pages),'failed':failed,'post_forms_with_csrf':form_count}
 assert not failed,failed
 ok(f'{len(pages)} populated page requests rendered; {form_count} POST forms contain CSRF')
 with patch.object(a,'export_thumb_path',side_effect=AssertionError('Dashboard must not run thumbnail generation')):
  assert client.get('/').status_code==200
 assert len(a.list_videos(cfg,limit=0))==0 and len(a.studio_rows(cfg,limit=0))==0
 ok('Dashboard reads bounded video summaries without generating thumbnails')
 for state in ['queued','rendering','failed','ready']:
  for yt in [None,'queued','uploading','failed','done']:
   with a.db() as con:con.execute('UPDATE studio_videos SET status=?,yt_status=? WHERE id=1',(state,yt))
   for url in ['/youtube','/studio/v/1']:
    r=client.get(url);assert r.status_code==200,(url,state,yt,r.text[:100])
 ok('40 video list/detail renders across creation and upload states')
 with a.db() as con:con.execute("UPDATE studio_videos SET status='ready',yt_status=NULL WHERE id=1")
 for mode in ['live','unknown','error','recording']:
  with patch.object(a,'storage_status',return_value={'mode':mode,'reason':'Fixture state'}):
   for url in ['/','/live','/storage','/videos']:
    r=client.get(url);assert r.status_code==200,(mode,url)
 ok('16 page renders across live-only, unknown, disk error, recording')
 for url in ['/detection/9999','/studio/v/9999','/studio/new/9999','/camera/unknown']:
  assert client.get(url,follow_redirects=False).status_code==303
 ok('Missing detection/video/camera redirects')
 # Settings round trip and future split-page regression risk.
 saved=copy.deepcopy(a.load_config())
 form={k:str(v) for k,v in saved['ai'].items() if isinstance(v,(str,int,float)) and not isinstance(v,bool)}
 for k in ['enabled','day_only','prefilter','fast_mode','dark_skip']:form[k]='1' if saved['ai'][k] else ''
 form.update(provider='ollama',cam_test_cam='1',ax_enabled='1',ax_cam_test_cam='1',ax_before='2',ax_after='3',ax_playback='realtime',strip_enabled='1',strip_frames='6',strip_span_min='60',mode_test_cam='custom',thr_test_cam='8',cph_test_cam_cervanky='1',csrf_token=token)
 for p in saved['ai']['phenomena']:form['ph_'+p]='1'
 r=client.post('/ai',data=form,follow_redirects=False);assert r.status_code==303,(r.status_code,r.text[:200])
 after=a.load_config();assert after['ai']['enabled'] and after['ai']['cameras']==['test_cam'] and after['ai']['strip']=={'enabled':True,'frames':6,'span_min':60,'mode':'batch','max_frames':36}
 ok('Full AI form saves cameras, enable flags and filmstrip 4.7')
 # Each settings form writes only its own configuration.
 ai_before=copy.deepcopy(after['ai'])
 r=client.post('/videos/settings',data={'csrf_token':token,'ax_enabled':'1','ax_cam_test_cam':'1','ax_before':'5','ax_after':'10','ax_playback':'timelapse_25x','days':'45'},follow_redirects=False)
 assert r.status_code==303
 video_cfg=a.load_config(); expected=copy.deepcopy(ai_before); expected['auto_export']=video_cfg['ai']['auto_export']
 assert video_cfg['ai']==expected and video_cfg['export_keep_days']==45
 assert video_cfg['ai']['auto_export']=={'enabled':True,'timelapse_enabled':False,'timelapse_threshold':7,'cameras':['test_cam'],'before_min':5,'after_min':10,'playback':'timelapse_25x','length_mode':'event','duration_min':60}
 form['scope']='ai';form['ax_enabled']='';form['ax_cam_test_cam']=''
 r=client.post('/ai',data=form,follow_redirects=False);assert r.status_code==303
 assert a.load_config()['ai']['auto_export']==video_cfg['ai']['auto_export']
 a.save_config(after)
 ok('Separate AI and AI-video POST forms preserve unrelated settings, cameras and rules')
 # Metadata proposals are evidence-based, validated and do not save over human text.
 ex=a._studio_export(cfg,vid);v=a.studio_vars(cfg,ex,20)
 assert v['popis']=='Testovací detekce' and v['clip_start']==ex['start_ts']
 with patch.object(a,'ai_text',return_value=json.dumps({'title':'Červánky nad obzorem','description':'Nad obzorem jsou vidět červánky.'})) as ai:
  r=client.post('/studio/metadata',data={'csrf_token':token,'sid':'1'})
  assert r.status_code==200 and r.json()['title']=='Červánky nad obzorem'
  assert 'film_start' in ai.call_args.args[1] and 'Testovací detekce' in ai.call_args.args[1]
  with a.db() as con:assert con.execute('SELECT title FROM studio_videos WHERE id=1').fetchone()[0]=='Testovací titulek'
 with patch.object(a,'ai_text',return_value='{"title":"Missing description"}'):
  assert client.post('/studio/metadata',data={'csrf_token':token,'sid':'1'}).status_code==400
 assert client.post('/studio/metadata',data={'sid':'1'}).status_code==403
 with patch.object(a,'ai_text',side_effect=RuntimeError('Provider unavailable')):
  assert client.post('/studio/metadata',data={'csrf_token':token,'sid':'1'}).status_code==400
 ok('Metadata success, malformed JSON schema, API failure, CSRF and no implicit saving')
 # Temporal evidence is used only when the full assessed window belongs to the clip.
 evidence=dict(v,film_start=ex['start_ts'],film_end=ex['end_ts'],frames=6,vyvoj='Oblačnost postupně houstne',trend='nastupuje')
 with patch.object(a,'ai_text',return_value='{"title":"Obloha","description":"Pozorování oblohy."}') as ai:
  a.studio_metadata(cfg,evidence)
  assert 'Oblačnost postupně houstne' in ai.call_args.args[1]
  evidence['film_start']=ex['start_ts']-3600
  a.studio_metadata(cfg,evidence)
  assert 'Oblačnost postupně houstne' not in ai.call_args.args[1]
 ok('Exclude evolution outside the exported clip from metadata evidence')
 # End-to-end image analysis result retains film timing, description, and exports it.
 image_cfg=copy.deepcopy(cfg);image_cfg['ai'].update(prefilter=False,dark_skip=False,threshold=10)
 w2=a.AtmovioWatcher();w2.strip_frames['test_cam']=[(now.timestamp()-600,jpg),(now.timestamp()-300,jpg)]
 evaluated={'score':3,'phenomena':[],'phenomenon':'Oblačnost','description':'Mraky','trend':'nastupuje','timelapse':7,'evolution':'Oblačnost houstne'}
 with patch.object(a,'fetch_snapshot',return_value=jpg),patch.object(a,'storage_ready',return_value=True),patch.object(a,'ai_evaluate',return_value=(evaluated,json.dumps(evaluated))):
  outcome=w2.check_camera(image_cfg,'test_cam',now)
 assert json.loads(outcome['film_context'])['frames']==3
 assert json.loads(outcome['film_context'])['evolution']=='Oblačnost houstne'
 with a.db() as con:assert json.loads(con.execute('SELECT film_context FROM evaluations WHERE id=?',(outcome['id'],)).fetchone()[0])['start']==now.timestamp()-600
 ok('Filmstrip evaluation stores real time bounds and observed evolution')
 # Automatic studio creation carries both generated fields and falls back as one unit.
 auto_cfg=copy.deepcopy(cfg);auto_cfg['studio'].update(auto=True,ai_title=True)
 av=a.record_export(cfg,'fixture-export',rid,'test_cam','Auto metadata',now.timestamp()-300,now.timestamp()+600,auto=1)
 with patch.object(a,'studio_metadata',return_value={'title':'AI nadpis','description':'AI popis'}),patch.object(a,'studio_enqueue') as enq:
  a.studio_auto(auto_cfg);assert enq.call_count==1
  assert enq.call_args.args[6:8]==('AI nadpis','AI popis')
 with patch.object(a,'studio_metadata',side_effect=RuntimeError('offline')),patch.object(a,'studio_enqueue') as enq:
  a.studio_auto(auto_cfg);assert enq.call_count==1 and enq.call_args.args[6] and 'Testovací detekce' in enq.call_args.args[7]
 with a.db() as con:con.execute('DELETE FROM exports WHERE id=?',(av,))
 ok('Automatic AI title and description plus provider-failure template fallback')
 # Combination filters and default visibility include evaluations without an alert.
 r2=a.watcher.record({'ts':now.isoformat(),'camera':'test_cam','score':3,'phenomenon':'Běžná obloha','phenomena':['c_foo_bar'],'description':'Bez upozornění','notified':0})
 assert 'Bez upozornění' in client.get('/history').text
 assert 'Bez upozornění' not in client.get('/history?show=notified').text
 assert 'Bez upozornění' in client.get('/history?phenomenon=c_foo_bar').text
 assert 'Testovací detekce' not in client.get('/history?phenomenon=c_foo_bar').text
 assert 'Bez upozornění' not in client.get('/history?since=2099-01-01').text
 assert client.get('/history?since=invalid',follow_redirects=False).status_code==303
 ok('All evaluations default, combined date/phenomenon/status filters')
 # Rename fixture with camera/video rules enabled; never touch real config.
 with patch.object(a,'frigate_restart',return_value=(0,'')):
  r=client.post('/cameras/add',data={'csrf_token':token,'name':'Renamed camera','main':'rtsp://192.0.2.1/live','replace':'test_cam'},follow_redirects=False)
  assert r.status_code==303
 renamed=a.load_config()
 assert renamed['ai']['cameras']==['test_cam'] and renamed['ai']['auto_export']['cameras']==['test_cam'] and 'test_cam' in renamed['ai']['cam_rules']
 assert renamed['camera_names']['test_cam']=='Renamed camera'
 ok('Camera display name changes without changing ID or detaching video and AI rules')
 a.save_config(after);a.frigate_write_yaml(after,frigate)
 # Single deletion of a 4.7 detection.
 sp=Path(cfg['snapshot_dir'],'fixture_strip.jpg');sp.write_bytes(jpg)
 r=client.post('/detection/1/delete',data={'csrf_token':token},follow_redirects=False);assert r.status_code==303
 assert not sp.exists() and not Path(cfg['snapshot_dir'],'fixture.jpg').exists()
 assert a.studio_vars(cfg,a._studio_export(cfg,vid),20)['popis']=='Testovací detekce'
 ok('Delete original and filmstrip together; retain AI evidence with exported clip')
 # Cleanup selection: interception only, no real file deletion.
 with a.db() as con:con.execute("UPDATE studio_videos SET status='ready',yt_status='uploading',created='2000-01-01T00:00:00' WHERE id=1")
 with patch.object(a,'delete_export') as de,patch.object(a,'studio_delete') as sd:
  a.cleanup_exports(cfg)
  assert sd.call_count==0
  ok('Retention skips an uploading YouTube video')
 # All-history semantics: skipped checks increment stats without saved rows.
 w=a.AtmovioWatcher();dark=io.BytesIO();Image.new('RGB',(32,18),'black').save(dark,format='JPEG')
 count=lambda:a.db()
 with a.db() as con:n0=con.execute('SELECT COUNT(*) FROM evaluations').fetchone()[0]
 with patch.object(a,'fetch_snapshot',return_value=dark.getvalue()),patch.object(a,'storage_ready',return_value=True):
  outcome=w.check_camera(cfg,'test_cam',now)
 assert outcome.get('skipped')==1
 with a.db() as con:n1=con.execute('SELECT COUNT(*) FROM evaluations').fetchone()[0]
 assert n1==n0;ok('Dark frame skipped without AI HTTP call or saved evaluation')
 observe('Skipped snapshots are aggregates, not a gallery','No evaluations row or stored snapshot for dark/prefilter skips; dashboard can show counts, not retrospective images of skipped checks.')
 # Filmstrip without calling external AI.
 strip=a.make_filmstrip(jpg,[(now.timestamp()-600,jpg),(now.timestamp()-300,jpg)],now.timestamp())
 im=Image.open(io.BytesIO(strip));assert im.width==1280 and im.height>720
 ok('4.7 filmstrip generation from current and two older JPEGs')
 # Storage guard pure transformations preserve source configuration.
 import storage_guard as sg
 source=copy.deepcopy(frigate);live=sg.live_config(source)
 assert source==frigate and live['record']['enabled']==False
 assert all('record' not in i['roles'] for i in live['cameras']['test_cam']['ffmpeg']['inputs'])
 assert live['database']['path']=='/config/live/frigate.db'
 ok('Storage guard live-only transform preserves source and disables recording')
 # Active source/output deletion is rejected; intentional output deletion suppresses regeneration.
 with a.db() as con:con.execute("UPDATE studio_videos SET status='rendering',yt_status=NULL WHERE id=1")
 assert a.delete_export(cfg,a._studio_export(cfg,vid)) is False
 assert a.studio_delete(cfg,a.studio_rows(cfg,sid=1)[0]) is False
 with a.db() as con:con.execute("UPDATE studio_videos SET status='ready',yt_status=NULL WHERE id=1")
 assert a.studio_delete(cfg,a.studio_rows(cfg,sid=1)[0]) is True
 auto_cfg=copy.deepcopy(cfg);auto_cfg['studio']['auto']=True;auto_cfg['studio']['ai_title']=False
 with patch.object(a,'studio_enqueue') as enqueue:
  a.studio_auto(auto_cfg);assert enqueue.call_count==0
 # Explicit new studio work from retained source is still offered.
 assert client.get('/studio/new/1?again=999').status_code==200
 ok('Protect active workers, suppress deleted automatic output, allow explicit recreation')
 # Migrate an existing 4.7 database additively and snapshot its evidence.
 with a.db() as con:
  con.execute('UPDATE exports SET ai_context=NULL,detection_id=? WHERE id=?',(r2,vid))
 with a.db() as con:
  con.execute('ALTER TABLE exports DROP COLUMN studio_suppressed')
  con.execute('ALTER TABLE exports DROP COLUMN ai_context')
  con.execute('ALTER TABLE evaluations DROP COLUMN film_context')
 a.db_init();a.db_init()
 assert a.studio_vars(cfg,a._studio_export(cfg,vid),20)['popis']=='Bez upozornění'
 ok('Idempotent upgrade migration preserves legacy evaluation evidence')
 # An empty initial installation should still render all normal entry points.
 empty=copy.deepcopy(cfg);empty['ai']['cameras']=[];empty['ai']['enabled']=False;a.save_config(empty)
 a.frigate_write_yaml(empty,{'cameras':{},'record':{'enabled':True,'continuous':{'days':7}}})
 with a.db() as con:
  for table in ['evaluations','exports','auto_exports','studio_videos','ai_stats','events']:con.execute('DELETE FROM '+table)
 with patch.object(a,'frigate_status',return_value={'online':False,'version':'','cameras':{}}),patch.object(a,'frigate_exports',return_value={}):
  for url in ['/youtube','/videos/settings','/','/live','/cameras','/discover','/storage','/ai','/history','/videos','/studio/settings','/email','/system']:
   r=client.get(url);assert r.status_code==200,(url,r.status_code,r.text[:100])
 ok('13 empty-installation/offline page renders')
# Don't start watcher, FFmpeg, Docker, real cameras, or external API clients.
assert not a.watcher.is_alive()
import shutil
shutil.rmtree(base)
print(json.dumps(results,ensure_ascii=False,indent=2))
