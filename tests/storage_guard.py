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
    assert probe.sample() is False and process.killed and '4 sekund' in probe.reason
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
