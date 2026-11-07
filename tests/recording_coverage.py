"""Manual clip saving accepts segment seams and offers a usable outage confirmation."""
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

base = Path(tempfile.mkdtemp(prefix='atmovio-coverage-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'coverage-fixture-password'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/atmovio'))
import app as a
from fastapi.testclient import TestClient

try:
    a.db_init()
    cfg = a.load_config()
    client = TestClient(a.app)
    token = re.search(r'name="csrf_token" value="([^"]+)"', client.get('/login').text)[1]
    client.post('/login', data={'csrf_token': token, 'password': os.environ['ATMOVIO_ADMIN_PASSWORD']})
    start = int(time.time()) - 7200
    end = start + 1000
    form = dict(from_time=a.clip_local(cfg, start), to_time=a.clip_local(cfg, end), csrf_token=token)
    seams = [[start+i*10, start+(i+1)*10-.4] for i in range(100)]
    # Many normal fragment seams add up to 40 seconds, but are not an outage.
    assert end-start-sum(b-x for x,b in seams) > 39
    assert a.recording_gaps(seams, start, end) == []
    assert a.recording_gaps([[start+.8,end-.8]], start, end) == []
    with patch.object(a, 'frigate_cameras', return_value=['east']), \
         patch.object(a, 'storage_ready', return_value=True), \
         patch.object(a, 'run', return_value=(1,'')), \
         patch.object(a, 'camera_recording_spans', return_value=seams) as coverage, \
         patch.object(a, 'frigate_start_export', return_value='coverage-export') as export, \
         patch('requests.sessions.Session.request', side_effect=RuntimeError('External HTTP disabled')):
        form['csrf_token'] = re.search(r'name="csrf_token" value="([^"]+)"', client.get('/camera/east/recording').text)[1]
        r = client.post('/camera/east/recording', data=form, follow_redirects=False)
        assert r.status_code == 303 and r.headers['location'].startswith('/recording/')
        assert export.call_args.args[2:4] == (start,end)
        export.reset_mock()
        coverage.return_value = [[start,start+400],[start+415,end]]
        # A real outage is shown with a direct save action, preserving both markers and AI choice.
        r = client.post('/camera/east/recording', data=dict(form, metadata='1', allow_gaps='0'))
        assert r.status_code == 200 and 'Uložit dostupné části' in r.text and '15 s' in r.text
        assert f'value="{form["from_time"]}"' in r.text and f'value="{form["to_time"]}"' in r.text
        assert 'name="metadata" value="1"' in r.text and 'name="allow_gaps" value="1"' in r.text
        assert 'Upravit výběr OD–DO' in r.text
        export.assert_not_called()
        r = client.post('/camera/east/recording', data=dict(form, allow_gaps='1'), follow_redirects=False)
        assert r.status_code == 303 and r.headers['location'].startswith('/recording/')
        assert export.call_count == 1
        export.reset_mock()
        # Recheck availability at confirmation time; never create an empty export.
        coverage.return_value = []
        r = client.post('/camera/east/recording', data=dict(form, allow_gaps='1'), follow_redirects=False)
        assert '/recording?' in r.headers['location']
        export.assert_not_called()
        coverage.side_effect = TimeoutError('private upstream detail')
        r = client.post('/camera/east/recording', data=form, follow_redirects=False)
        assert '/recording?' in r.headers['location']
        export.assert_not_called()
    # Range text retains both dates for midnight-spanning clips.
    assert '02. 01. 2026' in a.clip_range_label(dict(tz='UTC'), 1767311940, 1767312060)
    print('PASS: fractional seams, real outage confirmation, retained selection, explicit consent, fresh coverage and offline safety')
finally:
    shutil.rmtree(base)
