"""Simulate config validation and rollback without Docker, root or service changes."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('upgrade',Path(__file__).resolve().parents[1]/'src/atmovio/frigate_upgrade.py')
u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
base=Path(tempfile.mkdtemp(prefix='frigate-upgrade-test-'))
try:
    u.ROOT=base;u.COMPOSE=base/'docker-compose.yml';u.CONFIG=base/'config';u.CONFIG.mkdir()
    original='services:\n  frigate:\n    image: ghcr.io/blakeblackshear/frigate:0.17.2-standard-arm64\n    volumes: ["/mnt/nvr/frigate:/media/frigate"]\n'
    u.COMPOSE.write_text(original)
    (u.CONFIG/'config.yml').write_text('mqtt:\n  enabled: false\n')
    (u.CONFIG/'frigate.db').write_bytes(b'old-database')
    (u.CONFIG/'frigate.db-wal').write_bytes(b'old-wal')
    backup=base/'backup'
    with patch.object(u,'run',return_value='') as run,patch.object(u.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout='invalid fixture config')):
        try:u.prepare(backup);raise AssertionError('invalid config accepted')
        except RuntimeError:pass
        assert all(call.args[0][:2]!=['docker','stop'] for call in run.call_args_list)
        assert not (backup/'prepared.json').exists() and u.COMPOSE.read_text()==original
    with patch.object(u,'run',return_value=''),patch.object(u.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout='valid')):
        u.prepare(backup)
    assert (backup/'prepared.json').exists()
    calls=[]
    def command(args,**kwargs):
        calls.append(args)
        if args[:2]==['docker','inspect']:return 'true'
        if args[:2]==['docker','compose'] and 'up' in args and u.IMAGE in u.COMPOSE.read_text():
            (u.CONFIG/'frigate.db').write_bytes(b'new-incompatible-database')
        return ''
    with patch.object(u,'run',side_effect=command),patch.object(u,'api',side_effect=lambda name:'0.17.2-fixture' if name=='version' else {'cameras':{'east':{'camera_fps':5}}}),patch.object(u,'wait_ready',side_effect=[RuntimeError('camera offline'),None]):
        try:u.upgrade(backup);raise AssertionError('broken recorder accepted')
        except RuntimeError:pass
    assert u.COMPOSE.read_text()==original
    assert (u.CONFIG/'frigate.db').read_bytes()==b'old-database'
    assert (u.CONFIG/'frigate.db-wal').read_bytes()==b'old-wal'
    assert (backup/'rolled-back').exists()
    assert any('/mnt/nvr' in v for v in original.splitlines())
    assert not any('/mnt/nvr' in arg for call in calls for arg in call)
    with patch.object(u,'run') as run:u.rollback(backup);run.assert_not_called()
    print('PASS: invalid config never interrupts recording, failed upgrade restores compose/config/SQLite including WAL, idempotent rollback, media untouched')
finally:shutil.rmtree(base)
