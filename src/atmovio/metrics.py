"""Bounded subprocess for local RPi metrics; no network or camera operations."""
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import time

FIELDS = ('temperature', 'cpu', 'load', 'ram', 'disk', 'used_gb', 'total_gb', 'calls', 'interesting', 'errors')


def optional_read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return ''


def connect(path):
    con = sqlite3.connect(path, timeout=2)
    con.row_factory = sqlite3.Row
    con.execute('''CREATE TABLE IF NOT EXISTS samples (
        ts INTEGER PRIMARY KEY, temperature REAL, cpu REAL, load REAL, ram REAL,
        disk REAL, used_gb REAL, total_gb REAL, calls INTEGER, interesting INTEGER, errors INTEGER,
        ticks REAL, idle REAL, calls_total INTEGER, interesting_total INTEGER, errors_total INTEGER)''')
    return con


def collect(path, disk_path, app_db, days, now=None, require_external=False):
    # Parent checks the storage guard; never create missing disk directories or fall back to SSD.
    now = int(now if now is not None else time.time())
    path = Path(path)
    if not path.parent.is_dir():
        raise OSError('Adresář statistik na HDD není dostupný.')
    if require_external:
        disk_device = Path(disk_path).stat().st_dev
        if disk_device == Path('/').stat().st_dev or path.parent.stat().st_dev != disk_device:
            raise OSError('Statistiky musí zůstat na samostatném disku pro záznamy.')
    raw = optional_read('/proc/stat').splitlines()
    ticks = idle = None
    if raw and raw[0].startswith('cpu '):
        values = [int(v) for v in raw[0].split()[1:9]]
        ticks, idle = sum(values), values[3] + values[4]
    mem = {}
    for line in optional_read('/proc/meminfo').splitlines():
        key, value = line.split(':', 1)
        mem[key] = int(value.strip().split()[0])
    ram = 100 * (1 - mem['MemAvailable'] / mem['MemTotal']) if mem.get('MemTotal') and 'MemAvailable' in mem else None
    temp = optional_read('/sys/class/thermal/thermal_zone0/temp').strip()
    temperature = float(temp)/1000 if temp else None
    load = os.getloadavg()[0] if hasattr(os, 'getloadavg') else None
    usage = shutil.disk_usage(disk_path)
    totals = [None, None, None]
    try:
        with sqlite3.connect(f'file:{Path(app_db)}?mode=ro', uri=True, timeout=2) as source:
            totals = list(source.execute('SELECT COALESCE(SUM(calls),0),COALESCE(SUM(interesting),0),COALESCE(SUM(errors),0) FROM ai_stats').fetchone())
    except sqlite3.Error:
        pass
    with connect(path) as con:
        previous = con.execute('SELECT * FROM samples ORDER BY ts DESC LIMIT 1').fetchone()
        if previous and now - previous['ts'] < 55:
            return
        continuous = previous and 0 < now - previous['ts'] <= 180
        cpu = None
        if continuous and ticks is not None and previous['ticks'] is not None and ticks > previous['ticks']:
            cpu = max(0, min(100, 100*(1-(idle-previous['idle'])/(ticks-previous['ticks']))))
        deltas = [max(0,total-previous[key]) if continuous and total is not None and previous[key] is not None else None
                  for key,total in zip(('calls_total','interesting_total','errors_total'),totals)]
        values = (now,temperature,cpu,load,ram,100*usage.used/usage.total,
                  usage.used/1024**3,usage.total/1024**3,*deltas,ticks,idle,*totals)
        con.execute('INSERT INTO samples VALUES('+','.join('?' for _ in values)+')', values)
        con.execute('DELETE FROM samples WHERE ts < ?', (now-int(days)*86400,))


def query(path, start, end):
    if not Path(path).is_file():
        return {'points': [], 'first': None, 'last': None}
    bucket = max(60, int((end-start)/360)+1)
    expressions = ['MAX(temperature) AS temperature','AVG(cpu) AS cpu','AVG(load) AS load','AVG(ram) AS ram',
                   'MAX(disk) AS disk','MAX(used_gb) AS used_gb','MAX(total_gb) AS total_gb',
                   'SUM(calls) AS calls','SUM(interesting) AS interesting','SUM(errors) AS errors']
    with sqlite3.connect(f'file:{Path(path)}?mode=ro',uri=True,timeout=2) as con:
        con.row_factory=sqlite3.Row
        rows=con.execute('SELECT MIN(ts) AS ts,'+','.join(expressions)+' FROM samples WHERE ts>=? AND ts<=? GROUP BY CAST((ts-?)/? AS INTEGER) ORDER BY ts', (start,end,start,bucket)).fetchall()
        first,last=con.execute('SELECT MIN(ts),MAX(ts) FROM samples').fetchone()
    return {'points':[dict(r) for r in rows], 'first':first, 'last':last, 'bucket':bucket}


if __name__ == '__main__':
    try:
        if sys.argv[1]=='collect':
            collect(sys.argv[2],sys.argv[3],sys.argv[4],int(sys.argv[5]), require_external=True)
        elif sys.argv[1]=='query':
            print(json.dumps(query(sys.argv[2],float(sys.argv[3]),float(sys.argv[4])),allow_nan=False))
    except Exception as exc:
        print(str(exc),file=sys.stderr)
        raise SystemExit(1)
