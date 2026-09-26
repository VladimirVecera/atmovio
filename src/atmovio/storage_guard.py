#!/usr/bin/env python3
"""Hlídání HDD a přepínání Frigate mezi nahráváním a živým náhledem.

Samostatná služba, nezávislá na HDD. Konfigurace uživatele zůstává v config.yml.
Diskové I/O probíhá v jediném časově omezeném podprocesu, ne v řídicí smyčce.
"""
import copy
import datetime as dt
import fcntl
import io
import json
import os
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from ruamel.yaml import YAML

NVR = Path(os.environ.get('NVR_DIR', '/opt/nvr'))
SKY = NVR / 'atmovio'
MOUNT = Path('/mnt/nvr')
# Stav se zapisuje každé 2 s – patří do RAM (/run), ne na SSD.
STATUS = Path('/run/atmovio/storage-status.json')
COMPOSE = NVR / 'docker-compose.yml'
LIVE_CONFIG = NVR / 'frigate/config/config.live.yml'
SOURCE_CONFIG = NVR / 'frigate/config/config.yml'
SYSTEMD = Path('/etc/systemd/system')


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def read_yaml(path):
    return YAML().load(path.read_text()) or {}


def dump(data):
    out = io.StringIO()
    YAML().dump(data, out)
    return out.getvalue()


def live_config(data):
    data = copy.deepcopy(data)
    # Frigate nesmí při úklidu prázdného média odstranit index záznamů na HDD.
    # Název souboru musí obsahovat 'frigate.db' – Frigate před migrací zálohuje přes
    # path.replace('frigate.db', 'backup.db'); jiný název skončí SameFileError a pádem.
    data['database'] = {'path': '/config/live/frigate.db'}
    for scope in [data, *(data.get('cameras') or {}).values()]:
        scope.setdefault('record', {}).update(enabled=False, sync_recordings=False)
        scope.setdefault('snapshots', {})['enabled'] = False
        # Odstranění role record zabrání i tvorbě dočasných video segmentů.
        inputs = scope.get('ffmpeg', {}).get('inputs', [])
        for inp in inputs:
            inp['roles'] = [role for role in inp.get('roles', []) if role != 'record']
        if inputs and not any('detect' in inp['roles'] for inp in inputs):
            inputs[0]['roles'].append('detect')
        if inputs:
            scope['ffmpeg']['inputs'] = [inp for inp in inputs if inp['roles']]
    return data


def media_config(service, healthy):
    """Compose vždy explicitně určuje médium; nikdy nevytváří složku na SSD."""
    service = copy.deepcopy(service)
    def target(volume):
        return volume.get('target') if isinstance(volume, dict) else volume.split(':')[1]
    service['volumes'] = [v for v in service.get('volumes', []) if target(v) != '/media/frigate']
    service['volumes'].append(
        {'type': 'bind', 'source': str(MOUNT / 'frigate'), 'target': '/media/frigate',
         'bind': {'create_host_path': False}} if healthy else
        {'type': 'tmpfs', 'target': '/media/frigate', 'tmpfs': {'size': 32 * 1024 * 1024}})
    env = service.get('environment', {})
    if isinstance(env, list):
        env = dict(item.split('=', 1) if '=' in item else (item, None) for item in env)
    env['CONFIG_FILE'] = '/config/config.yml' if healthy else '/config/config.live.yml'
    service['environment'] = env
    # Start po rebootu musí nejprve rozhodnout podle stavu disku.
    service['restart'] = 'no'
    return service


