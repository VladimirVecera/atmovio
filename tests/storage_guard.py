"""Offline storage guard diagnostics: no mounts, writes to disks or real processes."""
import importlib.util
import io
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard_under_test', Path(__file__).resolve().parents[1] / 'src/atmovio/storage_guard.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

class Process:
    def __init__(self, rc, message=b''):
        self.rc, self.stderr, self.killed = rc, io.BytesIO(message), False
    def poll(self): return self.rc
    def kill(self): self.killed = True

probe = g.Probe()
probe.process = Process(1, 'Read-only file system: /mnt/nvr'.encode())
assert probe.sample() is False and 'Read-only file system' in probe.reason
probe.process = Process(0)
assert probe.sample() is True and probe.reason == 'HDD je zapisovatelný.'
probe.process = process = Process(None)
with patch.object(g.time, 'monotonic', return_value=10):
    assert probe.sample() is None and not process.killed
with patch.object(g.time, 'monotonic', return_value=31):
    assert probe.sample() is False and process.killed and '30 sekund' in probe.reason
    assert probe.process is process  # Never spawn another probe while a hung process still exists.
with tempfile.TemporaryDirectory() as temp:
    with patch.object(g, 'STATUS', Path(temp) / 'status.json'), patch.object(g, '_last_publish', {'key': None, 'at': 0}), patch('builtins.print') as output:
        g.publish('recording', 'OK', '1234567890123456789')
        state=json.loads(g.STATUS.read_text())
        assert state['restart_request']=='1234567890123456789'
        g.publish('error', 'Read-only file system')
        assert json.loads(g.STATUS.read_text())['mode']=='error'
        assert output.call_count==2
print('Storage diagnostics, bounded probes and exact restart acknowledgement OK')

with tempfile.TemporaryDirectory() as temp:
    root=Path(temp); sky=root/'atmovio';sky.mkdir();system=root/'systemd';system.mkdir()
    source=root/'config.yml';source.write_text('cameras: {}\n')
    compose=root/'compose.yml'
    service=g.media_config({},True)
    compose.write_text(g.dump({'services':{'frigate':service}}))
    (system/'atmovio.service').write_text('[Service]\n')
    with patch.object(g,'NVR',root),patch.object(g,'SKY',sky),patch.object(g,'SYSTEMD',system),patch.object(g,'SOURCE_CONFIG',source),patch.object(g,'LIVE_CONFIG',root/'live.yml'),patch.object(g,'COMPOSE',compose),patch.object(g,'command',return_value='true') as commands,patch.object(g,'publish'):
        g.install()
        assert g.read_yaml(compose)['services']['frigate']['environment']['CONFIG_FILE']=='/config/config.yml'
        guard=g.Guard();guard.adopt_running('mount-1');guard.reconcile(None,'mount-1')
        assert guard.mode=='recording'
        assert not any('--force-recreate' in call.args[0] for call in commands.call_args_list)
print('Managed upgrades preserve recording and adopt the running recorder without recreation OK')
