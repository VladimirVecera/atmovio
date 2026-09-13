#!/usr/bin/env bash
# Aktualizuje Atmovio; nová aplikace i závislosti se připraví před zastavením služby.
set -euo pipefail
umask 077
SKY_DIR=/opt/nvr/atmovio
# Legacy (SkyWatch ≤ 3.x): SKY_DIR=/opt/nvr/skywatch – instalace se níže přesune do $SKY_DIR; tento řádek zároveň
# splňuje kontrolu staženého skriptu ve verzích 3.2–3.4 (hledají v hlavičce text SKY_DIR=/opt/nvr/skywatch).
OLD_DIR=/opt/nvr/skywatch
[[ $EUID -eq 0 ]] || { echo "Spusť jako root: sudo bash update-atmovio.sh"; exit 1; }

# --- Migrace SkyWatch → Atmovio (jednorázově; konfigurace, databáze, snímky i zálohy zůstávají)
if [[ ! -d "$SKY_DIR" && -d "$OLD_DIR" ]]; then
  echo "Přejmenování SkyWatch → Atmovio: přesouvám $OLD_DIR → $SKY_DIR a služby."
  systemctl stop skywatch.service 2>/dev/null || true
  systemctl stop nvr-storage.service 2>/dev/null || true
  mv "$OLD_DIR" "$SKY_DIR"
  # venv je symlink s absolutní cestou do staré složky – přesměrovat na tutéž složku v novém umístění
  if [[ -L "$SKY_DIR/venv" ]]; then
    target=$(readlink "$SKY_DIR/venv")
    ln -sfn "$SKY_DIR/$(basename "$target")" "$SKY_DIR/venv"
  fi
  [[ ! -f "$SKY_DIR/skywatch.db" ]]  || mv "$SKY_DIR/skywatch.db" "$SKY_DIR/atmovio.db"
  [[ ! -f "$SKY_DIR/skywatch.log" ]] || mv "$SKY_DIR/skywatch.log" "$SKY_DIR/atmovio.log"
  for f in "$SKY_DIR"/skywatch.log.*; do [[ -e "$f" ]] && mv "$f" "${f/skywatch.log/atmovio.log}"; done
  # snímky na HDD (jen když je disk připojený; jinak si je aplikace založí znovu a staré zůstanou ve /mnt/nvr/skywatch)
  if [[ -d /mnt/nvr/skywatch && ! -e /mnt/nvr/atmovio ]] && findmnt -M /mnt/nvr >/dev/null 2>&1; then
    mv /mnt/nvr/skywatch /mnt/nvr/atmovio
  fi
  python3 - "$SKY_DIR/config.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p, encoding="utf-8"))
if str(cfg.get("snapshot_dir", "")).startswith("/mnt/nvr/skywatch/"):
    cfg["snapshot_dir"] = cfg["snapshot_dir"].replace("/mnt/nvr/skywatch/", "/mnt/nvr/atmovio/", 1)