def probe_disk():
    """Volá se pouze v podprocesu; vadné USB může blokovat i stat/fsync."""
    mounts = Path('/proc/self/mountinfo').read_text().splitlines()
    entry = next((line for line in mounts if line.split()[4] == str(MOUNT)), '')
    if not entry:
        raise OSError('Disk není připojený v /mnt/nvr.')
    if entry.split(' - ', 1)[1].split()[0] != 'ext4':
        raise OSError('Disk v /mnt/nvr nemá očekávaný formát ext4.')
    if not MOUNT.is_mount() or MOUNT.stat().st_dev == Path('/').stat().st_dev:
        raise OSError('Úložiště není samostatný připojený disk.')
    # Ověřit právě prostor záznamů, ne pouze jiný adresář na témže disku.
    directories = ('frigate', 'frigate/recordings', 'atmovio', 'atmovio/snapshots')
    if any((MOUNT / name).is_symlink() for name in directories):
        raise OSError('Adresář záznamů nebo snímků je symbolický odkaz; zápis pozastaven.')
    for name in directories:
        directory = MOUNT / name
        directory.mkdir(exist_ok=True)
        if directory.stat().st_dev != MOUNT.stat().st_dev:
            raise OSError(f'Adresář {directory} není na disku pro záznamy.')
    # Bez zápisu nelze rozlišit připojený disk od read-only / vadného HDD.
    fd, name = tempfile.mkstemp(prefix='.atmovio-probe-', dir=MOUNT / 'frigate/recordings')
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(b'Atmovio storage check\n')
            out.flush()
            os.fsync(out.fileno())
    finally:
        Path(name).unlink(missing_ok=True)
    return True


class Probe:
    def __init__(self):
        self.process = None
        self.started = 0
        self.reason = "Čekám na ověření zápisu na disk."

    def sample(self):
        """None = měření běží; False = chyba/timeout; True = fsync prošel."""
        if self.process is None:
            self.process = subprocess.Popen([sys.executable, __file__, '--probe'],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.started = time.monotonic()
            return None
        rc = self.process.poll()
        if rc is not None:
            detail = self.process.stderr.read().decode("utf-8", errors="replace").strip()[-600:]
            self.process.stderr.close()
            self.reason = "HDD je zapisovatelný." if rc == 0 else (detail or "Kontrola zápisu na disk selhala.")
            self.process = None
            return rc == 0
        if time.monotonic() - self.started > 4:
            self.reason = "Disk neodpověděl na kontrolu zápisu do 4 sekund. Zkontroluj USB, napájení a stav disku."
            self.process.kill()
            # Nečekat na proces v D state a nevytvářet další, dokud neskončí.
            return False
        return None


def command(args, timeout=90):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout)[-1000:])
    return result.stdout


_last_publish = {'key': None, 'at': 0.0}


def publish(mode, reason, restart_request=None):
    """Zapíše stav jen při změně nebo nejpozději po 10 s (Atmovio bere stav za čerstvý 15 s)."""
    now = time.time()
    if _last_publish['key'] == (mode, reason) and now - _last_publish['at'] < 10:
        return
    if _last_publish['key'] != (mode, reason):
        print(f'{dt.datetime.now().isoformat(timespec="seconds")} [{mode}] {reason}', flush=True)
    _last_publish.update(key=(mode, reason), at=now)
    atomic(STATUS, json.dumps({'mode': mode, 'reason': reason, 'checked_at': now, 'guard_pid': os.getpid(), 'restart_request': restart_request}, ensure_ascii=False))


