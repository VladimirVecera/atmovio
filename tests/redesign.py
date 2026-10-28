"""Behavior contracts for the v6 workspace, recorder adapters and editable projects."""
import datetime as dt
import json
import io
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import Mock, patch

base = Path(tempfile.mkdtemp(prefix='atmovio-v6-tests-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'isolated-redesign-fixture'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/atmovio'))
import app as a
from fastapi.testclient import TestClient

try:
    a.db_init()
    cfg = a.load_config()
    cfg.update(snapshot_dir=str(base/'snapshots'), recordings_path=str(base/'recordings'), camera_names={'east': 'Kamera východ'})
    a.save_config(cfg)
    client = TestClient(a.app)
    assert client.get('/camera/east/timeline', follow_redirects=False).status_code == 303
    token = re.search(r'name="csrf_token" value="([^"]+)"', client.get('/login').text)[1]
    client.post('/login', data={'csrf_token': token, 'password': os.environ['ATMOVIO_ADMIN_PASSWORD']})
    with patch.object(a, 'frigate_cameras', return_value=['east']), patch.object(a, 'camera_recording_spans', return_value=[[1,2]]) as spans:
        spring = client.get('/camera/east/timeline?day=2026-03-29').json()
        autumn = client.get('/camera/east/timeline?day=2026-10-25').json()
        assert spring['end']-spring['start'] == 23*3600
        assert autumn['end']-autumn['start'] == 25*3600
        assert client.get('/camera/missing/timeline').status_code == 404
        assert client.get('/camera/east/timeline?day=bad').status_code == 400
    response = Mock(ok=True, status_code=200)
    response.json.return_value = [{'start_time': 20, 'end_time': 30}, {'start_time': 0,'end_time':10}, {'start_time':10,'end_time':15}]
    with patch.object(a,'frigate_api',return_value=response):
        assert a.camera_recording_spans(cfg,'east',5,25) == [[5,15],[20,25]]
    with patch.object(a.requests, 'post', return_value=response) as post, patch.object(a.requests,'delete') as delete:
        a.frigate_delete_export(cfg,'one')
        assert post.call_args.args[0].endswith('/api/exports/delete')
        assert post.call_args.kwargs['json'] == {'ids':['one']}
        delete.assert_not_called()
        response.status_code=405
        a.frigate_delete_export(cfg,'legacy')
        assert delete.call_args.args[0].endswith('/api/export/legacy')
    response.status_code=200;response.content=b'json';response.json.return_value={'success':True,'export_id':'new'}
    with patch.object(a.requests,'post',return_value=response) as post:
        assert a.frigate_start_export(cfg,'east',10,20,'Title')=='new'
        assert post.call_args.kwargs['json']=={'source':'recordings','name':'Title'}
        a.frigate_start_export(cfg,'east',10,20,'Title','timelapse_25x')
        assert '/export/custom/east/' in post.call_args.args[0]
        assert 'setpts=PTS/25' in post.call_args.kwargs['json']['ffmpeg_output_args']
    exports_response=Mock(ok=True);exports_response.json.return_value=[]
    jobs_response=Mock(ok=True);jobs_response.json.return_value=[{'id':'queued','camera':'east','name':'Queued clip','status':'queued','progress_percent':0}]
    with patch.object(a,'frigate_api',side_effect=[exports_response,jobs_response]):
        queued=a.frigate_exports(cfg)['queued']
        assert queued['in_progress'] and queued['job_status']=='queued' and not queued['video_path']
    missing=Mock(status_code=404)
    queued_response=Mock(ok=True);queued_response.json.return_value={'status':'queued'}
    with patch.object(a.requests,'post',return_value=missing),patch.object(a.requests,'get',return_value=queued_response),patch.object(a.requests,'delete') as delete:
        assert a.frigate_delete_export(cfg,'queued').status_code==409
        delete.assert_not_called()
    response.text='#EXTM3U\nhls/playlist.m3u8?id=fixtureID';response.content=response.text.encode()
    response.headers={'Content-Type':'application/vnd.apple.mpegurl'}
    with patch.object(a,'frigate_cameras',return_value=['east']),patch.object(a.requests,'get',return_value=response) as get:
        result=client.get('/stream/east/hls/master.m3u8')
        assert result.status_code==200 and 'hls/playlist' not in result.text
        assert get.call_args.kwargs['params']['src']=='east'
        assert client.get('/stream/east/hls/config').status_code==400
        assert client.get('/stream/missing/hls/master.m3u8').status_code==404
        assert client.get('/stream/east/hls/segment.m4s?id=../../config').status_code==400
        assert client.get('/recordings/east/hls/10/99999/master.m3u8').status_code==400
    def item(id,camera,start,end):return dict(id=id,camera=camera,start_ts=start,end_ts=end)
    group=a.overlapping_groups([item(1,'east',600,740),item(2,'east',650,780),item(3,'east',720,810),item(4,'west',650,800),item(5,'east',900,950)])
    assert [[v['id'] for v in g] for g in group]==[[1,2,3]]
    assert (min(v['start_ts'] for v in group[0]),max(v['end_ts'] for v in group[0]))==(600,810)
    with a.db() as con:
        for begin, finish, context in [(600,740,'{}'),(650,780,'{"video_kind":"fixed"}'),(720,810,'broken-json')]:
            con.execute("INSERT INTO auto_exports(detection_id,camera,name,start_ts,end_ts,due_ts,playback,created,film_hits,ai_context) VALUES(0,'east','Oblačnost',?,?,900,'realtime','2026-10-28','clouds',?)",(begin,finish,context))
    a.merge_pending_events()
    with a.db() as con:
        merged=[dict(r) for r in con.execute("SELECT * FROM auto_exports WHERE status='pending'")]
        assert len(merged)==1 and (merged[0]['start_ts'],merged[0]['end_ts'])==(600,810)
        assert con.execute("SELECT COUNT(*) FROM auto_exports WHERE status='joined'").fetchone()[0]==2
    # Keep originals visible until a union is really ready; broken union cannot hide footage.
    original=dict(item(1,'east',0,10),ready=True,merge_parent=2)
    parent=dict(item(2,'east',0,20),ready=False)
    assert [v['id'] for v in a.completed_ai_videos([original,parent])]==[1]
    parent['ready']=True
    assert [v['id'] for v in a.completed_ai_videos([original,parent])]==[2]
    source=base/'source.mp4';source.write_bytes(b'fixture')
    eid=a.record_export(cfg,'source',None,'east','Klip',time.time()-100,time.time()-10)
    export=a._studio_export(cfg,eid)
    with patch.object(a,'studio_kick') as kick:
        sid=a.studio_enqueue(cfg,export,20,False,'','Nad údolím','Titulek','Popis',trim_start=2,trim_end=40,
                             draft=True,edit={'music_start':120,'music_volume':0,'effect':'subscribe','effect_at':8})
        kick.assert_not_called()
    with a.db() as con:project=dict(con.execute('SELECT * FROM studio_videos WHERE id=?',(sid,)).fetchone())
    assert project['status']=='draft' and project['trim_start']==2 and project['trim_end']==40
    edit=json.loads(project['edit_json']);assert edit['music_start']==120 and edit['music_volume']==0 and edit['effect']=='subscribe'
    for bad in (float('nan'),float('inf'),-1):
        try:a.normalize_studio_edit({'music_start':bad},{});raise AssertionError('invalid edit accepted')
        except ValueError:pass
    with patch.object(a,'frigate_exports',return_value={'source':{'video_path':str(source)}}),patch.object(a,'frigate_media_path',return_value=source),patch.object(a,'ffprobe_info',return_value={'duration':100,'width':640,'height':360,'fps':25}),patch.object(a,'studio_kick'),patch.object(a,'run',return_value=(1,'')):
        r=client.get(f'/studio/new/{eid}?again={sid}')
        assert r.status_code==200 and 'value="120.0"' in r.text and 'value="subscribe" selected' in r.text
        assert '<h1>Editor videa</h1>' in r.text and 'href="/youtube">← Moje videa</a>' in r.text
        assert 'class="active" href="/youtube"' in r.text and 'href="/studio"' not in r.text
        new_editor = client.get(f'/studio/new/{eid}').text
        assert f'href="/moments#v{eid}">← AI detekce</a>' in new_editor
        assert 'class="active" href="/moments"' in new_editor
        # A missing/mismatched previous project must behave like a new video.
        assert f'href="/moments#v{eid}">← AI detekce</a>' in client.get(f'/studio/new/{eid}?again=99999').text
        with a.db() as con:
            con.execute("UPDATE exports SET name='Kamera východ 28.10. 03:58 – vývoj kupovité oblačnosti' WHERE id=?",(eid,))
            con.execute("UPDATE studio_videos SET title='můj vlastní název NASA' WHERE id=?",(sid,))
        assert 'value="Vývoj kupovité oblačnosti"' in client.get(f'/studio/new/{eid}').text
        assert 'value="můj vlastní název NASA"' in client.get(f'/studio/new/{eid}?again={sid}').text
        with a.db() as con:
            con.execute("UPDATE exports SET metadata_status='ready',metadata_json=? WHERE id=?",(json.dumps({'title':'červánky nad krajinou','description':'Popis'}),eid))
        assert 'value="Červánky nad krajinou"' in client.get(f'/studio/new/{eid}').text
        with patch.object(a,'ai_text',return_value='{"title":"úsvit nad NASA","description":"Popis"}'):
            assert a.studio_metadata(cfg,{'popis':'Obloha'})['title']=='Úsvit nad NASA'
        with patch.object(a,'ai_text',return_value='["červánky nad NASA","NASA v noci"]'):
            assert a.studio_title_ideas(cfg,{'popis':'Obloha'})==['Červánky nad NASA','NASA v noci']
        token=re.search(r'name="csrf_token" value="([^"]+)"',r.text)[1]
        r=client.post(f'/studio/new/{eid}', data={'csrf_token':token,'action':'draft','project_id':sid,'trim_start':'3','trim_end':'42','music_start':'121','effect':'share'},follow_redirects=False)
        assert r.status_code==303 and r.headers['location']=='/youtube'
        with a.db() as con:latest=dict(con.execute('SELECT * FROM studio_videos ORDER BY id DESC LIMIT 1').fetchone())
        assert latest['status']=='draft' and json.loads(latest['edit_json'])['music_start']==121
        with a.db() as con:
            assert con.execute('SELECT COUNT(*) FROM studio_videos').fetchone()[0]==1
            con.execute("UPDATE studio_videos SET created='2000-01-01',status='ready'")
            con.execute("UPDATE exports SET created='2000-01-01'")
        with patch.object(a,'delete_export') as delete_source,patch.object(a,'studio_delete') as delete_project:
            a.cleanup_exports(cfg)
            delete_source.assert_not_called();delete_project.assert_not_called()
    from PIL import Image
    picture=io.BytesIO();Image.new('RGB',(32,32),'blue').save(picture,format='PNG')
    upload=client.post('/studio/project/intro',data={'csrf_token':token},files={'file':('intro.png',picture.getvalue(),'image/png')})
    assert upload.status_code==200 and client.get(upload.json()['url']).content==picture.getvalue()
    assert client.post('/studio/project/intro',data={'csrf_token':token},files={'file':('broken.png',b'invalid','image/png')}).status_code==400
    assert a.short_video_title('Kamera východ 28.10. 03:58 – Úsvit s mlhou','east')=='Úsvit s mlhou'
    secret='rtsp://name:credential@192.0.2.1/live?token=private api_key=abc secret=xyz user@example.org'
    redacted=a.redact_diagnostic(secret)
    assert all(v not in redacted for v in ['credential','private','abc','xyz','user@example.org'])
    logs='2026-10-28 10:00:00 ERROR Camera 1 failed\n2026-10-28 10:01:00 ERROR Camera 1 failed'
    with patch.object(a,'read_log_source',return_value=logs):
        groups=a.diagnostic_groups(logs,'atmovio');assert len(groups)==1 and groups[0]['count']==2
        r=client.post('/logs/resolve',data={'csrf_token':token,'src':'atmovio','issue':groups[0]['id']},follow_redirects=False)
        assert r.status_code==303 and not a.diagnostic_groups(logs,'atmovio')
        assert a.diagnostic_groups(logs+'\n2026-10-28 10:02:00 ERROR Camera 1 failed','atmovio')
        data=client.get('/logs/export.json').json();assert data['schema_version']==1 and len(data['entries'])==2
    print('PASS: DST timeline, gaps, Frigate 0.18 and legacy delete, HLS boundaries, union visibility, draft/edit persistence, diagnostics redaction and recurrence')
finally:
    shutil.rmtree(base)