json.dump(cfg, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
  # systemd: nová jednotka atmovio.service se stejným obsahem, stará pryč
  if [[ -f /etc/systemd/system/skywatch.service ]]; then
    sed -e 's#/opt/nvr/skywatch#/opt/nvr/atmovio#g' -e 's/SKYWATCH_/ATMOVIO_/g' -e 's/SkyWatch/Atmovio/g' \
      /etc/systemd/system/skywatch.service > /etc/systemd/system/atmovio.service
    chmod 644 /etc/systemd/system/atmovio.service
    systemctl disable skywatch.service 2>/dev/null || true
    rm -f /etc/systemd/system/skywatch.service
  fi
  systemctl daemon-reload
  systemctl enable atmovio.service >/dev/null 2>&1 || true
  rm -rf /run/skywatch
  echo "Přesunuto. Pokračuji běžnou aktualizací."
fi
[[ -f "$SKY_DIR/config.json" && -f "$SKY_DIR/app.py" && -x "$SKY_DIR/venv/bin/python" ]] || {
  echo "Atmovio není kompletně nainstalován v $SKY_DIR."; exit 1;
}
exec 9>"$SKY_DIR/.update.lock"
flock -n 9 || { echo "Jiná aktualizace již běží."; exit 1; }
STAMP=$(date +%Y%m%d%H%M%S)-$$
STAGE=$SKY_DIR/.update-$STAMP
BACKUP=$SKY_DIR/backups/$STAMP
NEW_VENV=$SKY_DIR/venv-$STAMP
mkdir -p "$STAGE" "$BACKUP"
cat > "$STAGE/app.py" <<'ATMOVIO_APP_EOF'
__ATMOVIO_APP__
ATMOVIO_APP_EOF
cat > "$STAGE/storage_guard.py" <<'ATMOVIO_STORAGE_EOF'
__ATMOVIO_STORAGE__
ATMOVIO_STORAGE_EOF
cat > "$STAGE/requirements.txt" <<'ATMOVIO_REQUIREMENTS_EOF'
__ATMOVIO_REQUIREMENTS__
ATMOVIO_REQUIREMENTS_EOF

# --- statické soubory (CSS/JS) a knihovny Pico CSS + Alpine.js (offline kopie)
write_static() {  # $1 = cílový adresář
  mkdir -p "$1/vendor"
  cat > "$1/atmovio.css" <<'ATMOVIO_CSS_EOF'
__ATMOVIO_CSS__
ATMOVIO_CSS_EOF
  cat > "$1/atmovio.js" <<'ATMOVIO_JS_EOF'
__ATMOVIO_JS__
ATMOVIO_JS_EOF
}
fetch_vendor() {  # $1 = cílový adresář static
  local d="$1/vendor" ok=1
  mkdir -p "$d"
  if [[ ! -s "$d/pico.min.css" ]]; then
    curl -fsSL --max-time 60 -o "$d/pico.min.css.tmp" "https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css" \
      && mv "$d/pico.min.css.tmp" "$d/pico.min.css" || { rm -f "$d/pico.min.css.tmp"; ok=0; }
  fi
  if [[ ! -s "$d/alpine.min.js" ]]; then
    curl -fsSL --max-time 60 -o "$d/alpine.min.js.tmp" "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js" \
      && mv "$d/alpine.min.js.tmp" "$d/alpine.min.js" || { rm -f "$d/alpine.min.js.tmp"; ok=0; }
  fi
  [[ $ok -eq 1 ]] || echo "! Knihovny Pico CSS / Alpine.js se nepodařilo stáhnout – Atmovio je načte z internetu (CDN), dokud se to nepovede při dalším updatu."
}
write_static "$STAGE/static"

# Staré prostředí zůstává beze změn a běžící služba dál obsluhuje web.
python3 -m venv "$NEW_VENV"
"$NEW_VENV/bin/python" -m pip install -q -r "$STAGE/requirements.txt"
"$NEW_VENV/bin/python" -m pip check
ATMOVIO_DIR="$SKY_DIR" PYTHONPATH="$STAGE" PYTHONDONTWRITEBYTECODE=1 "$NEW_VENV/bin/python" -c 'import app, storage_guard; app.load_config()'
cp -a "$SKY_DIR/app.py" "$BACKUP/app.py"
if [[ -f "$SKY_DIR/storage_guard.py" ]]; then cp -a "$SKY_DIR/storage_guard.py" "$BACKUP/storage_guard.py"; fi
if [[ -f "$SKY_DIR/requirements.txt" ]]; then cp -a "$SKY_DIR/requirements.txt" "$BACKUP/requirements.txt"; fi
cp -a "$SKY_DIR/config.json" "$BACKUP/config.json"
if [[ -d "$SKY_DIR/static" ]]; then cp -a "$SKY_DIR/static" "$BACKUP/static"; fi

rollback() {
  trap - ERR INT TERM
  set +e
  echo "Aktualizace selhala, obnovuji původní aplikaci a prostředí."
  systemctl stop atmovio.service
  cp -a "$BACKUP/app.py" "$SKY_DIR/app.py"
  if [[ -f "$BACKUP/storage_guard.py" ]]; then cp -a "$BACKUP/storage_guard.py" "$SKY_DIR/storage_guard.py"; fi
  if [[ -f "$BACKUP/requirements.txt" ]]; then cp -a "$BACKUP/requirements.txt" "$SKY_DIR/requirements.txt"; fi
  if [[ -d "$BACKUP/static" ]]; then rm -rf "$SKY_DIR/static"; cp -a "$BACKUP/static" "$SKY_DIR/static"; fi
  if [[ -e "$BACKUP/venv" || -L "$BACKUP/venv" ]]; then
    [[ ! -L "$SKY_DIR/venv" ]] || unlink "$SKY_DIR/venv"
    mv "$BACKUP/venv" "$SKY_DIR/venv"
  fi
  systemctl restart nvr-storage.service 2>/dev/null || true
  systemctl restart atmovio.service
  systemctl is-active --quiet atmovio.service || echo "Původní služba také nenaběhla; zkontroluj journalctl -u atmovio."
  echo "Záloha: $BACKUP"
  exit 1
}
trap rollback ERR INT TERM
systemctl stop nvr-storage.service 2>/dev/null || true
systemctl stop atmovio.service
mv "$SKY_DIR/venv" "$BACKUP/venv"
# Venv se nepřejmenovává: jeho pip/uvicorn obsahují absolutní cesty.
ln -s "$NEW_VENV" "$SKY_DIR/venv"
mv "$STAGE/app.py" "$SKY_DIR/app.py"
mv "$STAGE/storage_guard.py" "$SKY_DIR/storage_guard.py"
mv "$STAGE/requirements.txt" "$SKY_DIR/requirements.txt"
mkdir -p "$SKY_DIR/static/vendor"
mv -f "$STAGE/static/atmovio.css" "$SKY_DIR/static/atmovio.css"
mv -f "$STAGE/static/atmovio.js" "$SKY_DIR/static/atmovio.js"
fetch_vendor "$SKY_DIR/static"
"$NEW_VENV/bin/python" "$SKY_DIR/storage_guard.py" --install

# --- smartd (S.M.A.R.T. hlídání HDD): bez disku nesmí svítit jako chyba, s USB diskem má běžet
setup_smartd() {
  mkdir -p /etc/systemd/system/smartmontools.service.d
  cat > /etc/systemd/system/smartmontools.service.d/nvr.conf <<'EOF'
[Unit]
# Data disk se připojuje až po startu; smartd se má spustit i po jeho pozdějším připojení.
After=mnt-nvr.mount
[Service]
# 17 = "žádné zařízení ke sledování" – bez HDD to není chyba.
SuccessExitStatus=17
Restart=on-failure
RestartSec=60
EOF
  cat > /etc/smartd.conf <<'EOF'
# NVR: sledovat všechny disky včetně USB boxů (-d removable = nepadat, když disk zmizí; -n standby = nebudit uspaný disk).
# Bez e-mailu (na RPi není poštovní server) – varování jdou do systémového logu a Atmovio je ukazuje na každé stránce.
DEVICESCAN -d removable -n standby,q -a -W 4,45,55
EOF
  grep -q '^smartd_opts=' /etc/default/smartmontools 2>/dev/null || echo 'smartd_opts=""' >> /etc/default/smartmontools
  # unit soubory nejsou tajné – bez práv pro ostatní systemd při každém startu varuje
  chmod 644 /etc/systemd/system/atmovio.service /etc/systemd/system/nvr-storage.service /etc/systemd/system/smartmontools.service.d/nvr.conf 2>/dev/null || true
  # systémový žurnál: ponechat na disku kvůli diagnostice, ale omezit velikost (šetří SSD)
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\nSystemMaxFileSize=20M\n' > /etc/systemd/journald.conf.d/nvr.conf
  chmod 644 /etc/systemd/journald.conf.d/nvr.conf
  systemctl restart systemd-journald 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable smartmontools.service >/dev/null 2>&1 || true
  systemctl restart smartmontools.service 2>/dev/null || true
}
if [[ ! -f /etc/systemd/system/smartmontools.service.d/nvr.conf ]] || grep -q -- '-m root' /etc/smartd.conf 2>/dev/null; then setup_smartd; fi
systemctl restart atmovio.service
for _ in $(seq 1 20); do
  if systemctl is-active --quiet atmovio.service && "$NEW_VENV/bin/python" - <<'PY'
import json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1/api/health", timeout=2) as response:
        assert json.load(response)["ok"] is True
except Exception:
    raise SystemExit(1)
PY
  then
    trap - ERR INT TERM
    rm -rf "$STAGE" "$SKY_DIR"/.update-* 2>/dev/null || true
    # Zálohy (každá obsahuje i celé venv, ~100 MB): nechat jen 2 poslední, starší smazat.
    ls -1dt "$SKY_DIR"/backups/*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf
    # Stará prostředí venv-*: smazat ta, na která už neukazuje ani aktuální venv, ani žádná ponechaná záloha.
    keep_venvs=$(readlink -f "$SKY_DIR/venv"; for b in "$SKY_DIR"/backups/*/venv; do [[ -e "$b" ]] && readlink -f "$b"; done)
    for v in "$SKY_DIR"/venv-*; do
      [[ -d "$v" && ! -L "$v" ]] || continue
      grep -qxF "$(readlink -f "$v")" <<<"$keep_venvs" || rm -rf "$v"
    done
    echo "✔ Atmovio aktualizován: http://$(hostname -I | awk '{print $1}')"
    echo "Záloha původní aplikace a prostředí: $BACKUP (starší zálohy smazány, drží se 2 poslední – $(du -sh "$SKY_DIR/backups" 2>/dev/null | cut -f1))"
    exit 0
  fi
  sleep 2
done
journalctl -u atmovio -n 30 --no-pager
rollback