class Guard:
    def __init__(self):
        self.mode = None
        self.successes = 0
        self.config_text = None
        self.retry_at = 0
        self.last_running_check = 0
        self.mount_id = None

    def adopt_running(self, mount_id=None):
        """Po startu strážce (aktualizace Atmovio, restart služby) převzít běžící Frigate místo jeho
        znovuvytvoření – recreate by přerušil nahrávání i rozdělané exporty videí."""
        try:
            if command(['docker', 'inspect', '-f', '{{.State.Running}}', 'frigate'], timeout=5).strip() != 'true':
                return
            service = read_yaml(COMPOSE)['services']['frigate']
            media = [v for v in service.get('volumes', []) if isinstance(v, dict) and v.get('target') == '/media/frigate']
            env = service.get('environment', {})
            if isinstance(env, list):
                env = dict(item.split('=', 1) if '=' in item else (item, None) for item in env)
            if media and media[0].get('type') == 'bind' and env.get('CONFIG_FILE') == '/config/config.yml':
                mode = 'recording'
            elif media and media[0].get('type') == 'tmpfs' and env.get('CONFIG_FILE') == '/config/config.live.yml':
                mode = 'live'
            else:
                return
            request = SKY / 'storage-restart'
            self.mode, self.mount_id = mode, mount_id
            self.successes = 3 if mode == 'recording' else 0
            self.config_text = (SOURCE_CONFIG.read_text(), request.read_text() if request.exists() else '')
            publish(mode, 'HDD je zapisovatelný.' if mode == 'recording' else 'Pouze živý náhled. Nahrávání a ukládání snímků jsou vypnuté.')
        except Exception:
            return

    def reconcile(self, healthy, mount_id=None, reason="HDD chybí, neodpovídá nebo neprošel kontrolou zápisu."):
        if mount_id != self.mount_id:
            self.successes = 0
            self.mount_id = mount_id
        if healthy is True:
            self.successes += 1
        elif healthy is False:
            self.successes = 0
        # Návrat až po třech úspěšných zápisech; pád okamžitě.
        desired = 'recording' if self.successes >= 3 else 'live'
        if 0 < self.successes < 3:
            reason = f'Ověřuji stabilitu disku: {self.successes} ze 3 úspěšných zápisů.'
        if healthy is None and self.mode == 'recording':
            desired = 'recording'
        source = SOURCE_CONFIG.read_text()
        request = SKY / 'storage-restart'
        revision = (source, request.read_text() if request.exists() else '')
        changed = revision != self.config_text
        if self.mode and time.monotonic() - self.last_running_check >= 10:
            self.last_running_check = time.monotonic()
            try:
                if command(['docker', 'inspect', '-f', '{{.State.Running}}', 'frigate'], timeout=5).strip() != 'true':
                    self.mode = None
            except Exception:
                self.mode = None
        if self.mode == desired and not changed:
            publish(self.mode, 'HDD je zapisovatelný.' if self.mode == 'recording' else reason + ' Živý náhled bez záznamu.', revision[1])
            return
        if time.monotonic() < self.retry_at:
            return
        publish('switching', 'Přepínám režim Frigate; náhled může být krátce přerušen.')
        try:
            config = YAML().load(source) or {}
            database = config.get('database', {}).get('path', '/config/frigate.db')
            source_db = NVR / 'frigate/config' / Path(database).relative_to('/config')
            live_db = NVR / 'frigate/config/live/frigate.db'
            live_db.parent.mkdir(mode=0o700, exist_ok=True)
            if desired == 'live' and self.mode != 'live':
                if source_db.exists():
                    # Konzistentní SQLite backup včetně WAL, nikoli kopie otevřeného souboru.
                    command([sys.executable, __file__, '--backup-db', str(source_db),
                             str(live_db)])
            elif desired == 'recording' and not source_db.exists() and live_db.exists():
                # První instalace bez HDD: zachovat přihlášení vytvořené v live režimu.
                command([sys.executable, __file__, '--backup-db', str(live_db), str(source_db)])
            atomic(LIVE_CONFIG, dump(live_config(config)))
            compose = read_yaml(COMPOSE)
            compose['services']['frigate'] = media_config(compose['services']['frigate'], desired == 'recording')
            atomic(COMPOSE, dump(compose))
            # Omezená doba zastavení – na nemocný disk nečekat desítky sekund.
            command(['docker', 'compose', '-f', str(COMPOSE), 'up', '-d', '--no-deps', '--force-recreate', '--timeout', '5', 'frigate'])
            self.mode, self.config_text = desired, revision
            publish(desired, 'HDD je zapisovatelný.' if desired == 'recording' else reason + ' Nahrávání a ukládání snímků jsou vypnuté.', revision[1])
        except Exception as exc:
            self.mode = None
            self.retry_at = time.monotonic() + 15
            publish('error', f'Přepnutí se nepodařilo, opakuji: {exc}')


