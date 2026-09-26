"""Deterministic offline tests of sampled films, restart, evidence, and cross-window video episodes."""
import os, sys, tempfile, json, copy, io, datetime as dt, shutil
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

base = Path(tempfile.mkdtemp(prefix='atmovio-films-test-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'isolated-film-fixture'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src' / 'atmovio'))
import app as a
from PIL import Image
from fastapi.testclient import TestClient

checks = []
def ok(text): checks.append(text)
a.db_init(); a.db_init()
cfg = a.load_config()
cfg.update(snapshot_dir=str(base/'snapshots'), recordings_path=str(base/'recordings'), frigate_config_path=str(base/'frigate.yml'))
Path(cfg['snapshot_dir']).mkdir(); Path(cfg['recordings_path']).mkdir()
cfg['ai'].update(enabled=True, cameras=['east','west'], day_only=False, interval_min=5, daily_limit=0, threshold=7, phenomena=['cervanky'], cam_rules={})
cfg['ai']['strip'].update(mode='batch', enabled=True, span_min=60)
cfg['ai']['auto_export'].update(enabled=True, cameras=['east','west'], before_min=2, after_min=3)
a.save_config(cfg)
a.frigate_write_yaml(cfg, {'cameras':{'east':{},'west':{}}})
origin = dt.datetime(2026,9,26,12,0,tzinfo=ZoneInfo(cfg['tz']))
buf = io.BytesIO(); Image.new('RGB',(640,360),(100,120,180)).save(buf,'JPEG'); jpg=buf.getvalue()
def rows(table):
    with a.db() as con: return [dict(r) for r in con.execute('SELECT * FROM '+table+' ORDER BY id')]
def moment(minute): return origin + dt.timedelta(minutes=minute)
def tick(w, minute, settings=cfg):
    with patch.object(a.time,'time',return_value=moment(minute).timestamp()):
        w.tick_films(settings,moment(minute))
        if w._film_thread: w._film_thread.join(timeout=10)
        assert not w._film_thread or not w._film_thread.is_alive()
def evaluation(first=11,last=13,ongoing=True):
    return {'score':8,'phenomena':['cervanky'],'phenomenon':'Červánky','description':'Na konci filmu se objevují červánky.',
            'evolution':'Barvy se mění z modré do červené.','trend':'nastupuje','timelapse':8,
            'event_start_frame':first,'event_end_frame':last,'ongoing':ongoing}
