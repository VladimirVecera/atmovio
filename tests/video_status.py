"""Episode membership and truthful video lifecycle; no hardware or external services."""
import os, sys, tempfile, json, shutil, datetime as dt
from pathlib import Path
from unittest.mock import patch
base = Path(tempfile.mkdtemp(prefix='atmovio-status-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'fixture-password-only'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/atmovio'))
import app as a
try:
    a.db_init(); cfg = a.load_config()
    cfg['ai']['auto_export'].update(enabled=True, cameras=['west'])
    now = 1800954000
    def evidence(rid, end):
        return dict(id=rid, camera='west', description='Fixture', film_context=json.dumps(dict(mode='batch', start=end-1800, end=end, event_start=end-1800, event_end=end, ongoing=True, duration_min=30, sample_min=5, frames=7)))
    rows = [dict(id=i, camera='west') for i in range(1,5)]
    with patch.object(a.time, 'time', return_value=now), patch.object(a, 'list_videos', return_value=[]):
        for i in range(1,4): a.schedule_film_export(cfg, evidence(i, now+(i-1)*1800), ['cervanky'])
        with a.db() as con: jobs = [dict(r) for r in con.execute('SELECT * FROM auto_exports')]
        assert len(jobs) == 1 and a.export_detection_ids(jobs[0]) == {1,2,3}
        a.schedule_film_export(cfg, evidence(2, now+1800), ['cervanky'])
        assert len(a.pending_auto_exports(cfg)) == 1
        assert a.pending_auto_exports(cfg, 2)
        states = a.detection_video_statuses(cfg, rows)
        assert states[1] == states[2] == states[3] and states[1]['active']
        assert states[4]['title'] == 'Video není naplánované'
        with a.db() as con: con.execute("UPDATE auto_exports SET due_ts=?", (now-1,))
        with patch.object(a, "recording_state", return_value="offline"):
            a.process_auto_exports(cfg)
        assert 'Frigate neodpovídá' in a.detection_video_statuses(cfg, rows)[2]['detail']
        with a.db() as con: con.execute("UPDATE auto_exports SET status='failed',message='Disk nedostupný'")
        assert a.detection_video_statuses(cfg, rows)[2]['detail'] == 'Disk nedostupný'
        with a.db() as con: con.execute("UPDATE auto_exports SET status='done',message='export-fixture'")
        video = dict(frigate_id='export-fixture', detection_id=1, ready=False, expired=False, stuck=False, in_progress=True)
        with patch.object(a, 'list_videos', return_value=[video]):
            assert a.detection_video_statuses(cfg, rows)[2]['title'] == 'Vytváří se video'
            video.update(ready=True, in_progress=False)
            assert a.detection_video_statuses(cfg, rows)[2]['title'] == 'Video je uložené'
            video.update(ready=False, stuck=True)
            assert a.detection_video_statuses(cfg, rows)[2]['tone'] == 'failed'
        # Legacy context retains first and most recent known member, without inventing links.
        assert a.export_detection_ids(dict(detection_id=10, ai_context='{"id":12}')) == {10,12}
        assert a.export_detection_ids(dict(detection_id=10, ai_context='bad json')) == {10}
    print('PASS: shared episode membership, retry deduplication, unrelated detection, pending/offline/failed/rendering/ready/interrupted states, legacy evidence')
finally:
    shutil.rmtree(base)
