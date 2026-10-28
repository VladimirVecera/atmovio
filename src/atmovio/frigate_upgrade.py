#!/usr/bin/env python3
"""Transactional Frigate upgrade for the managed Raspberry Pi installation.

Preparation runs while cameras record. The switch backs up the stopped SQLite
DB and config together. No media directory or recording is moved or deleted.
"""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request

from ruamel.yaml import YAML

VERSION = '0.18.2'
IMAGE = f'ghcr.io/blakeblackshear/frigate:{VERSION}-standard-arm64'
ROOT = Path('/opt/nvr')
COMPOSE = ROOT / 'docker-compose.yml'
CONFIG = ROOT / 'frigate/config'


def run(args, timeout=180):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        # Docker errors can include camera URLs. Keep detailed output in a root-only file.
        raise RuntimeError(f"Příkaz {args[0]} selhal (kód {result.returncode}).")
    return result.stdout


def api(path):
    with urllib.request.urlopen('http://127.0.0.1:5000/api/' + path, timeout=5) as response:
        body = response.read().decode()
    try:
        return json.loads(body)
    except ValueError:
        return body


def fingerprint():
    digest = hashlib.sha256(COMPOSE.read_bytes())
    for p in sorted(CONFIG.glob('*.y*ml')):
        digest.update(p.name.encode() + p.read_bytes())
    return digest.hexdigest()


def compose():
    return YAML().load(COMPOSE.read_text())


def already_running():
    if compose()['services']['frigate']['image'] != IMAGE:
        return False
    try:
        return str(api('version')).startswith(VERSION)
    except Exception:
        return False


def prepare(backup):
    if already_running():
        return
    if os.uname().machine not in ('aarch64', 'arm64'):
        raise RuntimeError('Tato instalace vyžaduje 64bit ARM.')
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    print('Frigate: stahuji 0.18.2; kamery zatím nahrávají.', flush=True)
    run(['docker', 'pull', IMAGE], timeout=1800)
    candidate = backup / 'validate'
    candidate.mkdir(exist_ok=True)
    for path in CONFIG.glob('*.y*ml'):
        shutil.copy2(path, candidate / path.name)
    # Frigate's own loader performs its supported config migrations on the copy.
    for name in ('config.yml', 'config.live.yml'):
        if not (candidate / name).is_file():
            continue
        result = subprocess.run(['docker', 'run', '--rm', '--network=none', '-v', f'{candidate}:/config',
                                 '-e', f'CONFIG_FILE=/config/{name}', '--entrypoint', 'python3', IMAGE,
                                 '-m', 'frigate', '--validate-config'], text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        log = backup / ('validate-' + name + '.log')
        log.write_text(result.stdout)
        log.chmod(0o600)
        if result.returncode:
            raise RuntimeError(f'Frigate odmítl {name}. Původní nahrávání běží. Podrobnosti: {log}')
    (backup / 'prepared.json').write_text(json.dumps({'fingerprint': fingerprint(), 'image': IMAGE}))
    print('Frigate: konfigurace pro 0.18.2 ověřena.', flush=True)


def wait_ready(version, cameras=()):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            if str(api('version')).startswith(version):
                stats = api('stats').get('cameras', {})
                if all(float(stats.get(c, {}).get('camera_fps', 0)) > 0 for c in cameras):
                    return
        except Exception:
            pass
        time.sleep(3)
    raise RuntimeError('Frigate po aktualizaci nepotvrdil verzi nebo obraz původně dostupných kamer.')


def rollback(backup):
    manifest_path = backup / 'switch.json'
    if not manifest_path.is_file() or (backup / 'rolled-back').exists():
        return
    manifest = json.loads(manifest_path.read_text())
    run(['systemctl', 'stop', 'nvr-storage.service'])
    run(['docker', 'stop', '-t', '30', 'frigate'])
    # Preserve failed configuration for diagnostics; never mix old DB with new WAL.
    failed = backup / ('failed-config-' + dt.datetime.now().strftime('%H%M%S'))
    shutil.move(str(CONFIG), failed)
    shutil.copytree(backup / 'config', CONFIG)
    shutil.copy2(backup / 'docker-compose.yml', COMPOSE)
    if manifest['running']:
        run(['docker', 'compose', '-f', str(COMPOSE), 'up', '-d', '--no-deps', '--force-recreate', 'frigate'])
        wait_ready(manifest['version'])
    (backup / 'rolled-back').touch()
    print(f'Frigate: obnovena původní verze a databáze. Záloha: {backup}', flush=True)


def upgrade(backup):
    if already_running():
        print('Frigate 0.18.2 již běží.', flush=True)
        return
    prepared = json.loads((backup / 'prepared.json').read_text())
    if prepared['image'] != IMAGE or prepared['fingerprint'] != fingerprint():
        raise RuntimeError('Konfigurace se od ověření změnila; spusťte aktualizaci znovu.')
    old_version = str(api('version'))
    stats = api('stats').get('cameras', {})
    cameras = [name for name, item in stats.items() if float(item.get('camera_fps', 0)) > 0]
    running = run(['docker', 'inspect', '-f', '{{.State.Running}}', 'frigate']).strip() == 'true'
    run(['systemctl', 'stop', 'nvr-storage.service'])
    run(['docker', 'stop', '-t', '30', 'frigate'])
    try:
        shutil.copytree(CONFIG, backup / 'config')
        shutil.copy2(COMPOSE, backup / 'docker-compose.yml')
        (backup / 'switch.json').write_text(json.dumps({'version': old_version, 'running': running, 'cameras': cameras}))
        data = compose()
        data['services']['frigate']['image'] = IMAGE
        stream = io.StringIO(); YAML().dump(data, stream)
        COMPOSE.write_text(stream.getvalue())
        run(['docker', 'compose', '-f', str(COMPOSE), 'config', '-q'])
        run(['docker', 'compose', '-f', str(COMPOSE), 'up', '-d', '--no-deps', '--force-recreate', 'frigate'])
        wait_ready(VERSION, cameras)
        print(f'Frigate {VERSION}: API a {len(cameras)} kamer v provozu.', flush=True)
    except BaseException:
        if (backup / 'switch.json').exists():
            rollback(backup)
        elif running:
            run(['docker', 'start', 'frigate'])
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'upgrade', 'rollback'])
    parser.add_argument('backup', type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Spusťte aktualizaci přes sudo.')
    os.umask(0o077)
    globals()[args.action](args.backup.resolve())


if __name__ == '__main__':
    main()
