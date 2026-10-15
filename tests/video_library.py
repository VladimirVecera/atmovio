"""Ready-only library, live progress and scoped bulk deletion; all media/services are fixtures."""
import contextlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

base = Path(tempfile.mkdtemp(prefix='atmovio-library-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'library-fixture-only'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/atmovio'))
import app as a
from fastapi.testclient import TestClient

try:
    a.db_init()
    cfg = a.load_config()
    cfg.update(snapshot_dir=str(base/'snapshots'), recordings_path=str(base/'recordings'), frigate_config_path=str(base/'frigate.yml'))
    a.save_config(cfg)
    media = base/'source.mp4'; media.write_bytes(b'local video fixture')
    empty = base/'empty.mp4'; empty.touch()
    def export(fid, parent=None, job=None):
        eid = a.record_export(cfg, fid, None, 'camera', fid, 100, 3700)
        with a.db() as con:
            con.execute('UPDATE exports SET event_parent_id=?,event_job_id=? WHERE id=?', (parent, job, eid))
        return eid
    def studio(eid, status='ready', yt=''):
        with a.db() as con:
            return con.execute("INSERT INTO studio_videos(export_id,camera,name,speed,title,status,file,created,yt_status) VALUES(?,'camera','Video',120,'Večerní obloha',?,?,datetime('now'),?)", (eid,status,str(media),yt)).lastrowid
    with a.db() as con:
        job = con.execute("INSERT INTO auto_exports(detection_id,camera,name,start_ts,end_ts,due_ts,created,status) VALUES(1,'camera','Událost',100,3700,4000,datetime('now'),'done')").lastrowid
        pending = con.execute("INSERT INTO auto_exports(detection_id,camera,name,start_ts,end_ts,due_ts,created,status,film_open) VALUES(2,'camera','Pokračující jev',100,3700,9999999999,datetime('now'),'pending',1)").lastrowid
    main = export('final-event', job=job)
    part = export('hidden-part', parent=job)
    manual = export('manual-ready')
    working = export('working')
    missing = export('missing')
    zero = export('empty')
    open_part = export('open-part', parent=pending)
    orphan_part = export('orphan-part', parent=999)
    fr = {fid:dict(video_path=str(media),in_progress=False) for fid in ['final-event','hidden-part','manual-ready','working','open-part','orphan-part']}
    fr['working']['in_progress'] = True
    fr['empty'] = dict(video_path=str(empty),in_progress=False)
    sid = studio(main, 'rendering')
    uid = studio(manual, yt='uploading')
    a._studio_progress[sid] = 37
    a._yt_progress[uid] = 64
    a._yt_ack_time[uid] = a.time.time()
    a._yt_eta[uid] = 120
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch('requests.sessions.Session.request', side_effect=AssertionError('Unexpected network')))
        stack.enter_context(patch('subprocess.run', return_value=subprocess.CompletedProcess([],1,'','Offline fixture')))
        stack.enter_context(patch.object(a,'frigate_exports',return_value=fr))
        stack.enter_context(patch.object(a,'frigate_media_path',side_effect=lambda p:Path(p) if p else None))
        stack.enter_context(patch.object(a,'export_thumb_path',return_value=None))
        client=TestClient(a.app)
        assert client.get('/videos/activity',follow_redirects=False).status_code==303
        assert client.post('/videos/delete-all',data={'confirm':'delete-all'},follow_redirects=False).status_code in (303,403)
        token=re.search(r'name="csrf_token" value="([^"]+)"',client.get('/login').text)[1]
        assert client.post('/login',data={'password':os.environ['ATMOVIO_ADMIN_PASSWORD'],'csrf_token':token},follow_redirects=False).status_code==303
        page=client.get('/videos'); assert page.status_code==200
        token=re.search(r'name="csrf_token" value="([^"]+)"',page.text)[1]
        gallery=re.search(r'<div class="gallery videos">(.*?)</div><p class="hint">',page.text,re.S)[1]
        assert f'id="v{main}"' in gallery and f'id="v{manual}"' in gallery
        for eid in [part,working,missing,zero,open_part,orphan_part]:
            assert f'id="v{eid}"' not in gallery
        assert 'Průběžné části' not in page.text and '/parts' not in page.text
        assert 'Smazat všechna AI videa' in page.text
        review=client.get('/videos/delete-all')
        assert review.status_code==200 and 'Tuto akci nelze vrátit' in review.text
        assert 'name="csrf_token"' in review.text and '>Zrušit</a>' in review.text
        assert not a._video_bulk_state
        assert '37 %' in page.text and '64 %' in page.text
        assert 'working' in page.text  # Manual exports also have visible status.
        state=client.get('/videos/activity').json()
        assert '37 %' in state['html'] and '64 %' in state['html']
        a._studio_progress[sid]=52
        updated=client.get('/videos/activity').json()
        assert '52 %' in updated['html'] and updated['revision']==state['revision']
        with a.db() as con:con.execute("UPDATE studio_videos SET status='ready' WHERE id=?",(sid,))
        assert client.get('/videos/activity').json()['revision']!=state['revision']
        a._yt_progress.pop(uid)
        html=client.get('/videos/activity').json()['html']
        assert 'YouTube potvrdil první část' in html and 'value="0"' not in html
        with a.db() as con:con.execute("UPDATE exports SET name=? WHERE id=?",('<script>alert(1)</script>',working))
        assert '<script>alert(1)</script>' not in client.get('/videos/activity').json()['html']
        assert client.post('/videos/delete-all',data={'confirm':'delete-all'}).status_code==403
        assert client.post('/videos/delete-all',data={'csrf_token':token},follow_redirects=False).status_code==400
        # Capture the fixed deletion snapshot instead of launching a thread in this test.
        with patch.object(a.threading,'Thread') as thread:
            assert client.post('/videos/delete-all',data={'csrf_token':token,'confirm':'delete-all'},follow_redirects=False).status_code==303
            thread.return_value.start.assert_called_once()
            captured=thread.call_args.kwargs['args'][1]
            client.post('/videos/delete-all',data={'csrf_token':token,'confirm':'delete-all'},follow_redirects=False)
            assert thread.call_count==1
        after_click=export('created-after-click')
        # Any part in use protects its whole parent group. An API failure stays retryable.
        studio(part,'rendering')
        with patch.object(a.requests,'delete',side_effect=lambda url,**kw:SimpleNamespace(ok=not url.endswith('/missing'),status_code=503 if url.endswith('/missing') else 200)) as delete:
            a.delete_all_ai_videos(cfg,captured)
        with a.db() as con:
            kept={r[0] for r in con.execute('SELECT id FROM exports')}
            assert con.execute('SELECT COUNT(*) FROM studio_videos').fetchone()[0]==3
            assert con.execute('SELECT status FROM auto_exports WHERE id=?',(pending,)).fetchone()[0]=='pending'
        assert {main,part,manual,missing,open_part,after_click}==kept
        assert not a._video_bulk_state['active'] and a._video_bulk_state['deleted']==3
        assert not a._video_bulk_lock.locked()
        assert all('/api/export/' in call.args[0] for call in delete.call_args_list)
        # A stale Studio form cannot queue a consumer after its source has been deleted.
        with patch.object(a,'studio_kick') as kick:
            try:
                a.studio_enqueue(cfg,dict(id=working,camera='camera',name='Deleted'),20,False,'','','Title','')
                raise AssertionError('Deleted source was accepted')
            except ValueError:
                pass
            kick.assert_not_called()
        # Retry deletes the parent and its parts once all consumers finish; no rows reappear.
        with a.db() as con:
            con.execute("UPDATE studio_videos SET status='ready',yt_status='' ")
            retry=[dict(r) for r in con.execute('SELECT * FROM exports')]
        a._video_bulk_lock.acquire()
        with patch.object(a.requests,'delete',return_value=SimpleNamespace(ok=True,status_code=200)):
            a.delete_all_ai_videos(cfg,retry)
        with a.db() as con:assert [r[0] for r in con.execute('SELECT id FROM exports')]==[open_part]
    print('PASS: ready-only final/manual gallery; hidden safety parts and zero-byte/unavailable files; actual render/upload progress; escaping; auth/CSRF/confirmation; fixed bulk snapshot; busy/open-event protection; partial failure and retry; no raw/YouTube deletion')
finally:
    shutil.rmtree(base)