try:
    with patch.object(a,'fetch_snapshot',return_value=jpg), patch.object(a,'storage_ready',return_value=True), \
         patch.object(a,'deliver',side_effect=RuntimeError('mail unavailable')), \
         patch.object(a,'public_urls',return_value={'atmovio':'','frigate':''}), \
         patch.object(a,'camera_info',return_value={'ip':'','via':''}), \
         patch.object(a,'ai_evaluate',side_effect=lambda *args:(evaluation(), '{}')) as model:
        w=a.AtmovioWatcher()
        for minute in range(0,31,5): tick(w,minute)
        assert model.call_count==0 and len(rows('evaluations'))==0
        assert len(rows('ai_films'))==2 and all(len(a.film_frames(r))==7 for r in rows('ai_films'))
        w=a.AtmovioWatcher() # simulate service restart: no Python sampling state survives
        for minute in range(35,60,5): tick(w,minute)
        assert model.call_count==0
        tick(w,60); tick(w,60.4) # one ready film per tick, all cameras sampled first
        assert model.call_count==2
        complete=[f for f in rows('ai_films') if f['status']=='done']; active=[f for f in rows('ai_films') if f['status']=='collecting']
        assert len(complete)==2 and all(len(a.film_frames(f))==13 for f in complete)
        assert len(active)==2 and all(len(a.film_frames(f))==1 for f in active)
        assert a.film_frames(complete[0])[-1]['ts']==a.film_frames(active[0])[0]['ts']
        assert a.film_frames(complete[0])[-1]['image']!=a.film_frames(active[0])[0]['image']
        assert model.call_args.args[0]['_film_batch'] is True
        for f in complete:
            e=next(e for e in rows('evaluations') if e['id']==f['evaluation_id'])
            context=json.loads(e['film_context']); assert context['frames']==13 and context['start']==origin.timestamp()
            assert context['event_start']==moment(45).timestamp() # one sample before observed onset at 50
            path=Path(cfg['snapshot_dir'])/e['image'];sheet=path.with_name(path.stem+'_strip.jpg')
            assert sheet.exists() and Image.open(sheet).size==(1920,1200)
        jobs=rows('auto_exports');assert len(jobs)==2 and all(j['film_open']==1 for j in jobs)
        assert jobs[0]['start_ts']==moment(43).timestamp() and jobs[0]['end_ts']==moment(63).timestamp()
        assert all(j['due_ts']>moment(120).timestamp() for j in jobs)
        ok('5-minute samples, one call after 60 minutes, per-camera isolation, restart persistence, identical owned boundary samples')
        ok('Stored contact sheet, 13 evidence frames, event onset padding, automatic clips survive email failure')
        # The same event crosses the hour and ends at 01:20. The next film extends the pending job.
        model.side_effect=lambda *args:(dict(evaluation(1,5,False), description='Červánky po dvaceti minutách odezněly.',trend='odeznívá'), '{}')
        for minute in range(65,121,5):tick(w,minute)
        tick(w,120.4)
        jobs2=rows('auto_exports');assert len(jobs2)==2 and all(j['film_open']==0 for j in jobs2)
        assert jobs2[0]['start_ts']==jobs[0]['start_ts'] and jobs2[0]['end_ts']==moment(88).timestamp()
        assert 'odezněly' in json.loads(jobs2[0]['ai_context'])['description']
        assert model.call_count==4
        with patch.object(a.time,'time',return_value=moment(121).timestamp()),patch.object(a,'recording_state',return_value='ok'),patch.object(a,'frigate_start_export',return_value='offline-fixture-export'):
            a.process_auto_exports(cfg)
        exports=rows('exports');assert len(exports)==2 and 'odezněly' in json.loads(exports[0]['ai_context'])['description']
        ok('Late onset crosses film boundary; next film extends one clip and ends at observed event end; aggregated evidence retained in export')
        # Daily limit blocks evaluation, never sample acquisition.
        limited=copy.deepcopy(cfg);limited['ai']['daily_limit']=1
        for minute in range(125,181,5):tick(w,minute,limited)
        assert model.call_count==4 and len([f for f in rows('ai_films') if f['status']=='ready'])==2
        assert all(len(a.film_frames(f))==13 for f in rows('ai_films') if f['status']=='ready')
        ok('Exhausted daily quota still collects complete films and queues evaluation')
        # Failure / restart / bounded retries retain the same evidence.
        model.side_effect=RuntimeError('provider unavailable')
        tick(w,182); w=a.AtmovioWatcher();tick(w,184);tick(w,186)
        failed=[f for f in rows('ai_films') if f['status']=='failed']; assert failed and failed[0]['attempts']==3
        assert len(a.film_frames(failed[0]))==13
        ok('Failed provider retains full movie across restart and retries at most three times')
        # No fabricated gap-spanning movie after an outage.
        old_active=[f for f in rows('ai_films') if f['status']=='collecting']
        tick(w,240,limited)
        for f in old_active:
            now_f=next(r for r in rows('ai_films') if r['id']==f['id'])
            assert now_f['status']!='collecting' and now_f['end_ts']<=moment(186).timestamp()
        ok('Long sampling gaps close partial sequences and start a fresh film')
        # Day-only transition closes a partial multi-frame film even before its configured end.
        with patch.object(a,'is_daytime',return_value=False): tick(w,245,limited)
        assert not [f for f in rows('ai_films') if f['status']=='collecting']
        ok('Daylight cutoff flushes partial films; single-frame sequences remain explicitly incomplete')
        # Prompt semantics and invalid boundary fallback are deterministic, not trusted model dates.
        prompt=a.build_prompt(dict(cfg['ai'],_film_batch=True),12)
        assert 'CELÝ průběh' in prompt and 'Hodnoť aktuální snímek' not in prompt and 'event_start_frame' in prompt
        fake=dict(complete[0], items=a.selected_film_frames(a.film_frames(complete[0])))
        for bad in ({},{'event_start_frame':-1,'event_end_frame':999,'ongoing':False},{'event_start_frame':2,'event_end_frame':1}):
            ctx=a.film_context(fake,bad);assert not ctx['bounds_valid'] and ctx['ongoing'] and ctx['event_start']==origin.timestamp()
        many=[{'ts':i,'image':str(i)} for i in range(181)]; selected=a.selected_film_frames(many)
        assert len(selected)==36 and selected[0]==many[0] and selected[-1]==many[-1]
        ok('Whole-film prompt, validated event indices, conservative fallback, bounded 36-frame AI sheet')
        detail_cfg=copy.deepcopy(cfg);detail_cfg['ai']['strip']['max_frames']=9
        assert a.film_collection_plan(detail_cfg['ai'])==(5,40)
        for minute in range(0,41,5): a.collect_ai_film(detail_cfg,'detail_test',moment(minute))
        detail_film=next(f for f in rows('ai_films') if f['camera']=='detail_test' and f['status']=='ready')
        detail_frames=a.film_frames(detail_film)
        assert len(detail_frames)==9 and detail_film['end_ts']-detail_film['start_ts']==2400
        sheet=Image.open(io.BytesIO(a.make_ai_film(detail_cfg,detail_frames)))
        assert sheet.size==(2160,1305)
        next_detail=next(f for f in rows('ai_films') if f['camera']=='detail_test' and f['status']=='collecting')
        assert a.film_frames(next_detail)[0]['ts']==detail_frames[-1]['ts']
        ok('Nine-frame limit ends a 60-minute request at 40 minutes, larger evidence and continuous next film')

        # Slow inference must not block the next camera sample.
        import threading
        entered, release = threading.Event(), threading.Event()
        slow_cfg=copy.deepcopy(cfg); slow_cfg['ai']['cameras']=['slow']; slow_cfg['ai']['auto_export']['enabled']=False
        for minute in range(300,360,5): a.collect_ai_film(slow_cfg,'slow',moment(minute))
        def slow_model(*args):
            entered.set(); assert release.wait(5)
            return evaluation(), '{}'
        model.side_effect=slow_model
        slow=a.AtmovioWatcher()
        with patch.object(a.time,'time',return_value=moment(360).timestamp()):
            slow.tick_films(slow_cfg,moment(360))
            try:
                assert entered.wait(5)
                slow.tick_films(slow_cfg,moment(365))
                collecting=next(f for f in rows('ai_films') if f['camera']=='slow' and f['status']=='collecting')
                assert len(a.film_frames(collecting))==2
            finally:
                release.set();slow._film_thread.join(10)
        assert not slow._film_thread.is_alive()
        ok('Background inference does not block the next scheduled sample')
        # A completed evaluation recovered after a restart must not duplicate a source clip.
        before_jobs=len(rows('auto_exports'))
        recovery=complete[0]
        with a.db() as con: con.execute("UPDATE ai_films SET status='ready' WHERE id=?",(recovery['id'],))
        calls=model.call_count
        tick(a.AtmovioWatcher(),250,limited) # quota prevents even recovery; lifting it resumes safely
        tick(a.AtmovioWatcher(),250,cfg)
        assert model.call_count==calls and len(rows('auto_exports'))==before_jobs
        assert next(f for f in rows('ai_films') if f['id']==recovery['id'])['status']=='done'
        ok('Recovery of recorded completion does not repeat AI calls or duplicate exports')

    # A quiet following film closes the previous range; a missing follow-up has a bounded timeout.
    episode_cfg=copy.deepcopy(cfg);episode_cfg['ai']['auto_export']['cameras']=['episode']
    def event_result(n, ongoing=True):
        begin=moment(400+n*60).timestamp();end=begin+3600
        context={'mode':'batch','film_id':900+n,'start':begin,'end':end,'event_start':begin,'event_end':end,'frames':13,
                 'duration_min':60,'sample_min':5,'ongoing':ongoing,'evolution':'Doložený vývoj'}
        result={'camera':'episode','ts':moment(460+n*60).isoformat(),'score':8,'phenomena':['cervanky'],'description':'Jev', 'film_context':json.dumps(context)}
        a.watcher.record(result);return result
    first=event_result(0)
    a.schedule_film_export(episode_cfg,first,['cervanky'])
    job=rows('auto_exports')[-1]
    with patch.object(a.time,'time',return_value=job['due_ts']-1),patch.object(a,'recording_state',return_value='ok'),patch.object(a,'frigate_start_export',return_value='timeout-export') as export:
        a.process_auto_exports(episode_cfg);assert export.call_count==0
    with patch.object(a.time,'time',return_value=job['due_ts']+1),patch.object(a,'recording_state',return_value='ok'),patch.object(a,'frigate_start_export',return_value='timeout-export') as export:
        a.process_auto_exports(episode_cfg);assert export.call_count==1
        assert export.call_args.args[2:4]==(job['start_ts'],job['end_ts'])
    a.schedule_film_export(episode_cfg,event_result(2),['cervanky'])
    job=rows('auto_exports')[-1]
    a.schedule_film_export(episode_cfg,event_result(3),[])
    closed=rows('auto_exports')[-1];assert not closed['film_open'] and closed['end_ts']==job['end_ts']
    a.schedule_film_export(episode_cfg,event_result(4),['cervanky'])
    for i in range(5,10):a.schedule_film_export(episode_cfg,event_result(i),['cervanky'])
    assert not rows('auto_exports')[-1]['film_open']
    ok('Missing continuation exports only known bounds; quiet film closes the clip; six-hour event parts are bounded')
    # Motion alone can trigger a film clip only when explicitly enabled.
    quiet=event_result(20, ongoing=False)
    quiet.update(score=3, phenomena=[], phenomenon='Běžná obloha', timelapse=8)
    count=len(rows('auto_exports'))
    a.schedule_film_export(episode_cfg,quiet,[])
    assert len(rows('auto_exports'))==count
    episode_cfg['ai']['auto_export'].update(timelapse_enabled=True,timelapse_threshold=8)
    a.schedule_film_export(episode_cfg,dict(quiet,timelapse=7),[])
    a.schedule_film_export(episode_cfg,dict(quiet,timelapse=None),[])
    assert len(rows('auto_exports'))==count
    a.schedule_film_export(episode_cfg,quiet,[])
    job=rows('auto_exports')[-1];context=json.loads(quiet['film_context'])
    assert len(rows('auto_exports'))==count+1 and job['film_hits']=='timelapse'
    assert job['start_ts']==context['start']-120 and job['end_ts']==context['end']+180
    assert 'Zajímavý časosběr' in job['name']
    a.schedule_film_export(episode_cfg,quiet,[])
    assert len(rows('auto_exports'))==count+1
    single=event_result(21);single.update(timelapse=9)
    single['film_context']=json.dumps(dict(json.loads(single['film_context']),frames=1))
    a.schedule_film_export(episode_cfg,single,[])
    assert len(rows('auto_exports'))==count+1
    form_cfg=copy.deepcopy(episode_cfg)
    a.apply_ai_form({'scope':'ai','ax_timelapse_enabled':'on','ax_timelapse_threshold':'9'},form_cfg,['episode'])
    assert form_cfg['ai']['auto_export']['timelapse_threshold']==9
    a.apply_export_form({'ax_enabled':'on','ax_cam_episode':'on'},form_cfg,['episode'])
    assert form_cfg['ai']['auto_export']['timelapse_enabled'] is True
    assert form_cfg['ai']['auto_export']['timelapse_threshold']==9
    a.apply_ai_form({'scope':'ai','ax_timelapse_threshold':'6'},form_cfg,['episode'])
    assert form_cfg['ai']['auto_export']['timelapse_enabled'] is False
    assert form_cfg['ai']['auto_export']['timelapse_threshold']==6
    try:
        a.apply_ai_form({'scope':'ai','ax_timelapse_threshold':'11'},form_cfg,['episode'])
        raise AssertionError('Invalid threshold accepted')
    except ValueError: pass
    ok('Opt-in timelapse triggers below visual threshold, respects threshold, film evidence, bounds and deduplication')
    # Keep export-count checks below scoped to the original two cameras.
    with a.db() as con:
        con.execute("DELETE FROM exports WHERE camera='episode'")
        con.execute("DELETE FROM auto_exports WHERE camera='episode'")
        con.execute("DELETE FROM evaluations WHERE camera='episode'")
    # Render actual completed, failed and in-progress data with authentication and CSRF.
    with patch.object(a,'storage_ready',return_value=True),patch.object(a,'recording_state',return_value='none'),patch.object(a,'run',return_value=(1,'')),patch.object(a,'disk_health_warning',return_value=''),patch('requests.sessions.Session.request',side_effect=RuntimeError('HTTP disabled in fixture')):
        client=TestClient(a.app,raise_server_exceptions=True)
        assert client.get('/ai/films/1').url.path=='/login'
        import re
        token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
        client.post('/login',data={'password':'isolated-film-fixture','csrf_token':token})
        token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/ai/films/1').text)[1]
        for f in rows('ai_films'):
            r=client.get('/ai/films/'+str(f['id']));assert r.status_code==200
            if f['status']=='done':assert 'Přesný obrázek odeslaný AI' in r.text
        assert client.get('/history').status_code==200
        assert client.get('/ai/films/9999',follow_redirects=False).status_code==303
        fid=failed[0]['id']
        assert client.post(f'/ai/films/{fid}/retry').status_code==403
        assert client.post(f'/ai/films/{fid}/retry',data={'csrf_token':token},follow_redirects=False).status_code==303
        assert next(f for f in rows('ai_films') if f['id']==fid)['status']=='ready'
        retained=Path(cfg['snapshot_dir'])/a.film_frames(active[0])[0]['image']
        first=complete[0]
        assert client.post(f'/ai/films/{first["id"]}/delete',data={'csrf_token':token},follow_redirects=False).status_code==303
        assert retained.exists() and len(rows('exports'))==2
        assert not (Path(cfg['snapshot_dir'])/a.film_frames(first)[0]['image']).exists()
        ok('Film viewer renders all states; authentication/CSRF, retry, deletion and independent adjacent evidence')
    print(json.dumps({'version':a.APP_VERSION,'checks':checks},ensure_ascii=False,indent=2))
finally:
    shutil.rmtree(base,ignore_errors=True)
