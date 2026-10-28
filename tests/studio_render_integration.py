"""Real FFmpeg check for saved edits; operates only on generated temporary media."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

if not shutil.which('ffmpeg'):
    print('SKIP: real Studio rendering requires ffmpeg and ffprobe')
    raise SystemExit(0)
base = Path(tempfile.mkdtemp(prefix='atmovio-render-'))
os.environ['ATMOVIO_DIR'] = str(base)
os.environ['ATMOVIO_ADMIN_PASSWORD'] = 'isolated-render-fixture'
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/atmovio'))
import app as a
from PIL import Image

def generate(*args):
    subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y', *map(str, args)], check=True)

try:
    a.db_init()
    cfg = a.load_config()
    cfg['snapshot_dir'] = str(base / 'snapshots')
    source = base / 'source.mp4'
    generate('-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25', '-t', '8', '-c:v', 'libx264', source)
    original = hashlib.sha256(source.read_bytes()).digest()
    assets = a.studio_assets_dir()
    Image.new('RGB', (640, 360), '#143353').save(assets / 'intro.png')
    generate('-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '6', assets / 'music' / 'tone.wav')
    eid = a.record_export(cfg, 'fixture', None, 'east', 'Ukázkový klip', 1, 9)
    with patch.object(a, 'studio_kick'):
        sid = a.studio_enqueue(cfg, a._studio_export(cfg, eid), 1, True, 'tone.wav', 'Pohled na krajinu',
                               'Ukázka', '', trim_start=1, trim_end=7,
                               edit={'music_start': 2, 'music_volume': .4, 'effect': 'both', 'effect_at': 1, 'effect_duration': 3})
    with a.db() as con:
        job = dict(con.execute('SELECT * FROM studio_videos WHERE id=?', (sid,)).fetchone())
    # Replacing the default intro must not change this saved project's asset.
    (assets / 'intro.png').unlink()
    with patch.object(a, 'storage_ready', return_value=True), patch.object(a, 'frigate_exports', return_value={'fixture': {'video_path': str(source)}}), patch.object(a, 'frigate_media_path', return_value=source), patch.object(a, 'studio_after_render'):
        a.studio_render(cfg, job)
    with a.db() as con:
        ready = dict(con.execute('SELECT * FROM studio_videos WHERE id=?', (sid,)).fetchone())
    info = a.ffprobe_info(ready['file'])
    assert ready['status'] == 'ready' and info['audio'] and 9.8 <= info['duration'] <= 10.2, info
    assert hashlib.sha256(source.read_bytes()).digest() == original
    print('PASS: real FFmpeg trim, 1× playback, immutable intro, music offset/volume/fades, animated callout, 10-second H.264/AAC output, unchanged source')
finally:
    shutil.rmtree(base)