def install():
    """Převod instalace tohoto projektu; původní soubory ponechá v záloze."""
    # Bez démona nelze bezpečně změnit restart policy starého kontejneru.
    # Neodstraňovat starou mount závislost před touto kontrolou.
    command(['docker', 'info'], timeout=10)
    compose = read_yaml(COMPOSE)
    if 'frigate' not in compose.get('services', {}):
        raise RuntimeError('V Compose chybí služba frigate.')
    config = read_yaml(SOURCE_CONFIG)
    database = Path(config.get('database', {}).get('path', '/config/frigate.db'))
    if not database.is_relative_to('/config') or '..' in database.parts:
        raise RuntimeError('Správce vyžaduje databázi Frigate na SSD uvnitř /config.')
    backup = SKY / 'backups' / ('storage-' + dt.datetime.now().strftime('%Y%m%d%H%M%S'))
    backup.mkdir(parents=True, exist_ok=True)
    files = [COMPOSE, SYSTEMD / 'atmovio.service',
             SYSTEMD / 'docker.service.d/nvr-storage.conf',
             SYSTEMD / 'nvr-storage.service']
    for index, path in enumerate(files):
        if path.exists():
            atomic(backup / f'{index}-{path.name}', path.read_text())
    atomic(LIVE_CONFIG, dump(live_config(config)))
    compose['services']['frigate'] = media_config(compose['services']['frigate'], False)
    atomic(COMPOSE, dump(compose))
    # Zrušit pouze starou závislost vytvořenou tímto projektem.
    files[2].unlink(missing_ok=True)
    unit = files[1].read_text()
    unit = '\n'.join(line for line in unit.splitlines() if not (
        line == 'RequiresMountsFor=/mnt/nvr' or line == 'BindsTo=mnt-nvr.mount'
        or line == 'After=mnt-nvr.mount' or line == 'ConditionPathIsMountPoint=/mnt/nvr')) + '\n'
    atomic(files[1], unit)
    atomic(files[3], f'''[Unit]
Description=NVR storage guard – živý náhled při poruše HDD
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
ExecStart={SKY}/venv/bin/python {SKY}/storage_guard.py
WorkingDirectory={NVR}
Restart=always
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
''')
    # Původní restart policy nesmí po rebootu obejít kontrolu disku.
    existing = command(['docker', 'ps', '-a', '--filter', 'name=^/frigate$', '--format', '{{.ID}}'])
    if existing.strip():
        command(['docker', 'update', '--restart=no', 'frigate'])
    # unit soubor není tajný – s právy 600 systemd při každém načtení varuje "world-inaccessible"
    (SYSTEMD / 'nvr-storage.service').chmod(0o644)
    command(['systemctl', 'daemon-reload'])
    command(['systemctl', 'start', 'docker'])
    command(['systemctl', 'enable', 'nvr-storage.service'])
    command(['systemctl', 'restart', 'nvr-storage.service'])


def main():
    if '--backup-db' in sys.argv:
        with sqlite3.connect(f'file:{sys.argv[2]}?mode=ro', uri=True, timeout=5) as source:
            with sqlite3.connect(sys.argv[3], timeout=5) as destination:
                source.backup(destination)
        return 0
    if '--probe' in sys.argv:
        try:
            return 0 if probe_disk() else 1
        except (OSError, ValueError) as exc:
            print(str(exc), file=sys.stderr, flush=True)
            return 1
    if '--install' in sys.argv:
        install()
        return 0
    SKY.mkdir(parents=True, exist_ok=True)
    with (SKY / '.storage.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        probe, guard = Probe(), Guard()
        mounts = Path('/proc/self/mountinfo').read_text().splitlines()
        guard.adopt_running(next((line.split()[0] for line in mounts if line.split()[4] == str(MOUNT)), None))
        while True:
            try:
                # Změna mount ID zachytí i rychlé odpojení/připojení mezi sondami.
                mounts = Path('/proc/self/mountinfo').read_text().splitlines()
                mount_id = next((line.split()[0] for line in mounts if line.split()[4] == str(MOUNT)), None)
                healthy = probe.sample()
                guard.reconcile(healthy, mount_id, probe.reason)
            except Exception as exc:
                publish('error', str(exc))
            time.sleep(2)


if __name__ == '__main__':
    raise SystemExit(main())
