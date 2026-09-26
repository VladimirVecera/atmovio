"""Real SQLite history with simulated hardware: retention, deltas, gaps and read-only ranges."""
import importlib.util, sqlite3, tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('metrics',Path(__file__).resolve().parents[1]/'src/atmovio/metrics.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as temp:
 root=Path(temp);history=root/'metrics.sqlite3';app=root/'app.db'
 with sqlite3.connect(app) as con:
  con.execute('CREATE TABLE ai_stats(calls INTEGER,interesting INTEGER,errors INTEGER)')
  con.execute('INSERT INTO ai_stats VALUES(100,20,3)')
 ticks=[100,100]
 def read(path):
  return {'/proc/stat':f'cpu {ticks[0]} 0 0 {ticks[1]} 0 0 0 0\n','/proc/meminfo':'MemTotal: 1000 kB\nMemAvailable: 400 kB\n','/sys/class/thermal/thermal_zone0/temp':'45000'}.get(path,'')
 with patch.object(m,'optional_read',side_effect=read),patch.object(m.shutil,'disk_usage',return_value=SimpleNamespace(total=1000,used=250)),patch.object(m.os,'getloadavg',return_value=(1,1,1)):
  m.collect(history,root,app,30,100000)
  ticks[:]=[150,150]
  with sqlite3.connect(app) as con:con.execute('UPDATE ai_stats SET calls=104,interesting=22,errors=4')
  m.collect(history,root,app,30,100060)
  m.collect(history,root,app,30,100061) # No duplicate within minute.
  data=m.query(history,99999,100100)
  assert len(data['points'])==2
  point=data['points'][1]
  assert point['cpu']==50 and point['temperature']==45 and point['ram']==60 and point['disk']==25
  assert (point['calls'],point['interesting'],point['errors'])==(4,2,1)
  m.collect(history,root,app,30,101000)
  assert m.query(history,100900,101001)['points'][0]['calls'] is None
  m.collect(history,root,app,1,200000)
  with sqlite3.connect(history) as con:assert con.execute('SELECT COUNT(*) FROM samples').fetchone()[0]==1
 assert not m.query(root/'absent.sqlite3',0,1)['points'] and not (root/'absent.sqlite3').exists()
 # Query downsampling keeps a bounded payload even for a full year.
 with m.connect(history) as con:
  con.executemany('INSERT OR IGNORE INTO samples(ts,cpu,temperature) VALUES(?,?,?)',[(300000+i*60,40,50) for i in range(2000)])
 assert len(m.query(history,0,31536000)['points'])<=361
print('PASS: CPU/RAM/HDD/temperature values, AI counter deltas, gaps, minute deduplication, retention, read-only missing history, bounded queries')
