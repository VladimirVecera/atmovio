#!/usr/bin/env bash
# =============================================================================
#  RPi 5 NVR + Atmovio – instalační script
#  Raspberry Pi OS Lite 64-bit (Debian 13 "trixie")
#
#  Nainstaluje a zprovozní:
#    * Docker + Frigate (NVR: záznam kamer, přehrávání, export)   https://IP:8971
#    * Portainer (správa kontejnerů)                              https://IP:9443
#    * Cockpit (správa systému, sítě, disků, aktualizací)         https://IP:9090
#    * Atmovio (vlastní administrace: kamery, retence, mazání,
#      AI hlídání oblohy, e-mail, VPN klient, systém)             http://IP
#
#  Spuštění:  sudo bash install.sh
# =============================================================================
set -euo pipefail
umask 077

NVR_DIR=/opt/nvr
DATA_MNT=/mnt/nvr
SKY_DIR=$NVR_DIR/atmovio
FRIGATE_CFG_DIR=$NVR_DIR/frigate/config
INFO_FILE=$NVR_DIR/INSTALL-INFO.txt
LOG=/var/log/nvr-install.log

C_B='\033[1m'; C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_C='\033[36m'; C_0='\033[0m'
step()  { echo -e "\n${C_C}${C_B}==> $*${C_0}"; }
ok()    { echo -e "${C_G}✔ $*${C_0}"; }
warn()  { echo -e "${C_Y}! $*${C_0}"; }
die()   { echo -e "${C_R}✖ $*${C_0}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Spusť jako root: sudo bash install.sh"
[[ -t 0 ]] || die "Spusť stažený skript v interaktivním terminálu (ne curl | bash)."
[[ ! -f "$SKY_DIR/config.json" ]] || die "Atmovio už je nainstalován. Pro aktualizaci použij update-atmovio.sh; konfiguraci nepřepisuji."
[[ ! -f /opt/nvr/skywatch/config.json ]] || die "Je tu instalace SkyWatch (starý název Atmovia). Nespouštěj instalátor – spusť update-atmovio.sh, ten ji přejmenuje a aktualizuje se zachováním nastavení."
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=== NVR install $(date) ==="

# ----------------------------------------------------------------------------- 0. kontroly
[[ $EUID -eq 0 ]] || die "Spusť jako root:  sudo bash install.sh"
[[ "$(uname -m)" == "aarch64" ]] || die "Očekávám 64-bit ARM (aarch64). Nainstaluj Raspberry Pi OS 64-bit."
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "Systém: $PRETTY_NAME"
  [[ "${VERSION_CODENAME:-}" == "trixie" || "${VERSION_CODENAME:-}" == "bookworm" ]] || warn "Určeno pro Debian 13 (trixie), máš ${VERSION_CODENAME:-?}. Pokračuji."
fi
grep -qi "raspberry pi 5" /proc/device-tree/model 2>/dev/null || warn "Nevypadá to na Raspberry Pi 5 – pokračuji, ale výkon může být jiný."


export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------- 1. dotazy
step "Základní nastavení"
DEFAULT_TZ="Europe/Prague"
echo "Heslo administrátora platí pro Atmovio a Portainer; alespoň 12 znaků."
while true; do
  read -rsp "Heslo administrátora: " ADMIN_PW; echo
  read -rsp "Heslo znovu:         " ADMIN_PW2; echo
  [[ "$ADMIN_PW" == "$ADMIN_PW2" ]] || { warn "Hesla se neshodují."; continue; }
  [[ ${#ADMIN_PW} -ge 12 ]] || { warn "Heslo musí mít alespoň 12 znaků."; continue; }
  break
done
while true; do
  read -rp "Kolik dní uchovávat záznamy? [7, rozsah 1–60]: " RETAIN_DAYS
  RETAIN_DAYS=${RETAIN_DAYS:-7}
  [[ "$RETAIN_DAYS" =~ ^[1-9][0-9]?$ ]] && (( RETAIN_DAYS <= 60 )) && break
  warn "Zadej celé číslo 1–60."
done
while true; do
  read -rp "Časové pásmo [$DEFAULT_TZ]: " TZ_IN
  TZONE=${TZ_IN:-$DEFAULT_TZ}
  [[ "$TZONE" =~ ^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)+$ && -f "/usr/share/zoneinfo/$TZONE" ]] && break
  warn "Neplatné časové pásmo, například Europe/Prague."
done
timedatectl set-timezone "$TZONE"

echo "E-mail lze nastavit později ve Atmovio → E-mail."
read -rp "SMTP server (Enter = přeskočit): " SMTP_HOST
SMTP_PORT=587; SMTP_SEC=starttls; SMTP_USER=""; SMTP_PASS=""; MAIL_FROM=""; MAIL_TO=""
if [[ -n "$SMTP_HOST" ]]; then
  while true; do
    read -rp "Port [587 STARTTLS, 465 SSL]: " SMTP_PORT_IN
    SMTP_PORT=${SMTP_PORT_IN:-587}
    [[ "$SMTP_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SMTP_PORT <= 65535 )) && break
    warn "Zadej port 1–65535."
  done
  [[ "$SMTP_PORT" != "465" ]] || SMTP_SEC=ssl
  read -rp "Přihlašovací jméno: " SMTP_USER
  read -rsp "Heslo k SMTP: " SMTP_PASS; echo
  read -rp "Odesílatel [$SMTP_USER]: " MAIL_FROM_IN; MAIL_FROM=${MAIL_FROM_IN:-$SMTP_USER}
  read -rp "Příjemce upozornění: " MAIL_TO
fi

# ----------------------------------------------------------------------------- 2. balíčky
step "Aktualizace systému a instalace balíčků (může trvat několik minut)"
apt-get update -q
apt-get -y -q install ca-certificates curl gnupg jq git python3 python3-venv python3-pip ffmpeg fonts-dejavu-core \
  wireguard-tools iproute2 iputils-ping smartmontools hdparm parted e2fsprogs util-linux avahi-daemon \
  cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit \
  || die "Instalace balíčků selhala – viz $LOG"
systemctl enable --now cockpit.socket
ok "Balíčky nainstalovány, Cockpit běží na portu 9090"

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
setup_smartd

# ----------------------------------------------------------------------------- 3. Docker
step "Docker"
if ! command -v docker >/dev/null 2>&1; then
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh; then
    ok "Docker nainstalován z docker.com"
  else
    warn "Instalace z docker.com selhala, zkouším balíčky Debianu"
    apt-get -y -q install docker.io docker-compose-v2 || apt-get -y -q install docker.io docker-compose \
      || die "Docker se nepodařilo nainstalovat"
  fi
fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || die "Chybí 'docker compose' plugin."
if [[ -n "${SUDO_USER:-}" ]]; then usermod -aG docker "$SUDO_USER" || true; fi
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) připraven"

# ----------------------------------------------------------------------------- 4. HDD pro záznamy
step "Disk pro záznamy kamer"
mkdir -p "$DATA_MNT"

ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
ROOT_DISK=$(lsblk -snro NAME,TYPE "$ROOT_SRC" | awk '$2=="disk"{print $1}')
[[ -n "$ROOT_DISK" ]] || die "Nelze bezpečně určit systémový disk."
BOOT_SRC=$(findmnt -no SOURCE /boot/firmware 2>/dev/null || findmnt -no SOURCE /boot 2>/dev/null || true)
BOOT_DISK=""
if [[ -n "$BOOT_SRC" ]]; then
  BOOT_DISK=$(lsblk -snro NAME,TYPE "$BOOT_SRC" | awk '$2=="disk"{print $1}')
  [[ -n "$BOOT_DISK" ]] || die "Nelze bezpečně určit bootovací disk."
fi

if findmnt -M "$DATA_MNT" >/dev/null 2>&1 && grep -q " $DATA_MNT " /etc/fstab; then
  [[ "$(findmnt -nro FSTYPE -M "$DATA_MNT")" == "ext4" ]] || die "$DATA_MNT musí být samostatný disk ext4."
  DATA_PARENT=$(lsblk -snro NAME,TYPE "$(findmnt -nro SOURCE -M "$DATA_MNT")" | awk '$2=="disk"{print $1}')
  [[ -n "$DATA_PARENT" ]] || die "Nelze určit disk připojený v $DATA_MNT."
  while IFS= read -r d; do
    [[ "$ROOT_DISK" != *"$d"* && "$BOOT_DISK" != *"$d"* ]] || die "$DATA_MNT leží na systémovém disku."
  done <<< "$DATA_PARENT"
  ok "Disk už je připojen v $DATA_MNT ($(findmnt -no SOURCE "$DATA_MNT")) – ponechávám."
  SKIP_DISK=1
else
  SKIP_DISK=0
fi

if [[ $SKIP_DISK -eq 0 ]]; then
  CANDIDATES=()
  while read -r d kind; do
    [[ "$kind" == "disk" ]] || continue
    [[ "$d" != mmcblk* && "$d" != loop* && "$d" != zram* && "$d" != ram* ]] || continue
    [[ "$ROOT_DISK" != *"$d"* && "$BOOT_DISK" != *"$d"* ]] || continue
    # Disk s připojeným oddílem (včetně swapu) nikdy neodpojuj ani nenabízej.
    [[ -z "$(lsblk -nr -o MOUNTPOINTS "/dev/$d" | tr -d '[:space:]')" ]] || continue
    CANDIDATES+=("$d")
  done < <(lsblk -dn -o NAME,TYPE)

  echo
  echo -e "Systémový disk (${C_B}/dev/$ROOT_DISK${C_0}) je ${C_G}chráněný${C_0} a v nabídce se neukazuje."
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    warn "HDD není k dispozici. Instaluji živý náhled bez záznamu; disk můžeš připojit později do /mnt/nvr."
  else
    echo -e "${C_B}Nalezené disky pro záznamy:${C_0}"
    printf "  %-3s %-10s %-9s %-6s %-28s %s\n" "č." "zařízení" "velikost" "typ" "model" "obsah"
    i=1
    for d in "${CANDIDATES[@]}"; do
      SIZE=$(lsblk -dn -o SIZE "/dev/$d"); MODEL=$(lsblk -dn -o MODEL "/dev/$d" | sed 's/ *$//'); TRAN=$(lsblk -dn -o TRAN "/dev/$d")
      FS=$(lsblk -n -o FSTYPE,LABEL "/dev/$d" | awk 'NF{print}' | sed 's/^ *//' | paste -sd, - )
      [[ -z "$FS" ]] && FS="prázdný / bez souborového systému"
      printf "  %-3s %-10s %-9s %-6s %-28s %s\n" "$i)" "/dev/$d" "$SIZE" "${TRAN:-?}" "${MODEL:-?}" "$FS"
      i=$((i+1))
    done
    echo "  0)  pokračovat bez HDD – pouze živý náhled"
    while true; do
      read -rp "Vyber číslo disku pro záznamy: " PICK
      [[ "$PICK" =~ ^(0|[1-9][0-9]?)$ ]] && [[ $PICK -le ${#CANDIDATES[@]} ]] && break
      warn "Zadej číslo 0–${#CANDIDATES[@]}."
    done
    if [[ $PICK -gt 0 ]]; then
      DISK=${CANDIDATES[$((PICK-1))]}
      DEV=/dev/$DISK
      [[ "$ROOT_DISK" != *"$DISK"* && "$BOOT_DISK" != *"$DISK"* ]] || die "Bezpečnostní pojistka: $DEV je systémový disk!"
      [[ -z "$(lsblk -nr -o MOUNTPOINTS "$DEV" | tr -d '[:space:]')" ]] || die "Disk je připojený; ukončeno."

      EXISTING_EXT4=$(lsblk -ln -o NAME,FSTYPE "$DEV" | awk '$2=="ext4"{print $1; exit}')
      FORMAT=1
      if [[ -n "$EXISTING_EXT4" ]]; then
        echo
        echo -e "Disk $DEV už obsahuje oddíl ${C_B}/dev/$EXISTING_EXT4${C_0} se souborovým systémem ext4."
        echo "  1) Ponechat data a použít tento oddíl (nic se nesmaže)"
        echo "  2) Naformátovat celý disk (VŠECHNA DATA NA NĚM BUDOU SMAZÁNA)"
        read -rp "Volba [1]: " FCH
        [[ "${FCH:-1}" == "2" ]] || { FORMAT=0; PART=/dev/$EXISTING_EXT4; }
      fi
      if [[ $FORMAT -eq 1 ]]; then
        echo
        echo -e "${C_R}${C_B}POZOR: Disk $DEV ($(lsblk -dn -o SIZE "$DEV"), $(lsblk -dn -o MODEL "$DEV" | sed 's/ *$//')) bude kompletně smazán.${C_0}"
        read -rp "Pro potvrzení napiš velkými písmeny SMAZAT: " CONFIRM
        [[ "$CONFIRM" == "SMAZAT" ]] || die "Formátování nepotvrzeno, ukončeno. Nic se nesmazalo."
        [[ -z "$(lsblk -nr -o MOUNTPOINTS "$DEV" | tr -d '[:space:]')" ]] || die "Disk byl mezitím připojen, nic nemažu."
        wipefs -a "$DEV" >/dev/null
        parted -s "$DEV" mklabel gpt mkpart primary ext4 0% 100%
        partprobe "$DEV"; sleep 3; udevadm settle || true
        PART=$(lsblk -ln -o NAME,TYPE "$DEV" | awk '$2=="part"{print "/dev/"$1; exit}')
        [[ -n "$PART" ]] || die "Nepodařilo se vytvořit oddíl na $DEV"
        mkfs.ext4 -F -q -L NVRDATA -m 0 "$PART"
        ok "Disk naformátován ($PART)"
      fi
      UUID=$(blkid -s UUID -o value "$PART")
      cp -a /etc/fstab "/etc/fstab.nvr-$(date +%Y%m%d%H%M%S).bak"
      sed -i "\# $DATA_MNT #d" /etc/fstab
      echo "UUID=$UUID  $DATA_MNT  ext4  defaults,noatime,nofail,x-systemd.device-timeout=20  0  2" >> /etc/fstab
      systemctl daemon-reload
      mount "$DATA_MNT"
      findmnt -M "$DATA_MNT" >/dev/null || die "Disk se nepodařilo připojit do $DATA_MNT"
      ok "Disk $PART připojen v $DATA_MNT ($(df -h "$DATA_MNT" | awk 'NR==2{print $2" celkem, "$4" volných"}'))"
    else
      warn "Pokračuji bez HDD; nahrávání bude vypnuté."
    fi
  fi
fi
# --- ladění disku: uspávání, USB rychlost, UAS, zdroj
DISK_NOTE=""
DATA_SRC=$(findmnt -no SOURCE "$DATA_MNT" 2>/dev/null || true)
if [[ -n "$DATA_SRC" && "$DATA_SRC" == /dev/* ]]; then
  DATA_DISK=$(lsblk -no PKNAME "$DATA_SRC" 2>/dev/null || true)
  DATA_DISK=${DATA_DISK:-$(basename "$DATA_SRC")}
  DATA_DEV=/dev/$DATA_DISK
  if [[ "$DATA_DISK" != "$ROOT_DISK" ]]; then
    # vypnout uspávání/parkování hlav (teď i po každém startu přes /etc/hdparm.conf)
    hdparm -S 0 -B 254 "$DATA_DEV" >/dev/null 2>&1 && ok "Uspávání disku $DATA_DEV vypnuto (hdparm -S 0 -B 254)" \
      || { hdparm -S 0 "$DATA_DEV" >/dev/null 2>&1 && ok "Uspávání disku vypnuto (hdparm -S 0; APM box nepodporuje)" || warn "hdparm na $DATA_DEV nefunguje (USB box ho nepodporuje) – vypni auto-spindown přepínačem/utilitou boxu."; }
    DATA_UUID=$(blkid -s UUID -o value "$DATA_SRC" 2>/dev/null || true)
    if [[ -n "$DATA_UUID" ]] && ! grep -q "$DATA_UUID" /etc/hdparm.conf 2>/dev/null; then
      cat >> /etc/hdparm.conf <<EOF

# NVR – disk pro záznamy: nikdy neuspávat
/dev/disk/by-uuid/$DATA_UUID {
    spindown_time = 0
    apm = 254
}
EOF
    fi
    # USB rychlost a VID:PID (pro případný UAS quirk)
    SYSDEV=$(readlink -f "/sys/block/$DATA_DISK/device" 2>/dev/null || true)
    USBDIR="$SYSDEV"
    while [[ -n "$USBDIR" && "$USBDIR" != "/" && ! -f "$USBDIR/idVendor" ]]; do USBDIR=$(dirname "$USBDIR"); done
    if [[ -f "$USBDIR/idVendor" ]]; then
      VID=$(cat "$USBDIR/idVendor"); PID=$(cat "$USBDIR/idProduct"); SPEED=$(cat "$USBDIR/speed" 2>/dev/null || echo ?)
      DRV=$(basename "$(readlink -f "$SYSDEV/../../../driver" 2>/dev/null)" 2>/dev/null || echo ?)
      case "$SPEED" in
        5000|10000|20000) ok "HDD běží na USB 3 (${SPEED} Mb/s), driver: ${DRV}" ;;
        *) warn "HDD běží jen na USB ${SPEED} Mb/s – zapoj ho do MODRÉHO USB 3.0 portu!" ;;
      esac
      DISK_NOTE="HDD $DATA_DEV: USB ${SPEED} Mb/s, VID:PID $VID:$PID, driver $DRV
      Pokud se disk odpojuje nebo hlásí I/O chyby (UAS + box), přidej na začátek /boot/firmware/cmdline.txt:
        usb-storage.quirks=$VID:$PID:u
      a restartuj."
    fi
  fi
fi
# napájecí zdroj (RPi 5 hlásí max. proud zdroje; 27W = 5000 mA)
PSU_MA=""
if [[ -r /proc/device-tree/chosen/power/max_current ]]; then
  PSU_MA=$(od -An -tu4 --endian=big /proc/device-tree/chosen/power/max_current 2>/dev/null | tr -d ' ' || true)
fi
if [[ -n "$PSU_MA" && "$PSU_MA" -lt 5000 ]]; then
  warn "Zdroj hlásí jen ${PSU_MA} mA – použij originální 27W zdroj (5 V / 5 A), jinak USB porty omezí proud pro HDD."
elif [[ -n "$PSU_MA" ]]; then
  ok "Zdroj: ${PSU_MA} mA (OK)"
fi

# Datové složky vytváří storage guard až po ověření skutečného HDD a zápisu.

# ----------------------------------------------------------------------------- 5. Frigate + Portainer (docker compose)
step "Frigate a Portainer"
mkdir -p "$FRIGATE_CFG_DIR" "$NVR_DIR/portainer"

if [[ ! -f "$FRIGATE_CFG_DIR/config.yml" ]]; then
cat > "$FRIGATE_CFG_DIR/config.yml" <<EOF
# Konfigurace Frigate – kamery přidávej v Atmovio (http://IP → Kamery)
# nebo zde přes Frigate UI → Nastavení → Editor konfigurace.
mqtt:
  enabled: false

detectors:
  cpu1:
    type: cpu
    num_threads: 2

# Detekce objektů je vypnutá. Frigate přesto dekóduje obraz pro náhledy;
# kamerám nastav nízké rozlišení substreamu s rolí detect. Záznam se ukládá copy.
detect:
  enabled: false

record:
  enabled: true
  sync_recordings: true
  continuous:
    days: $RETAIN_DAYS
  motion:
    days: 0
  alerts:
    retain:
      days: $RETAIN_DAYS
  detections:
    retain:
      days: $RETAIN_DAYS

snapshots:
  enabled: false

birdseye:
  enabled: false

go2rtc:
  streams: {}

cameras: {}
EOF
fi

cat > "$NVR_DIR/docker-compose.yml" <<EOF
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:0.17.2-standard-arm64
    restart: "no"
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s
    shm_size: "256mb"
    environment:
      - TZ=$TZONE
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - $FRIGATE_CFG_DIR:/config
      - type: tmpfs
        target: /media/frigate
        tmpfs:
          size: 33554432
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "8971:8971"            # UI + API s přihlášením (HTTPS)
      - "127.0.0.1:5000:5000"  # API bez přihlášení – jen pro Atmovio na tomto RPi
      - "127.0.0.1:1984:1984"  # go2rtc API – snímky pro Atmovio
      - "127.0.0.1:8554:8554"            # RTSP restream
      - "8555:8555/tcp"        # WebRTC
      - "8555:8555/udp"

  portainer:
    container_name: portainer
    image: portainer/portainer-ce:lts
    restart: unless-stopped
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    command: --admin-password-file /run/secrets/admin_pw
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $NVR_DIR/portainer:/data
      - $NVR_DIR/.portainer_pw:/run/secrets/admin_pw:ro
EOF
printf '%s' "$ADMIN_PW" > "$NVR_DIR/.portainer_pw"; chmod 600 "$NVR_DIR/.portainer_pw"

# Frigate spustí správce úložiště podle aktuálního stavu HDD.
systemctl daemon-reload
cd "$NVR_DIR"
docker compose config -q
docker compose pull
docker compose up -d portainer
ok "Portainer spuštěn; Frigate spustí správce úložiště"

# ----------------------------------------------------------------------------- 6. Atmovio
step "Atmovio (vlastní administrace)"
mkdir -p "$SKY_DIR"
cat > "$SKY_DIR/app.py" <<'ATMOVIO_APP_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Atmovio – webová administrace pro RPi 5 NVR (Frigate) + AI hlídání oblohy.

Běží jako systemd služba na hostiteli (ne v Dockeru), aby mohla spravovat
WireGuard, disky a Docker kontejnery. Konfigurace: /opt/nvr/atmovio/config.json
"""
import base64
import concurrent.futures
import ipaddress
import socket
import uuid
import xml.etree.ElementTree as ET
import datetime as dt
import hashlib
import io
import json
import logging
import os
import re
import secrets
import shutil
import smtplib
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
import traceback
import unicodedata
from email.message import EmailMessage
from contextlib import asynccontextmanager, contextmanager
from functools import wraps
from logging.handlers import RotatingFileHandler
from pathlib import Path
from urllib.parse import quote, urlsplit
from xml.sax.saxutils import escape
from zoneinfo import ZoneInfo

import requests
from PIL import Image, ImageChops, ImageStat
from fastapi import FastAPI, Form, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import DictLoader, Environment
from ruamel.yaml import YAML
from starlette.middleware.sessions import SessionMiddleware
from starlette.concurrency import run_in_threadpool
from astral import LocationInfo
from astral.sun import sun

APP_DIR = Path(os.environ.get("ATMOVIO_DIR", "/opt/nvr/atmovio"))
CONFIG_FILE = APP_DIR / "config.json"
DB_FILE = APP_DIR / "atmovio.db"
LOG_FILE = APP_DIR / "atmovio.log"
FRIGATE_CONTAINER = "frigate"
APP_VERSION = "4.6.3"
GITHUB_REPO = "VladimirVecera/atmovio"          # odkud se berou nové verze (GitHub Releases)
UPDATE_STATE_FILE = APP_DIR / "update-state.json"
UPDATE_LOG_FILE = APP_DIR / "update.log"
UPDATE_UNIT = "atmovio-update"                  # transientní systemd jednotka, ve které běží update-atmovio.sh

# Katalog jevů: id, název, popis pro AI. Uživatel si vybírá, na které chce upozornit.
PHENOMENA = [
    ("cervanky", "Červánky", "barevný východ nebo západ slunce – oranžová, růžová či červená obloha nebo mraky"),
    ("shelf", "Shelf cloud / arcus", "válcovitá nebo hradbovitá tmavá bouřková fronta postupující nízko nad zemí"),
    ("mammatus", "Mammatus", "vakovité, visící výběžky na spodní straně oblačnosti"),
    ("beranci", "Beránky", "altocumulus / cirrocumulus – pravidelný vzor mnoha malých obláčků"),
    ("bourka", "Bouřkový mrak", "cumulonimbus s kovadlinou, mohutná věžovitá bouřková oblačnost, tmavá bouřková stěna"),
    ("blesk", "Blesk", "viditelný blesk nebo bouřkový mrak osvětlený bleskem"),
    ("duha", "Duha", "duha nebo její část"),
    ("halo", "Halo / sluneční sloup", "halo kolem slunce či měsíce, sluneční sloup, parhelium (boční slunce)"),
    ("paprsky", "Krepuskulární paprsky", "paprsky světla prosvítající mezi mraky nebo za obzorem"),
    ("lentikularni", "Lentikulární mraky", "čočkovité, hladké oválné mraky"),
    ("mlha", "Mlha / inverze", "mlha, nízká oblačnost pod úrovní kamery, inverzní vrstva"),
    ("tornado", "Nálevkový oblak / tromba / tornádo", "nálevkovitý výběžek sahající ze základny bouřkového oblaku k zemi (funnel cloud), tromba nebo tornádo; vždy jako samostatná kategorie"),
    ("wallcloud", "Wall cloud", "výrazná sníženina (nižší, často rotující blok oblačnosti) pod základnou bouřky, typická pro silné bouře"),
    ("rollcloud", "Roll cloud / rotorový oblak", "oddělený horizontální válec oblačnosti nízko nad zemí, nesouvisí s bouřkovou základnou"),
    ("asperitas", "Asperitas", "dramaticky zvlněná, chaoticky vlnitá spodní základna oblačnosti připomínající rozbouřenou hladinu zespodu"),
    ("kroupy", "Kroupové / srážkové jádro", "výrazná bílá až zelenavá oblast srážek pod bouřkovým oblakem (kroupové nebo silné srážkové jádro)"),
    ("prehanka", "Srážkové pruhy / přeháňka", "viditelné pruhy deště nebo sněžení padající z oblaku až k zemi"),
    ("virga", "Virga", "srážkové pruhy pod oblakem, které se vypařují ve vzduchu a nedosahují země"),
    ("dest", "Silný déšť", "silný déšť viditelný přímo v záběru – kapky, stékající voda, mlžný závoj deště, zhoršená viditelnost"),
    ("snezeni", "Sněžení", "husté sněžení nebo sněhová přeháňka viditelná v záběru"),
    ("jine", "Fotogenická / zajímavá obloha", "cokoliv výrazně fotogenického, co nespadá do předchozích kategorií – krásné barvy mraků, dramatické nasvícení, výrazná struktura oblačnosti, neobvyklá atmosféra"),
]
PHENOMENA_IDS = [p[0] for p in PHENOMENA]
PHENOMENA_LABELS = {p[0]: p[1] for p in PHENOMENA}
# Jevy přidané v pozdějších verzích – u existující instalace se zapnou automaticky (jednorázově).
PHENOMENA_ADDED = {"2": ["tornado", "wallcloud", "rollcloud", "asperitas", "kroupy", "prehanka", "virga", "dest", "snezeni"]}


def phenomena_catalog(ai: dict | None = None) -> list:
    """Vestavěné jevy + vlastní jevy uživatele (ai.custom_phenomena: [{id, label, desc}])."""
    out = list(PHENOMENA)
    for c in (ai or {}).get("custom_phenomena") or []:
        if c.get("id") and c.get("label"):
            out.append((c["id"], c["label"], c.get("desc") or c["label"]))
    return out


def phen_labels(ai: dict | None = None) -> dict:
    return {p[0]: p[1] for p in phenomena_catalog(ai)}


def cam_rule(ai: dict, cam: str) -> dict:
    """Co platí pro danou kameru: práh a sledované jevy – vlastní (ai.cam_rules[cam]), jinak výchozí."""
    ids = [p[0] for p in phenomena_catalog(ai)]
    default = {"threshold": int(ai.get("threshold", 7) or 7), "phenomena": [p for p in (ai.get("phenomena") or ids) if p in ids] or ids,
               "any": bool(ai.get("any_photogenic", True)), "custom": False}
    r = (ai.get("cam_rules") or {}).get(cam) or {}
    if not r.get("custom"):
        return default
    thr = r.get("threshold")
    ph = [p for p in (r.get("phenomena") or []) if p in ids]
    return {"threshold": int(thr) if thr else default["threshold"], "phenomena": ph or default["phenomena"],
            "any": bool(r.get("any", default["any"])), "custom": True}

DEFAULT_PROMPT = (
    "Jsi meteorolog a fotograf oblohy. Na obrázku je záběr z venkovní kamery. "
    "Posuď, jak zajímavá a fotogenická je obloha, a urči, které z uvedených jevů jsou na snímku skutečně vidět."
)

DEFAULT_CONFIG = {
    "admin_password_hash": "",
    "secret": "",
    "frigate_url": "http://127.0.0.1:5000",
    "go2rtc_url": "http://127.0.0.1:1984",
    "restream_url": "rtsp://127.0.0.1:8554",
    "frigate_config_path": "/opt/nvr/frigate/config/config.yml",
    "recordings_path": "/mnt/nvr/frigate/recordings",
    "snapshot_dir": "/mnt/nvr/atmovio/snapshots",
    "lat": 49.8,
    "lon": 15.5,
    "tz": "Europe/Prague",
    "ai": {
        "enabled": False,
        "provider": "gemini",
        "api_key": "",
        "model": "auto",
        "base_url": "https://api.groq.com/openai/v1",
        "ollama_url": "http://127.0.0.1:11434",
        "interval_min": 10,
        "fast_mode": True,
        "fast_interval_min": 3,
        "golden_min": 60,
        "day_only": True,
        "margin_min": 60,
        "twilight": "nautical",
        "dark_skip": True,
        "dark_level": 22,
        "threshold": 7,
        "cooldown_min": 15,
        "episode_gap_min": 120,
        "daily_limit": 200,
        "prefilter": True,
        "prefilter_diff": 5.0,
        "cameras": [],
        "phenomena": list(PHENOMENA_IDS),
        "prompt_extra": "",
        "keep_days": 14,
        "export_keep_days": 30,
        "auto_export": {"enabled": False, "before_min": 2, "after_min": 3, "playback": "realtime", "cameras": []},
    },
    "studio": {   # Video studio: zrychlení, intro, text v obraze, hudba, šablony titulku/popisu
        "speed": 20, "intro": True, "intro_seconds": 4, "intro_title": True, "intro_text": "{kamera}\n{datum}",
        "text_enabled": True, "text": "{kamera} · {datum} · {rychlost}×", "text_pos": "bl", "text_size": 36,
        "music_default": "", "music_volume": 0.8, "fade_in": 2, "fade_out": 4, "video_fade_in": 1, "video_fade_out": 2,
        "title": "{jev} nad obcí {kamera} · časosběr {datum}", "ai_title": True,
        "description": "{popis}\n\n{kamera}, {datum} {cas}. Záznam {delka}, zrychleno {rychlost}×.\nVytvořeno v Atmovio – atmovio.com",
        "auto": False,
        "youtube": {"client_id": "", "client_secret": "", "privacy": "unlisted", "playlist_id": "", "tags": "Atmovio, obloha, timelapse, časosběr", "auto": False},
    },
    "alerts": {
        "camera_outage": True,
        "outage_min": 5,
        "repeat_h": 6,
        "frigate": True,
        "storage": True,
        "recovery": True,
    },
    "email": {
        "host": "",
        "port": 587,
        "user": "",
        "password": "",
        "security": "starttls",
        "from": "",
        "to": "",
        "attach": True,
    },
    "vpn": {"iface": "wg-remote", "test_ip": ""},
    "api_keys": [],
    "log_since": {},
    "update": {"auto_check": True},
    "web": {
        "enabled": False,
        "url": "",
        "token": "",
        "thumbs": True,
        "nvr_name": "Raspberry Pi 5 NVR",
    },
}

PROVIDERS = {
    "gemini": {"label": "Google Gemini (bezplatný tarif)", "model": "auto",
               "models_hint": "auto = nejnovější Flash-Lite model, který Google pro tvůj klíč nabízí (zdarma cca 500 vyhodnocení/den – doporučeno). Plný Flash (např. gemini-3.8-flash) je přesnější, ale zdarma jen cca 20/den. Limity vidíš na aistudio.google.com/rate-limit."},
    "openai_compat": {"label": "Groq / OpenRouter / jiné OpenAI-kompatibilní API", "model": "meta-llama/llama-4-scout-17b-16e-instruct",
                      "models_hint": "Groq: meta-llama/llama-4-scout-17b-16e-instruct (zdarma) · OpenRouter: modely s příponou :free"},
    "anthropic": {"label": "Anthropic Claude (placené)", "model": "claude-haiku-4-5", "models_hint": "claude-haiku-4-5 (levný) · claude-sonnet-4-5"},
    "openai": {"label": "OpenAI (placené)", "model": "gpt-4o-mini", "models_hint": "gpt-4o-mini · gpt-4.1-mini"},
    "ollama": {"label": "Ollama na RPi (zdarma, offline, pomalé a méně přesné)", "model": "moondream",
               "models_hint": "moondream · qwen2.5vl:3b · llava"},
}
PROVIDER_MODELS = {k: v["model"] for k, v in PROVIDERS.items()}

# Přehled poskytovatelů pro stránku AI – cena, limity, přesnost, kde vzít klíč, doporučené modely.
PROVIDER_INFO = {
    "gemini": {"name": "Google Gemini", "tag": "zdarma", "kind": "free", "price": "Zdarma bez karty (bezplatný tarif AI Studia).",
               "limits": "auto = Flash-Lite: cca 500 vyhodnocení/den zdarma. Plný Flash ~20/den zdarma; placený tarif bez limitu za pár Kč/den.",
               "quality": "Dobrá; Flash je přesnější než Flash-Lite. Google může snímky z bezplatného tarifu použít k trénování.",
               "key_url": "https://aistudio.google.com/apikey", "key_label": "Create API key", "usage_url": "https://aistudio.google.com/rate-limit",
               "models": [("auto", "nejnovější Flash-Lite, který klíč nabízí – doporučeno"), ("gemini-2.5-flash-lite", "Flash-Lite napevno"), ("gemini-2.5-flash", "přesnější, zdarma jen ~20/den")]},
    "openai_compat": {"name": "Groq / OpenRouter", "tag": "zdarma", "kind": "free", "price": "Groq: zdarma bez karty. OpenRouter: modely s příponou :free zdarma, ostatní za kredity.",
                      "limits": "Groq free: řádově tisíce požadavků/den, ale malé modely. OpenRouter free: ~50–200/den podle modelu.",
                      "quality": "Střední – Llama 4 Scout vidí obrázky, ale oblohu popisuje hůř než Gemini/Claude.",
                      "key_url": "https://console.groq.com/keys", "key_label": "Create API Key", "usage_url": "https://console.groq.com/settings/limits",
                      "models": [("meta-llama/llama-4-scout-17b-16e-instruct", "Groq, zdarma"), ("meta-llama/llama-4-maverick-17b-128e-instruct", "Groq, přesnější"), ("google/gemini-2.0-flash-exp:free", "OpenRouter, zdarma")]},
    "anthropic": {"name": "Anthropic Claude", "tag": "placené", "kind": "paid", "price": "Předplacené kredity (od 5 USD); jedno vyhodnocení ≈ 0,01–0,05 Kč u Haiku.",
                  "limits": "Bez denního limitu, platíš za spotřebu. 300 vyhodnocení/den ≈ 10–40 Kč/měsíc.",
                  "quality": "Nejlepší popisy a nejméně planých poplachů.",
                  "key_url": "https://console.anthropic.com/settings/keys", "key_label": "Create Key", "usage_url": "https://console.anthropic.com/settings/usage",
                  "models": [("claude-haiku-4-5", "levný a rychlý – doporučeno"), ("claude-sonnet-4-5", "nejpřesnější, ~10× dražší")]},
    "openai": {"name": "OpenAI", "tag": "placené", "kind": "paid", "price": "Předplacené kredity (od 5 USD); vyhodnocení ≈ 0,02–0,05 Kč u gpt-4o-mini.",
               "limits": "Bez denního limitu, platíš za spotřebu. 300 vyhodnocení/den ≈ 15–40 Kč/měsíc.",
               "quality": "Velmi dobrá, srovnatelná s Claude.",
               "key_url": "https://platform.openai.com/api-keys", "key_label": "Create new secret key", "usage_url": "https://platform.openai.com/usage",
               "models": [("gpt-4o-mini", "levný – doporučeno"), ("gpt-4.1-mini", "novější, podobná cena"), ("gpt-4.1", "nejpřesnější, dražší")]},
    "ollama": {"name": "Ollama na Raspberry Pi", "tag": "offline", "kind": "local", "price": "Zdarma, bez internetu a bez klíče – model běží přímo na Pi.",
               "limits": "Bez limitu, ale jedno vyhodnocení trvá 30–90 s a zatěžuje CPU (Pi 5 8 GB doporučeno).",
               "quality": "Nejnižší – malé modely oblohu často popíšou špatně. Spíš pro experimenty nebo úplně bez internetu.",
               "key_url": "https://ollama.com/download", "key_label": "instalace Ollama", "usage_url": "",
               "models": [("moondream", "nejmenší, nejrychlejší"), ("qwen2.5vl:3b", "lepší popisy, pomalejší"), ("llava", "klasika, pomalá")]},
}

# --------------------------------------------------------------------------- utils

def slugify(name: str) -> str:
    """Libovolný název (Zahrada – západ) → identifikátor pro Frigate (zahrada_zapad)."""
    text = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-zA-Z0-9]+", "_", text).strip("_").lower()
    if not text:
        text = "kamera"
    if not text[0].isalpha():
        text = "cam_" + text
    return text[:64]


def rtsp_with_auth(url: str, user: str, password: str) -> str:
    """Doplní uživatele a heslo do rtsp:// adresy, pokud v ní ještě nejsou (zakóduje speciální znaky)."""
    url = url.strip()
    if not user or not url:
        return url
    parts = urlsplit(url)
    if parts.username:
        return url
    host = parts.hostname or ""
    if ":" in host:
        host = f"[{host}]"
    netloc = f"{quote(user, safe='')}:{quote(password, safe='')}@{host}" + (f":{parts.port}" if parts.port else "")
    return parts._replace(netloc=netloc).geturl()


def local_ip() -> str:
    try:
        _rc, out = run("hostname -I", timeout=5)
        return (out or "").split()[0]
    except Exception:
        return ""


def public_urls() -> dict:
    """Adresy Atmovio a přehrávače v LAN – pro odkazy v e-mailech a na webu."""
    ip = local_ip()
    return {"atmovio": f"http://{ip}" if ip else "", "frigate": f"https://{ip}:8971" if ip else ""}


def camera_labels(cfg) -> dict:
    names = cfg.get("camera_names")
    return names if isinstance(names, dict) else {}


def cam_label(cfg, cam: str) -> str:
    return camera_labels(cfg).get(cam) or cam


_config_lock = threading.RLock()
_frigate_lock = threading.RLock()
_logger = logging.getLogger("atmovio")


def log(msg: str):
    line = f"{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        _logger.info(line)
    except Exception:
        pass


def deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if CONFIG_FILE.exists():
        try:
            stored = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            if not isinstance(stored, dict):
                raise ValueError("Konfigurace musí být JSON objekt.")
            cfg = deep_merge(cfg, stored)
            if any(not isinstance(cfg[key], dict) for key in ("ai", "email", "vpn", "alerts", "web")):
                raise ValueError("Neplatné sekce konfigurace.")
        except (OSError, ValueError, TypeError) as e:
            raise RuntimeError("Nelze přečíst config.json; obnov zálohu. Konfiguraci nepřepisuji.") from e
    changed = False
    if not cfg["secret"]:
        cfg["secret"] = secrets.token_hex(32)
        changed = True
    if not cfg["admin_password_hash"]:
        pw = os.environ.get("ATMOVIO_ADMIN_PASSWORD", "")
        if len(pw) < 12:
            raise RuntimeError("Pro první spuštění nastav ATMOVIO_ADMIN_PASSWORD (alespoň 12 znaků).")
        cfg["admin_password_hash"] = hash_pw(pw)
        changed = True
    # Starší konfigurace (verze 1) – převod na nové klíče.
    ai = cfg["ai"]
    if "prompt" in ai and ai.get("prompt") and not ai.get("prompt_extra") and ai["prompt"] != DEFAULT_PROMPT:
        ai["prompt_extra"] = "" if "Odpověz POUZE platným JSON" in ai["prompt"] else ai["prompt"]
    ai.pop("prompt", None)
    if not isinstance(ai.get("phenomena"), list):
        ai["phenomena"] = list(PHENOMENA_IDS)
    seen = ai.setdefault("phenomena_seen", [])
    for version, ids in PHENOMENA_ADDED.items():
        if version not in seen:
            ai["phenomena"] = list(dict.fromkeys(ai["phenomena"] + ids))
            seen.append(version)
            changed = True
    if changed:
        save_config(cfg)
    return cfg


def atomic_write(path: Path, content: str):
    """Soubor s tajnými údaji je soukromý už při vytvoření, výměna je atomická."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def save_config(cfg: dict):
    with _config_lock:
        atomic_write(CONFIG_FILE, json.dumps(cfg, indent=2, ensure_ascii=False))


@contextmanager
def edit_config():
    """Jeden zámek pro načtení, změnu i uložení nastavení ve webových vláknech."""
    with _config_lock:
        cfg = load_config()
        yield cfg
        save_config(cfg)


def frigate_transaction(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        with _frigate_lock:
            return fn(*args, **kwargs)
    return wrapped


def hash_pw(pw: str) -> str:
    salt = secrets.token_hex(16)
    rounds = 600_000
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), rounds).hex()
    return f"pbkdf2_sha256${rounds}${salt}${h}"


def check_pw(pw: str, stored: str) -> bool:
    try:
        if stored.startswith("pbkdf2_sha256$"):
            _, rounds, salt, h = stored.split("$")
            return secrets.compare_digest(
                hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), int(rounds)).hex(), h)
        # Staré instalace se po úspěšném přihlášení automaticky převedou.
        salt, h = stored.split("$", 1)
    except (ValueError, TypeError, AttributeError):
        return False
    return secrets.compare_digest(hashlib.sha256((salt + pw).encode()).hexdigest(), h)


def run(cmd, timeout=60, input_text=None) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd, shell=isinstance(cmd, str), capture_output=True, text=True,
            timeout=timeout, input=input_text,
        )
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as e:
        return 1, str(e)


def human_bytes(n) -> str:
    try:
        n = float(n)
    except Exception:
        return "?"
    for unit in ["B", "kB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def human_size(n) -> str:
    """Velikost bez zbytečných desetin: 364 MB, 1,2 GB, 850 kB."""
    try:
        n = float(n)
    except Exception:
        return "?"
    if n >= 1024 ** 3:
        return f"{n / 1024 ** 3:.1f} GB".replace(".", ",")
    if n >= 1024 ** 2:
        return f"{n / 1024 ** 2:.0f} MB"
    if n >= 1024:
        return f"{n / 1024:.0f} kB"
    return f"{n:.0f} B"


def human_minutes(seconds: float) -> str:
    m = int(round(max(0, seconds) / 60))
    if m < 60:
        return f"{m} min"
    return f"{m // 60} h {m % 60} min" if m % 60 else f"{m // 60} h"


def cz_dt(ts, with_year: bool = True) -> str:
    """ISO čas → „9. 9. 2026 08:57“ (ISO zůstane v DB, tohle je jen pro zobrazení)."""
    if not ts:
        return ""
    t = str(ts)
    try:
        d = dt.datetime.fromisoformat(t)
    except ValueError:
        return t[:16].replace("T", " ")
    return f"{d.day}. {d.month}. {d.year} {d:%H:%M}" if with_year else f"{d.day}. {d.month}. {d:%H:%M}"


def cz_date(ts) -> str:
    if not ts:
        return ""
    try:
        d = dt.datetime.fromisoformat(str(ts))
    except ValueError:
        return str(ts)[:10]
    return f"{d.day}. {d.month}. {d.year}"


def human_duration(seconds: float) -> str:
    seconds = int(max(0, seconds))
    if seconds < 3600:
        return f"{seconds // 60} min"
    if seconds < 86400:
        return f"{seconds // 3600} h {seconds % 3600 // 60} min"
    return f"{seconds // 86400} d {seconds % 86400 // 3600} h"


def dir_size(path: Path) -> int:
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except Exception:
        pass
    return total


# --------------------------------------------------------------------------- DB

@contextmanager
def db():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_FILE, timeout=30)
    con.row_factory = sqlite3.Row
    try:
        with con:
            yield con
    finally:
        con.close()


def db_init():
    with db() as con:
        con.execute(
            """CREATE TABLE IF NOT EXISTS evaluations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                camera TEXT NOT NULL,
                image TEXT,
                score INTEGER,
                phenomenon TEXT,
                description TEXT,
                notified INTEGER DEFAULT 0,
                skipped INTEGER DEFAULT 0,
                error TEXT,
                raw TEXT
            )"""
        )
        con.execute("CREATE INDEX IF NOT EXISTS idx_eval_ts ON evaluations(ts)")
        cols = {r["name"] for r in con.execute("PRAGMA table_info(evaluations)")}
        if "phenomena" not in cols:
            con.execute("ALTER TABLE evaluations ADD COLUMN phenomena TEXT")
        if "note" not in cols:
            con.execute("ALTER TABLE evaluations ADD COLUMN note TEXT")
        con.execute(
            """CREATE TABLE IF NOT EXISTS episodes (
                camera TEXT NOT NULL,
                phenomenon TEXT NOT NULL,
                last_seen REAL NOT NULL,
                PRIMARY KEY (camera, phenomenon)
            )"""
        )
        con.execute(
            """CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                kind TEXT NOT NULL,
                subject TEXT NOT NULL,
                message TEXT,
                emailed INTEGER DEFAULT 0
            )"""
        )


        con.execute(
            """CREATE TABLE IF NOT EXISTS disk_smart (
                ts TEXT NOT NULL,
                serial TEXT NOT NULL,
                model TEXT,
                dev TEXT,
                role TEXT,
                healthy INTEGER,
                pending INTEGER,
                reallocated INTEGER,
                uncorrectable INTEGER,
                temp INTEGER
            )"""
        )
        con.execute("CREATE INDEX IF NOT EXISTS idx_smart ON disk_smart(serial, ts)")
        con.execute(
            """CREATE TABLE IF NOT EXISTS ai_stats (
                day TEXT NOT NULL,
                camera TEXT NOT NULL,
                calls INTEGER DEFAULT 0,
                skipped INTEGER DEFAULT 0,
                errors INTEGER DEFAULT 0,
                interesting INTEGER DEFAULT 0,
                notified INTEGER DEFAULT 0,
                PRIMARY KEY (day, camera)
            )"""
        )
        con.execute(
            """CREATE TABLE IF NOT EXISTS exports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frigate_id TEXT NOT NULL,
                detection_id INTEGER,
                camera TEXT NOT NULL,
                name TEXT NOT NULL,
                start_ts REAL NOT NULL,
                end_ts REAL NOT NULL,
                created TEXT NOT NULL
            )"""
        )
        cols = {r["name"] for r in con.execute("PRAGMA table_info(exports)")}
        if "auto" not in cols:
            con.execute("ALTER TABLE exports ADD COLUMN auto INTEGER DEFAULT 0")
        if "retries" not in cols:
            con.execute("ALTER TABLE exports ADD COLUMN retries INTEGER DEFAULT 0")
        con.execute(
            """CREATE TABLE IF NOT EXISTS auto_exports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                detection_id INTEGER NOT NULL,
                camera TEXT NOT NULL,
                name TEXT NOT NULL,
                start_ts REAL NOT NULL,
                end_ts REAL NOT NULL,
                due_ts REAL NOT NULL,
                playback TEXT NOT NULL DEFAULT 'realtime',
                status TEXT NOT NULL DEFAULT 'pending',
                message TEXT,
                created TEXT NOT NULL
            )"""
        )
        con.execute(
            """CREATE TABLE IF NOT EXISTS studio_videos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                export_id INTEGER NOT NULL,
                camera TEXT NOT NULL,
                name TEXT NOT NULL,
                speed INTEGER NOT NULL,
                intro INTEGER DEFAULT 0,
                music TEXT DEFAULT '',
                text TEXT DEFAULT '',
                title TEXT DEFAULT '',
                description TEXT DEFAULT '',
                status TEXT NOT NULL DEFAULT 'queued',
                message TEXT DEFAULT '',
                file TEXT,
                duration REAL,
                created TEXT NOT NULL,
                finished TEXT,
                auto INTEGER DEFAULT 0,
                yt_id TEXT,
                yt_url TEXT,
                yt_status TEXT
            )"""
        )
        scols = {r["name"] for r in con.execute("PRAGMA table_info(studio_videos)")}
        for col in ("yt_meta TEXT", "yt_error TEXT"):
            if col.split()[0] not in scols:
                con.execute(f"ALTER TABLE studio_videos ADD COLUMN {col}")
        # po restartu (výpadek proudu uprostřed ffmpegu) se rozdělané video vyrobí znovu
        con.execute("UPDATE studio_videos SET status='queued' WHERE status='rendering'")
        con.execute("UPDATE studio_videos SET yt_status='queued' WHERE yt_status='uploading'")


AI_STAT_COLS = ("calls", "skipped", "errors", "interesting", "notified")


def ai_stat(day: str, camera: str, **inc):
    """Přičte počty do denní statistiky AI (nezávislé na řádcích historie – mazání historie je nemění)."""
    cols = [c for c in AI_STAT_COLS if inc.get(c)]
    if not cols:
        return
    try:
        with db() as con:
            con.execute("INSERT OR IGNORE INTO ai_stats (day, camera) VALUES (?,?)", (day, camera))
            con.execute("UPDATE ai_stats SET " + ", ".join(f"{c}={c}+?" for c in cols) + " WHERE day=? AND camera=?",
                        (*[int(inc[c]) for c in cols], day, camera))
    except Exception as e:
        log(f"Statistika AI: {e}")


def ai_stats_seed(threshold: int):
    """Jednorázově naplní statistiku z existující historie (při prvním startu nové verze)."""
    try:
        with db() as con:
            if con.execute("SELECT 1 FROM ai_stats LIMIT 1").fetchone():
                return
            con.execute(
                "INSERT INTO ai_stats (day, camera, calls, skipped, errors, interesting, notified) "
                "SELECT substr(ts,1,10), camera, SUM(skipped=0), SUM(skipped=1), "
                "SUM(error IS NOT NULL AND error != ''), SUM(skipped=0 AND COALESCE(score,0) >= ?), SUM(notified=1) "
                "FROM evaluations GROUP BY substr(ts,1,10), camera", (int(threshold),))
    except Exception as e:
        log(f"Statistika AI: naplnění z historie selhalo: {e}")


def ai_stats_days(now, days: int = 7) -> list:
    """Denní přehled za posledních N dní (dnes první), chybějící dny s nulami."""
    start = (now.date() - dt.timedelta(days=days - 1)).isoformat()
    rows = {}
    try:
        with db() as con:
            for r in con.execute(
                    "SELECT day, SUM(calls) AS calls, SUM(skipped) AS skipped, SUM(errors) AS errors, "
                    "SUM(interesting) AS interesting, SUM(notified) AS notified FROM ai_stats WHERE day >= ? GROUP BY day", (start,)):
                rows[r["day"]] = dict(r)
    except Exception:
        pass
    out = []
    for i in range(days):
        d = now.date() - dt.timedelta(days=i)
        r = rows.get(d.isoformat()) or {}
        out.append({"day": d.isoformat(), "label": ("dnes" if i == 0 else "včera" if i == 1 else f"{d.day}. {d.month}."),
                    "dow": ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"][d.weekday()],
                    **{c: int(r.get(c) or 0) for c in AI_STAT_COLS}})
    return out


def add_event(kind: str, subject: str, message: str = "", emailed: int = 0):
    try:
        with db() as con:
            con.execute("INSERT INTO events (ts, kind, subject, message, emailed) VALUES (?,?,?,?,?)",
                        (dt.datetime.now().isoformat(timespec="seconds"), kind, subject, message, emailed))
    except Exception as e:
        log(f"Nelze zapsat událost: {e}")


# --------------------------------------------------------------------------- Frigate helpers

yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)


@frigate_transaction
def frigate_read_yaml(cfg) -> dict:
    p = Path(cfg["frigate_config_path"])
    if not p.exists():
        return {}
    with open(p, encoding="utf-8") as f:
        return yaml.load(f) or {}


@frigate_transaction
def frigate_write_yaml(cfg, data):
    p = Path(cfg["frigate_config_path"])
    backup = p.with_suffix(".yml.bak")
    if p.exists():
        shutil.copy2(p, backup)
        os.chmod(backup, 0o600)
    content = io.StringIO()
    yaml.dump(data, content)
    atomic_write(p, content.getvalue())


def frigate_restart():
    if (APP_DIR / "storage_guard.py").exists():
        atomic_write(APP_DIR / "storage-restart", str(time.time_ns()))
        return 0, "Restart provede správce úložiště podle stavu HDD."
    return run(["docker", "restart", FRIGATE_CONTAINER], timeout=120)


def frigate_fix_config(cfg) -> list[str]:
    """Opraví konfiguraci Frigate na formát 0.17 (record.retain -> record.continuous). Vrací seznam provedených oprav."""
    fixes: list[str] = []
    try:
        data = frigate_read_yaml(cfg)
    except Exception as e:
        log(f"Frigate: konfiguraci nelze načíst: {e}")
        return fixes
    rec = data.get("record")
    if not isinstance(rec, dict):
        return fixes
    if "retain" in rec:
        old = rec.pop("retain") or {}
        days = int(old.get("days", cfg.get("retain_days", 7)) or 7)
        rec.setdefault("continuous", {})["days"] = days
        fixes.append(f"record.retain (starý formát) převedeno na record.continuous, {days} dní")
    for k in ("alerts", "detections"):
        if k in rec and isinstance(rec[k], dict) and "retain" in rec[k] and "mode" in rec[k]["retain"]:
            rec[k]["retain"].pop("mode", None)
            fixes.append(f"record.{k}.retain.mode odstraněno (0.17 ho nezná)")
    if fixes:
        frigate_write_yaml(cfg, data)
        log("Frigate: konfigurace opravena – " + "; ".join(fixes))
    return fixes


def frigate_safe_mode() -> str:
    """Vrátí popis chyby konfigurace, pokud Frigate běží v nouzovém režimu (config odmítnut). Jinak ''."""
    _rc, out = run(["docker", "logs", "--tail", "400", FRIGATE_CONTAINER], timeout=15)
    if not out:
        return ""
    # "[INFO] Starting Frigate..." je začátek posledního startu kontejneru (validace configu následuje hned po něm).
    starts = [m.start() for m in re.finditer(r"\[INFO\] Starting Frigate\.\.\.", out)]
    tail = out[starts[-1]:] if starts else out
    if "safe mode" not in tail.lower() and "Config Validation Errors" not in tail:
        return ""
    details = []
    for m in re.finditer(r"Key\s*:\s*(.+?)\n.*?Value\s*:\s*(.+?)\n.*?Message\s*:\s*(.+?)\n", tail, re.S):
        details.append(f"{m.group(1).strip()} = {m.group(2).strip()} – {m.group(3).strip()}")
    return "; ".join(details) if details else "Frigate odmítl konfiguraci (viz Logy → Frigate)."


def storage_status():
    if not (APP_DIR / "storage_guard.py").exists():
        return {"mode": "legacy", "reason": ""}
    try:
        status_file = Path("/run/atmovio/storage-status.json")
        if not status_file.exists():
            status_file = APP_DIR / "storage-status.json"  # starší verze hlídače (před updatem)
        status = json.loads(status_file.read_text())
        if time.time() - status["checked_at"] <= 15:
            return status
    except (OSError, ValueError, KeyError):
        pass
    return {"mode": "unknown", "reason": "Čekám na kontrolu HDD. Ukládání snímků je pozastavené."}


def storage_ready():
    return storage_status()["mode"] in ("recording", "legacy")


def frigate_api(cfg, path, **kw):
    url = cfg["frigate_url"].rstrip("/") + path
    return requests.get(url, timeout=kw.pop("timeout", 10), **kw)


def frigate_set_admin_password(cfg, password: str) -> bool:
    """Nastaví heslo uživatele admin ve Frigate přes lokální API (port 5000 bez přihlášení)."""
    try:
        r = requests.put(cfg["frigate_url"].rstrip("/") + "/api/users/admin/password",
                         json={"password": password}, timeout=10)
        return r.ok
    except Exception as e:
        log(f"Frigate: heslo se nepodařilo nastavit: {e}")
        return False


def frigate_cameras(cfg) -> list:
    """Seznam kamer z Frigate API, fallback na YAML."""
    try:
        r = frigate_api(cfg, "/api/config")
        if r.ok:
            return sorted((r.json().get("cameras") or {}).keys())
    except Exception:
        pass
    try:
        return sorted((frigate_read_yaml(cfg).get("cameras") or {}).keys())
    except Exception:
        return []


def frigate_status(cfg) -> dict:
    out = {"online": False, "version": "", "cameras": {}}
    try:
        r = frigate_api(cfg, "/api/version", timeout=4)
        if r.ok:
            out["online"] = True
            out["version"] = r.text.strip().strip('"')
    except Exception:
        return out
    try:
        r = frigate_api(cfg, "/api/stats", timeout=6)
        if r.ok:
            st = r.json()
            out["uptime"] = float((st.get("service") or {}).get("uptime") or 0)   # s od startu Frigate
            for cam, s in (st.get("cameras") or {}).items():
                out["cameras"][cam] = {
                    "fps": s.get("camera_fps"),
                    "pid": s.get("ffmpeg_pid"),
                }
    except Exception:
        pass
    return out


def ffmpeg_frame(url: str, timeout=20) -> bytes | None:
    """Jeden snímek z RTSP (go2rtc restream) v plném rozlišení – jednorázově, bez trvalé zátěže CPU."""
    try:
        p = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-rtsp_transport", "tcp", "-i", url,
             "-frames:v", "1", "-q:v", "3", "-f", "image2", "pipe:1"],
            capture_output=True, timeout=timeout,
        )
        if p.returncode == 0 and p.stdout[:2] == b"\xff\xd8":
            return p.stdout
    except Exception:
        pass
    return None


def fetch_snapshot(cfg, camera: str) -> bytes | None:
    """Plný snímek hlavního streamu přímo z kamery (ffmpeg); záložně náhled z Frigate (rozlišení substreamu).
    Přes go2rtc restream se nechodí – u některých kamer z něj obraz nejde a každý pokus jen plní log."""
    if re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        try:
            streams = frigate_read_yaml(cfg).get("go2rtc", {}).get("streams", {}) or {}
            src = streams.get(camera)
            direct = plain_rtsp(src[0] if isinstance(src, list) and src else (src or ""))
        except Exception:
            direct = ""
        if direct.startswith("rtsp"):
            img = ffmpeg_frame(direct)
            if img:
                return img
    for url in (
        f"{cfg['frigate_url'].rstrip('/')}/api/{camera}/latest.jpg?h=720",
    ):
        try:
            r = requests.get(url, timeout=20)
            if r.ok and r.content[:2] == b"\xff\xd8":
                return r.content
        except Exception:
            continue
    return None


_camera_info_cache: dict = {}


def camera_info(cfg, camera: str) -> dict:
    """IP kamery a cesta k ní (LAN / VPN) podle adresy streamu a směrovací tabulky."""
    now = time.time()
    cached = _camera_info_cache.get(camera)
    if cached and now - cached["at"] < 300:
        return cached
    info = {"ip": "", "via": "LAN", "iface": "", "at": now}
    try:
        streams = frigate_read_yaml(cfg).get("go2rtc", {}).get("streams", {}) or {}
        src = streams.get(camera)
        url = src[0] if isinstance(src, list) and src else (src if isinstance(src, str) else "")
        host = urlsplit(plain_rtsp(url)).hostname or ""
        if host:
            info["ip"] = host
            rc, route = run(["ip", "route", "get", host], timeout=5)
            m = re.search(r"\bdev\s+(\S+)", route or "")
            if rc == 0 and m:
                info["iface"] = m.group(1)
                if m.group(1).startswith("wg") or m.group(1) == cfg.get("vpn", {}).get("iface"):
                    info["via"] = f"VPN WireGuard ({m.group(1)})"
    except Exception:
        pass
    _camera_info_cache[camera] = info
    return info


@frigate_transaction
def frigate_reset_admin_password(cfg) -> str:
    """Nastaví auth.reset_admin_password, restartuje Frigate a vyčte nové heslo z logu."""
    data = frigate_read_yaml(cfg)
    data.setdefault("auth", {})["reset_admin_password"] = True
    frigate_write_yaml(cfg, data)
    since = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    rc, _out = frigate_restart()
    if rc:
        data["auth"]["reset_admin_password"] = False
        frigate_write_yaml(cfg, data)
        return ""
    password = ""
    for _ in range(40):
        time.sleep(3)
        _rc, logs = run(["docker", "logs", "--since", since, FRIGATE_CONTAINER], timeout=20)
        m = re.findall(r"Password:\s*(\S+)", logs)
        if m:
            password = m[-1]
            break
    data = frigate_read_yaml(cfg)
    data.setdefault("auth", {})["reset_admin_password"] = False
    frigate_write_yaml(cfg, data)
    return password


# --------------------------------------------------------------------------- AI providers

def build_prompt(ai: dict) -> str:
    selected = phenomena_catalog(ai)
    lines = [DEFAULT_PROMPT, "", "Sledované jevy (id – popis):"]
    lines += [f"- {pid}: {label} – {desc}" for pid, label, desc in selected]
    lines += [
        "",
        "Hodnocení score: 0–3 nudná, šedá, tmavá nebo rozmazaná obloha; 4–6 hezká, ale běžná obloha; "
        "7–8 výrazný, fotogenický jev; 9–10 výjimečná podívaná.",
        "Do pole phenomena dej jen id ze seznamu, které jsou na snímku SKUTEČNĚ vidět; jinak prázdné pole. "
        "Nehodnoť objekty na zemi, jen oblohu a počasí.",
    ]
    if ai.get("prompt_extra"):
        lines += ["", "Doplňující pokyny: " + ai["prompt_extra"].strip()]
    lines += [
        "",
        "Odpověz POUZE platným JSON bez dalšího textu ve tvaru: "
        '{"score": <celé číslo 0-10>, "phenomena": ["id", ...], '
        '"phenomenon": "<krátký název jevu česky nebo \\"nic zajímavého\\">", "description": "<1-2 věty česky, co je vidět>"}',
    ]
    return "\n".join(lines)


def extract_json(text: str) -> dict:
    text = text.strip()
    m = re.search(r"\{.*\}", text, re.S)
    if m:
        text = m.group(0)
    return json.loads(text)


def _openai_style(url, key, model, prompt, b64, extra_headers=None):
    headers = {"Authorization": f"Bearer {key}", **(extra_headers or {})}
    r = requests.post(
        url,
        headers=headers,
        json={
            "model": model, "max_tokens": 400, "temperature": 0.2,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ]}],
        }, timeout=90,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


_gemini_models_cache = {"at": 0, "key": "", "names": []}


def gemini_models(key: str) -> list:
    """Modely, které Google pro tento klíč nabízí (podporující generateContent); cache 1 h."""
    now = time.time()
    if _gemini_models_cache["key"] == key and now - _gemini_models_cache["at"] < 3600 and _gemini_models_cache["names"]:
        return _gemini_models_cache["names"]
    r = requests.get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
                     headers={"x-goog-api-key": key}, timeout=20)
    r.raise_for_status()
    names = [m.get("name", "").replace("models/", "") for m in r.json().get("models", [])
             if "generateContent" in (m.get("supportedGenerationMethods") or ["generateContent"])]
    _gemini_models_cache.update(at=now, key=key, names=names)
    return names


def gemini_pick_model(key: str) -> str:
    """Nejnovější stabilní Flash-Lite model (bezplatný tarif: ~500 požadavků/den; plný Flash má jen ~20/den,
    což na hlídání oblohy nestačí). Když lite není, plný Flash; když ani ten, cokoli z řady gemini."""
    names = gemini_models(key)
    bad = ("preview", "exp", "tts", "image", "live", "audio", "thinking", "embedding", "robotics", "computer", "8b", "latest")
    def version(n):
        m = re.search(r"gemini-(\d+)(?:\.(\d+))?", n)
        return (int(m.group(1)), int(m.group(2) or 0)) if m else (0, 0)
    for pattern in (lambda n: "flash-lite" in n, lambda n: "flash" in n, lambda n: "gemini" in n):
        cands = [n for n in names if n.startswith("gemini") and pattern(n) and not any(b in n for b in bad)]
        if cands:
            return sorted(cands, key=version, reverse=True)[0]
    return ""


def gemini_resolve_model(ai: dict) -> str:
    """Nastavený model, nebo automaticky vybraný; automatický výběr se uloží do nastavení, aby byl vidět."""
    model = (ai.get("model") or "auto").strip()
    if model and model != "auto":
        return model
    picked = gemini_pick_model(ai["api_key"])
    if not picked:
        raise RuntimeError("Google pro tento klíč nenabízí žádný model Gemini – zkontroluj klíč na aistudio.google.com/apikey.")
    return picked


AI_TRANSIENT_CODES = (500, 502, 503, 504, 529)


def ai_evaluate(ai: dict, image_bytes: bytes) -> tuple[dict, str]:
    """Vrátí (parsed, raw_text). Dočasné chyby poskytovatele (přetížení 503/529, timeout, výpadek spojení)
    zkusí ještě 2× s odstupem – zajímavá obloha nemá propadnout kvůli minutovému zaškobrtnutí Googlu."""
    delays = (5, 20)
    last: Exception | None = None
    for attempt in range(3):
        try:
            return _ai_evaluate_once(ai, image_bytes)
        except (requests.Timeout, requests.ConnectionError) as e:
            last = e
            why = "neodpověděl včas" if isinstance(e, requests.Timeout) else "spojení selhalo"
        except requests.HTTPError as e:
            code = e.response.status_code if e.response is not None else 0
            if code not in AI_TRANSIENT_CODES:
                raise
            last = e
            why = f"HTTP {code} (přetížení)"
        if attempt < 2:
            log(f"AI: poskytovatel {why} – zkouším znovu za {delays[attempt]} s (pokus {attempt + 2}/3)")
            time.sleep(delays[attempt])
    raise last  # type: ignore[misc]


def _ai_evaluate_once(ai: dict, image_bytes: bytes) -> tuple[dict, str]:
    b64 = base64.b64encode(image_bytes).decode()
    provider = ai["provider"]
    prompt = build_prompt(ai)
    model = ai["model"] or PROVIDER_MODELS.get(provider, "")
    key = ai["api_key"]

    if provider == "gemini":
        model = gemini_resolve_model(ai)
        body = {
            "contents": [{"parts": [
                {"text": prompt},
                {"inline_data": {"mime_type": "image/jpeg", "data": b64}},
            ]}],
            "generationConfig": {"response_mime_type": "application/json", "temperature": 0.2},
        }
        for attempt in (1, 2):
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            r = requests.post(url, headers={"x-goog-api-key": key}, json=body, timeout=60)
            if r.status_code in (429, 503) and attempt == 1 and "lite" not in model:
                # Vyčerpaný bezplatný limit – lite varianta má vyšší denní kvótu; zkus ji, jinak počkat na další den.
                lite = next((n for n in sorted(gemini_models(key), reverse=True) if "flash-lite" in n
                             and not any(b in n for b in ("preview", "exp", "image", "audio", "tts", "live"))), "")
                if lite:
                    log(f"AI: model {model} hlásí {r.status_code} (vyčerpaný limit / přetížení Google) – zkouším {lite}")
                    model = lite
                    continue
            if r.status_code == 404 and attempt == 1:
                # Model už Google nenabízí (ruší je průběžně) – vyber nový a přepni natrvalo.
                _gemini_models_cache["at"] = 0
                picked = gemini_pick_model(key)
                if not picked or picked == model:
                    r.raise_for_status()
                log(f"AI: model {model} už Google nenabízí (404) – přepínám na {picked}")
                with edit_config() as cfg:
                    cfg["ai"]["model"] = "auto"
                model = picked
                continue
            r.raise_for_status()
            break
        raw = r.json()["candidates"][0]["content"]["parts"][0]["text"]

    elif provider == "anthropic":
        r = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={
                "model": model, "max_tokens": 400,
                "messages": [{"role": "user", "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64}},
                    {"type": "text", "text": prompt},
                ]}],
            }, timeout=90,
        )
        r.raise_for_status()
        raw = "".join(p.get("text", "") for p in r.json()["content"])

    elif provider == "openai":
        raw = _openai_style("https://api.openai.com/v1/chat/completions", key, model, prompt, b64)

    elif provider == "openai_compat":
        base = (ai.get("base_url") or "https://api.groq.com/openai/v1").rstrip("/")
        raw = _openai_style(base + "/chat/completions", key, model, prompt, b64,
                            {"HTTP-Referer": "https://atmovio.local", "X-Title": "Atmovio"})

    elif provider == "ollama":
        r = requests.post(
            ai["ollama_url"].rstrip("/") + "/api/generate",
            json={"model": model, "prompt": prompt, "images": [b64], "stream": False, "format": "json"},
            timeout=600,
        )
        r.raise_for_status()
        raw = r.json()["response"]
    else:
        raise ValueError(f"Neznámý poskytovatel: {provider}")

    parsed = extract_json(raw)
    if not isinstance(parsed, dict) or isinstance(parsed.get("score"), bool):
        raise ValueError("AI nevrátila objekt s číselným skóre 0–10.")
    score = float(parsed.get("score", -1))
    if not 0 <= score <= 10:
        raise ValueError("Skóre AI musí být v rozsahu 0–10.")
    phenomena = parsed.get("phenomena") or []
    if not isinstance(phenomena, list):
        phenomena = [phenomena]
    phenomena = [str(p).strip().lower() for p in phenomena]
    known = [p[0] for p in phenomena_catalog(ai)]
    phenomena = [p for p in phenomena if p in known]
    return {
        "score": int(score),
        "phenomena": phenomena,
        "phenomenon": str(parsed.get("phenomenon", ""))[:200],
        "description": str(parsed.get("description", ""))[:1000],
    }, raw


def ai_text(ai: dict, prompt: str, max_tokens: int = 400) -> str:
    """Jednoduchý textový dotaz na nastaveného poskytovatele AI (bez obrázku) – např. návrh titulku videa."""
    provider = ai.get("provider") or "gemini"
    model = ai.get("model") or PROVIDER_MODELS.get(provider, "")
    key = ai.get("api_key") or ""
    if provider != "ollama" and not key:
        raise RuntimeError("AI nemá nastavený klíč (Nastavení → AI).")
    if provider == "gemini":
        model = gemini_resolve_model(ai)
        r = requests.post(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", headers={"x-goog-api-key": key},
                          json={"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.9, "maxOutputTokens": max_tokens}}, timeout=45)
        r.raise_for_status()
        return r.json()["candidates"][0]["content"]["parts"][0]["text"]
    if provider == "anthropic":
        r = requests.post("https://api.anthropic.com/v1/messages", headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
                          json={"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": prompt}]}, timeout=45)
        r.raise_for_status()
        return "".join(p.get("text", "") for p in r.json()["content"])
    if provider in ("openai", "openai_compat"):
        base = "https://api.openai.com/v1" if provider == "openai" else (ai.get("base_url") or "https://api.groq.com/openai/v1").rstrip("/")
        r = requests.post(base + "/chat/completions", headers={"Authorization": f"Bearer {key}", "HTTP-Referer": "https://atmovio.local", "X-Title": "Atmovio"},
                          json={"model": model, "max_tokens": max_tokens, "temperature": 0.9, "messages": [{"role": "user", "content": prompt}]}, timeout=45)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
    if provider == "ollama":
        r = requests.post(ai["ollama_url"].rstrip("/") + "/api/generate", json={"model": model, "prompt": prompt, "stream": False}, timeout=300)
        r.raise_for_status()
        return r.json()["response"]
    raise ValueError(f"Neznámý poskytovatel: {provider}")


def ai_check(ai: dict) -> str:
    """Ověří klíč a spojení bez odeslání obrázku. Vrátí text pro uživatele; chyby vyhazuje."""
    provider = ai["provider"]
    key = ai["api_key"]
    model = ai["model"] or PROVIDER_MODELS.get(provider, "")
    if provider == "gemini":
        _gemini_models_cache["at"] = 0
        names = gemini_models(key)
        picked = gemini_pick_model(key)
        if not names:
            raise RuntimeError("Klíč je platný, ale Google pro něj nenabízí žádný model.")
        if model in ("", "auto"):
            return f"Klíč funguje. Model se vybírá automaticky – teď: {picked}. Dalších modelů k dispozici: {len(names) - 1}."
        if model in names:
            return f"Klíč funguje. Model {model} je dostupný. (Automatický výběr by dal {picked}.)"
        with edit_config() as cfg:
            cfg["ai"]["model"] = "auto"
        return (f"Klíč funguje, ale model {model} už Google nenabízí – přepnuto na automatický výběr (teď {picked}). "
                f"Dostupné: {', '.join(n for n in names if 'flash' in n)[:300]}")
    if provider in ("openai", "openai_compat"):
        base = "https://api.openai.com/v1" if provider == "openai" else (ai.get("base_url") or "").rstrip("/")
        r = requests.get(base + "/models", headers={"Authorization": f"Bearer {key}"}, timeout=20)
        r.raise_for_status()
        names = [m.get("id", "") for m in r.json().get("data", [])]
        found = model in names
        return (f"Klíč funguje ({base}). Model {model} {'je dostupný' if found else 'NENÍ v seznamu – zkontroluj název'}. "
                f"Celkem {len(names)} modelů.")
    if provider == "anthropic":
        r = requests.get("https://api.anthropic.com/v1/models", headers={"x-api-key": key, "anthropic-version": "2023-06-01"}, timeout=20)
        r.raise_for_status()
        names = [m.get("id", "") for m in r.json().get("data", [])]
        return f"Klíč funguje. Model {model} {'je dostupný' if model in names else 'NENÍ v seznamu'}. Modely: {', '.join(names[:10])}"
    if provider == "ollama":
        r = requests.get(ai["ollama_url"].rstrip("/") + "/api/tags", timeout=20)
        r.raise_for_status()
        names = [m.get("name", "") for m in r.json().get("models", [])]
        ok = any(n == model or n.split(":")[0] == model for n in names)
        return f"Ollama běží. Model {model} {'je stažený' if ok else 'NENÍ stažený – spusť: ollama pull ' + model}. Stažené: {', '.join(names) or 'žádné'}"
    raise ValueError("Neznámý poskytovatel AI.")


# --------------------------------------------------------------------------- e-mail

def send_email(em: dict, subject: str, body: str, image: bytes | None = None, image_name="snimek.jpg"):
    if not em["host"] or not em["to"]:
        raise ValueError("SMTP server nebo příjemce nejsou nastaveny")
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = em["from"] or em["user"]
    msg["To"] = em["to"]
    msg.set_content(body)
    if image and em.get("attach", True):
        msg.add_attachment(image, maintype="image", subtype="jpeg", filename=image_name)
    port = int(em["port"] or 587)
    if em["security"] == "ssl":
        s = smtplib.SMTP_SSL(em["host"], port, timeout=30, context=ssl.create_default_context())
    else:
        s = smtplib.SMTP(em["host"], port, timeout=30)
        s.ehlo()
        if em["security"] == "starttls":
            s.starttls(context=ssl.create_default_context())
            s.ehlo()
    try:
        if em["user"]:
            s.login(em["user"], em["password"])
        s.send_message(msg)
    finally:
        s.quit()


def email_ready(cfg) -> bool:
    em = cfg.get("email", {})
    return bool(em.get("host") and em.get("to"))


# --------------------------------------------------------------------------- webhook (vlastní web) – viz docs/webhook.md

def web_ready(cfg) -> bool:
    w = cfg.get("web", {})
    return bool(w.get("enabled") and w.get("url") and w.get("token"))


def web_post(cfg, payload: dict, timeout=20) -> dict:
    """POST JSON na webhook s tokenem (Authorization: Bearer + X-Token). Vrací odpověď serveru; chyby vyhazuje."""
    w = cfg["web"]
    # Token jde v Authorization i v X-Token – sdílené hostingy Authorization do PHP často nepředají.
    r = requests.post(w["url"], json=payload, timeout=timeout,
                      headers={"Authorization": f"Bearer {w['token']}", "X-Token": w["token"],
                               "User-Agent": f"Atmovio/{APP_VERSION}"})
    try:
        data = r.json()
    except ValueError:
        data = {}
    if not r.ok or not data.get("ok"):
        raise RuntimeError(data.get("error") or f"HTTP {r.status_code}")
    return data


def web_event(cfg, kind: str, subject: str, message: str, camera: str = "", score=None, phenomena=None,
              image: bytes | None = None, ts: dt.datetime | None = None, link: str = "") -> dict:
    urls = public_urls()
    payload = {
        "type": "event", "kind": kind, "camera": camera, "camera_label": cam_label(cfg, camera) if camera else "",
        "subject": subject, "message": message, "link": link, "frigate_url": urls["frigate"],
        "ts": (ts or dt.datetime.now()).isoformat(timespec="seconds"),
    }
    if score is not None:
        payload["score"] = int(score)
    if phenomena:
        payload["phenomena"] = list(phenomena)
    if image:
        payload["image"] = base64.b64encode(image).decode()
    return web_post(cfg, payload, timeout=40)


def deliver(cfg, subject: str, body: str, image: bytes | None = None, image_name: str = "snimek.jpg",
            kind: str = "system", camera: str = "", score=None, phenomena=None, ts: dt.datetime | None = None,
            link: str = "") -> str:
    """Doručí upozornění všemi nastavenými kanály (web, e-mail). Vrací názvy kanálů; bez doručení vyhazuje."""
    channels, errors = [], []
    if web_ready(cfg):
        try:
            resp = web_event(cfg, kind, subject, body, camera, score, phenomena, image, ts, link)
            channels.append("web" + (" + e-mail z webu" if resp.get("emailed") else ""))
        except Exception as e:
            errors.append(f"web: {e}")
    if email_ready(cfg) or not channels:
        try:
            send_email(cfg["email"], subject, body, image, image_name)
            channels.append("e-mail")
        except Exception as e:
            errors.append(f"e-mail: {e}")
    if not channels:
        raise RuntimeError("; ".join(errors) or "žádný kanál upozornění není nastaven")
    if errors:
        log("Upozornění doručeno jen částečně: " + "; ".join(errors))
    return ", ".join(channels)


_web_sent: dict[str, set] = {"det": set(), "vid": set()}   # id, jejichž náhled už web dostal (po restartu se pošlou znovu – neškodí)


def small_jpeg_b64(data: bytes, height: int = 240, max_bytes: int = 120_000) -> str | None:
    """Zmenšený JPEG pro web (base64) – aby heartbeat zůstal malý."""
    try:
        im = Image.open(io.BytesIO(data))
        im.thumbnail((height * 4, height))
        buf = io.BytesIO()
        im.convert("RGB").save(buf, "JPEG", quality=72, optimize=True)
        out = buf.getvalue()
        return base64.b64encode(out).decode() if len(out) <= max_bytes else None
    except Exception:
        return None


def web_api_snapshot(cfg, fs: dict, base: str) -> dict:
    """Vše, co nabízí REST API (stejná pole), pro stránku IP kamery na webu – web se na RPi nedostane, tak mu to RPi posílá.
    Náhledy detekcí a videí jdou jen k novým položkám (max. 3 + 3 za minutu)."""
    detections = api_detections_data(cfg, base, limit=30) if storage_ready() else []
    videos = api_videos_data(cfg, base) if storage_ready() else []
    sent = 0
    snap_dir = Path(cfg["snapshot_dir"])
    with db() as con:
        for d in detections:
            if sent >= 3 or d["id"] in _web_sent["det"]:
                continue
            row = con.execute("SELECT image FROM evaluations WHERE id=?", (d["id"],)).fetchone()
            f = snap_dir / str(row["image"]) if row and row["image"] else None
            if f and f.is_file():
                b64 = small_jpeg_b64(f.read_bytes())
                if b64:
                    d["thumb"] = b64; sent += 1
            _web_sent["det"].add(d["id"])
    sent = 0
    thumbs = {v["id"]: v.get("thumb_path") for v in list_videos(cfg)} if videos else {}
    for v in videos:
        if sent >= 3 or v["id"] in _web_sent["vid"] or not v["ready"]:
            continue
        f = Path(thumbs.get(v["id"]) or "")
        if f.is_file():
            b64 = small_jpeg_b64(f.read_bytes())
            if b64:
                v["thumb"] = b64; sent += 1
        _web_sent["vid"].add(v["id"])
    return {"status": api_status_data(cfg, fs), "cameras": api_cameras_data(cfg, base, fs),
            "detections": detections, "videos": videos, "events": api_events_data(30)}


def web_heartbeat(cfg, fs: dict, watcher_status: str, outages: dict) -> None:
    """Stav NVR + kamer + náhledy pro přehled na webu (1× za minutu)."""
    w = cfg["web"]
    d = disk_info(cfg["recordings_path"]) if storage_ready() else {"pct": 0, "free_h": "–"}
    sysi = sys_info()
    cameras = []
    last_eval = {}   # poslední hodnocení AI (i to, které nedosáhlo prahu) – web ho ukazuje pod aktuálním snímkem
    try:
        with db() as con:
            for c in (cfg["ai"].get("cameras") or []):
                r = con.execute("SELECT id, ts, score, phenomenon, description, notified FROM evaluations "
                                "WHERE camera=? AND skipped=0 AND error IS NULL AND image IS NOT NULL ORDER BY id DESC LIMIT 1", (c,)).fetchone()
                if r:
                    last_eval[c] = {"id": r["id"], "ts": r["ts"], "score": int(r["score"] or 0), "phenomenon": r["phenomenon"] or "",
                                    "description": (r["description"] or "")[:600], "notified": bool(r["notified"])}
    except Exception as e:
        log(f"Web: poslední hodnocení AI pro heartbeat se nepodařilo načíst: {e}")
    for cam in frigate_cameras(cfg):
        s = fs["cameras"].get(cam) or {}
        info = camera_info(cfg, cam)
        fps = float(s.get("fps") or 0)
        entry = {"name": cam, "label": cam_label(cfg, cam), "ip": info["ip"], "via": info["via"],
                 "online": bool(fs["online"] and fps > 0), "fps": round(fps, 1), "ai": cam in cfg["ai"]["cameras"]}
        if cam in last_eval:
            entry["last_eval"] = last_eval[cam]
        if w.get("thumbs", True) and entry["online"]:
            try:
                r = frigate_api(cfg, f"/api/{cam}/latest.jpg?h=240", timeout=6)
                if r.ok and r.content[:2] == b"\xff\xd8" and len(r.content) < 190_000:
                    entry["thumb"] = base64.b64encode(r.content).decode()
            except Exception:
                pass
        cameras.append(entry)
    ai = cfg["ai"]
    urls = public_urls()
    try:
        api = web_api_snapshot(cfg, fs, urls["atmovio"])
    except Exception as e:
        log(f"Web: data z API pro heartbeat se nepodařilo sestavit: {e}")
        api = None
    web_post(cfg, {
        "type": "heartbeat", "nvr": w.get("nvr_name") or "Raspberry Pi NVR", "version": APP_VERSION, "api": api,
        "atmovio_url": urls["atmovio"], "skywatch_url": urls["atmovio"], "frigate_url": urls["frigate"],  # skywatch_url = starý název pole (přijímače do 3.x)
        "status": {
            "frigate_online": "1" if fs["online"] else "0", "frigate_version": fs.get("version", ""),
            "storage_mode": storage_status()["mode"], "disk_pct": d.get("pct", 0), "disk_free": d.get("free_h", ""),
            "ai_enabled": "1" if ai["enabled"] else "0", "ai_status": watcher_status,
            "hostname": sysi.get("hostname", ""), "temp": sysi.get("temp", ""), "uptime": sysi.get("uptime", ""), "load": sysi.get("load", ""),
        },
        "cameras": cameras,
    }, timeout=30)


# --------------------------------------------------------------------------- sun / daylight

def daylight_window(cfg, day: dt.date):
    tz = ZoneInfo(cfg["tz"])
    loc = LocationInfo("home", "CZ", cfg["tz"], float(cfg["lat"]), float(cfg["lon"]))
    try:
        s = sun(loc.observer, date=day, tzinfo=tz)
        return s["sunrise"], s["sunset"]
    except Exception:
        # polární den/noc apod. – vrátíme celý den
        start = dt.datetime.combine(day, dt.time(0, 0), tzinfo=tz)
        return start, start + dt.timedelta(hours=24)


TWILIGHT_DEPRESSION = {"civil": 6, "nautical": 12, "astronomical": 18}


def watch_window(cfg, day: dt.date):
    """Od kdy do kdy má smysl se dívat: svítání–soumrak podle zvoleného typu (slunce X° pod obzorem),
    nebo východ/západ ± pevná rezerva v minutách."""
    ai = cfg["ai"]
    tz = ZoneInfo(cfg["tz"])
    sr, ss = daylight_window(cfg, day)
    mode = ai.get("twilight", "nautical")
    if mode in TWILIGHT_DEPRESSION:
        try:
            loc = LocationInfo("home", "CZ", cfg["tz"], float(cfg["lat"]), float(cfg["lon"]))
            s = sun(loc.observer, date=day, tzinfo=tz, dawn_dusk_depression=TWILIGHT_DEPRESSION[mode])
            return s["dawn"], s["dusk"]
        except Exception:
            # v létě u nautického/astronomického soumraku nemusí slunce klesnout dost hluboko – vezmi občanský, jinak ±90 min
            try:
                s = sun(loc.observer, date=day, tzinfo=tz, dawn_dusk_depression=6)
                return s["dawn"], s["dusk"]
            except Exception:
                return sr - dt.timedelta(minutes=90), ss + dt.timedelta(minutes=90)
    margin = dt.timedelta(minutes=int(ai.get("margin_min", 60)))
    return sr - margin, ss + margin


def is_daytime(cfg, now: dt.datetime) -> bool:
    if not cfg["ai"].get("day_only", True):
        return True
    dawn, dusk = watch_window(cfg, now.date())
    return dawn <= now <= dusk


def is_golden_hour(cfg, now: dt.datetime) -> bool:
    """Svítání a soumrak (od svítání do X min po východu, od X min před západem do soumraku) – červánky, rychlé změny."""
    sr, ss = daylight_window(cfg, now.date())
    dawn, dusk = watch_window(cfg, now.date())
    g = dt.timedelta(minutes=int(cfg["ai"].get("golden_min", 60)))
    return (min(dawn, sr - g) <= now <= sr + g) or (ss - g <= now <= max(dusk, ss + g))


def image_brightness(img: bytes) -> float:
    """Průměrný jas snímku 0–255 (zmenšený, rychlé)."""
    im = Image.open(io.BytesIO(img)).convert("L").resize((64, 36))
    return ImageStat.Stat(im).mean[0]


# --------------------------------------------------------------------------- scheduler

class AtmovioWatcher(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.last_check: dict[str, float] = {}
        self.last_dark: dict[str, float] = {}
        self.ai_failed: dict[str, int] = {}  # kamera → kolikrát po sobě AI selhala (rychlé opakování)
        self.last_notify: dict[str, float] = {}
        self.last_score: dict[str, int] = {}
        self.last_image: dict[str, Path] = {}
        self.check_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.running = True
        self.status = "start"
        self.outages: dict[str, dict] = {}
        self.web_error = ""
        self._last_watchdog = 0.0
        self.frigate_problem = ""  # popis chyby konfigurace Frigate (nouzový režim), '' = v pořádku
        self.vpn_problem = ""      # tunel zastaven pojistkou (odřízl by domácí síť)
        self._last_cleanup = 0.0

    def run(self):
        log("Atmovio smyčka spuštěna")
        while self.running:
            try:
                self.tick()
            except Exception as e:
                log(f"Chyba ve smyčce: {e}\n{traceback.format_exc()}")
            self.stop_event.wait(20)

    # ---- hlavní smyčka
    def tick(self):
        cfg = load_config()
        try:
            self.watchdog(cfg)
        except Exception as e:
            log(f"Hlídání výpadků selhalo: {e}")
        if time.time() - getattr(self, "_last_smart", 0) > 3600:
            self._last_smart = time.time()
            smart_record()
            try:
                cleanup_exports(cfg)
            except Exception as e:
                log(f"Úklid videí selhal: {e}")
        if time.time() - getattr(self, "_last_update_check", 0) > 1800 and (cfg.get("update") or {}).get("auto_check", True):
            self._last_update_check = time.time()
            try:
                last = update_state().get("checked") or ""
                if not last or (dt.datetime.now() - dt.datetime.fromisoformat(last)).total_seconds() > 86400 - 600:
                    check_for_update()
            except Exception as e:
                log(f"Kontrola aktualizací selhala: {e}")
        if not storage_ready():
            self.status = "HDD nedostupný – AI se snímky pozastavena, živý náhled zůstává dostupný"
            return
        try:
            process_auto_exports(cfg)
        except Exception as e:
            log(f"Automatická videa: {e}")
        if time.time() - getattr(self, "_last_export_check", 0) > 120:
            self._last_export_check = time.time()
            try:
                resume_killed_exports(cfg, frigate_status(cfg))
            except Exception as e:
                log(f"Kontrola rozdělaných videí: {e}")
        try:
            studio_auto(cfg)
            studio_kick()
            yt_kick()
        except Exception as e:
            log(f"Studio: {e}")
        self.cleanup(cfg)
        ai = cfg["ai"]
        if not ai["enabled"]:
            self.status = "AI vypnuto"
            return
        now = dt.datetime.now(ZoneInfo(cfg["tz"]))
        if not is_daytime(cfg, now):
            dawn, dusk = watch_window(cfg, now.date())
            nxt = dawn if now < dawn else watch_window(cfg, now.date() + dt.timedelta(days=1))[0]
            self.status = f"noc – čekám na svítání ({nxt.strftime('%H:%M')})"
            return
        used = self.calls_today(cfg, now)
        limit = int(ai.get("daily_limit", 0) or 0)
        if limit and used >= limit:
            self.status = f"denní limit {limit} dotazů vyčerpán ({now.strftime('%H:%M')}), pokračuji zítra"
            return
        golden = is_golden_hour(cfg, now)
        dark = [cam_label(cfg, c) for c in ai["cameras"] if c in self.last_dark]
        self.status = (f"běží{' – svítání/soumrak, rychlé kontroly' if golden and ai.get('fast_mode') else ''}, "
                       f"poslední tick {now.strftime('%H:%M:%S')}, dnes {used}/{limit or '∞'} dotazů"
                       + (f" · tma: {', '.join(dark)}" if dark else ""))
        for cam in ai["cameras"]:
            if not self.running:
                break
            fast = bool(ai.get("fast_mode")) and (golden or self.last_score.get(cam, 0) >= cam_rule(ai, cam)["threshold"] - 2)
            interval = int(ai["fast_interval_min"] if fast else ai["interval_min"]) * 60
            if 0 < self.ai_failed.get(cam, 0) <= 3:
                interval = min(interval, 120)  # AI právě selhala (přetížený poskytovatel) – zkusit znovu za 2 min, max. 3×
            if time.time() - self.last_check.get(cam, 0) < interval:
                continue
            self.last_check[cam] = time.time()
            self.check_camera(cfg, cam, now)

    def calls_today(self, cfg, now) -> int:
        try:
            with db() as con:
                row = con.execute("SELECT COALESCE(SUM(calls), 0) AS n FROM ai_stats WHERE day=?",
                                  (now.strftime("%Y-%m-%d"),)).fetchone()
            return int(row["n"])
        except Exception:
            return 0

    # ---- vyhodnocení jedné kamery
    def check_camera(self, cfg, cam, now, force=False) -> dict:
        if not storage_ready():
            return {"camera": cam, "error": "HDD není připravený. Ukládání snímků je pozastavené."}
        if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", cam):
            raise ValueError("Neplatný název kamery.")
        if not self.check_lock.acquire(blocking=False):
            return {"camera": cam, "error": "Právě probíhá jiné vyhodnocení; zkus to po jeho dokončení."}
        try:
            return self._check_camera(cfg, cam, now, force)
        finally:
            self.check_lock.release()

    def _check_camera(self, cfg, cam, now, force=False) -> dict:
        ai = cfg["ai"]
        result = {"camera": cam, "ts": now.isoformat(timespec="seconds")}
        day = now.strftime("%Y-%m-%d")
        img = fetch_snapshot(cfg, cam)
        if not img:
            ai_stat(day, cam, errors=1)
            self.record(result, error="Nepodařilo se získat snímek z kamery")
            return result

        # tma (noc, kamera přepnutá do IR bez oblohy): AI se neptá, snímek se neukládá – jen se počítá
        if ai.get("dark_skip", True) and not force:
            try:
                bright = image_brightness(img)
                if bright < float(ai.get("dark_level", 22)):
                    ai_stat(day, cam, skipped=1)
                    self.last_dark[cam] = bright
                    result.update(skipped=1, description=f"Tma: jas snímku {bright:.0f} < {ai.get('dark_level', 22)} – AI se neptá")
                    return result
                self.last_dark.pop(cam, None)
            except Exception as e:
                log(f"Měření jasu selhalo: {e}")
        # předfiltr – změna oproti poslednímu vyhodnocenému snímku; přeskočené snímky se neukládají (jen se počítají)
        if ai["prefilter"] and not force and cam in self.last_image and self.last_image[cam].exists():
            try:
                diff = image_diff(self.last_image[cam].read_bytes(), img)
                if diff < float(ai["prefilter_diff"]):
                    ai_stat(day, cam, skipped=1)
                    result.update(skipped=1, description=f"Předfiltr: změna {diff:.1f} < {ai['prefilter_diff']} – snímek se neposílá AI ani neukládá")
                    return result
            except Exception as e:
                log(f"Předfiltr selhal: {e}")
        day_dir = Path(cfg["snapshot_dir"]) / day
        day_dir.mkdir(parents=True, exist_ok=True)
        fname = f"{cam}_{now.strftime('%H%M%S')}_{secrets.token_hex(4)}.jpg"
        fpath = day_dir / fname
        fpath.write_bytes(img)
        result["image"] = str(fpath.relative_to(cfg["snapshot_dir"]))
        ai_stat(day, cam, calls=1)
        try:
            parsed, raw = ai_evaluate(ai, img)
        except Exception as e:
            ai_stat(day, cam, errors=1)
            self.ai_failed[cam] = self.ai_failed.get(cam, 0) + 1
            note = " · zkusím znovu za 2 min" if self.ai_failed[cam] <= 3 else ""
            self.record(result, error=f"AI: {e}", note=note.strip(" ·"))
            return result
        self.ai_failed.pop(cam, None)
        self.last_image[cam] = fpath
        parsed.setdefault("phenomena", [])
        result.update(parsed)
        result["raw"] = raw
        self.last_score[cam] = int(parsed["score"])
        rule = cam_rule(ai, cam)
        if int(parsed["score"]) >= rule["threshold"]:
            ai_stat(day, cam, interesting=1)

        notified = 0
        note = ""
        threshold = rule["threshold"]
        selected = set(rule["phenomena"])
        detected = list(parsed["phenomena"]) or (["jine"] if parsed["score"] >= threshold else [])
        hits = [p for p in detected if p in selected]
        # „Cokoli fotogenického“: upozornit i bez shody s vybranými jevy, když je záběr podle skóre výjimečný
        if not hits and rule.get("any") and parsed["score"] >= threshold:
            hits = ["jine"]
        if force:
            note = "ruční test – bez e-mailu"
        elif parsed["score"] >= threshold and hits:
            ts_now = now.timestamp()
            gap = int(ai.get("episode_gap_min", 120)) * 60
            cooldown = int(ai["cooldown_min"]) * 60
            seen = self.episode_seen(cam)
            fresh = [p for p in hits if ts_now - seen.get(p, 0) >= gap]
            self.episode_mark(cam, hits, ts_now)
            if cam not in self.last_notify:
                with db() as con:
                    last = con.execute("SELECT ts FROM evaluations WHERE camera=? AND notified=1 ORDER BY id DESC LIMIT 1", (cam,)).fetchone()
                self.last_notify[cam] = dt.datetime.fromisoformat(last["ts"]).timestamp() if last else 0
            if not fresh:
                note = "probíhající epizoda – e-mail už byl odeslán"
            elif ts_now - self.last_notify[cam] < cooldown:
                note = f"odstup e-mailů {ai['cooldown_min']} min – bez e-mailu"
            else:
                labels = ", ".join(phen_labels(ai).get(p, p) for p in fresh)
                # Nejdřív uložit (kvůli id pro odkaz na detail), potom odeslat.
                result["notified"] = 0
                result["note"] = "odesílám…"
                rid = self.record(result)
                urls = public_urls()
                link = f"{urls['atmovio']}/detection/{rid}" if urls["atmovio"] else ""
                try:
                    info = camera_info(cfg, cam)
                    title = cam_label(cfg, cam)
                    subject = f"[Atmovio] {title}: {labels} ({parsed['score']}/10)"
                    body = (
                        f"Kamera: {title} ({info['ip'] or '?'}, {info['via']})\nČas: {now.strftime('%d.%m.%Y %H:%M')}\n"
                        f"Skóre: {parsed['score']}/10\nJev: {labels}\n\n{parsed['description']}\n\n"
                        + (f"Snímek a navedení na video od–do: {link}\nPřehrávač záznamů: {urls['frigate']}\n\n" if link else "")
                        + f"Další e-mail o stejném jevu z této kamery přijde nejdřív za {int(ai.get('episode_gap_min', 120))} min.\n"
                    )
                    channels = deliver(cfg, subject, body, img, fname, kind="sky", camera=cam, score=parsed["score"],
                                       phenomena=fresh, ts=now, link=link)
                    notified = 1
                    note = f"odesláno: {channels}"
                    self.last_notify[cam] = ts_now
                    ai_stat(day, cam, notified=1)
                    add_event("sky", f"{title}: {labels} ({parsed['score']}/10)", parsed["description"], emailed=1)
                    ax = ai.get("auto_export") or {}
                    if ax.get("enabled") and cam in (ax.get("cameras") or []):
                        try:
                            schedule_auto_export(cfg, rid, cam, now, labels)
                            note += " · video se vytvoří automaticky"
                        except Exception as e:
                            log(f"[{cam}] Automatické video se nepodařilo naplánovat: {e}")
                    self.record_update(rid, notified=1, note=note)
                except Exception as e:
                    result["error"] = f"Upozornění: {e}"
                    self.record_update(rid, error=result["error"], note="")
                    log(f"[{cam}] {result['error']}")
                result["notified"] = notified
                result["note"] = note
                return result
        elif parsed["score"] >= threshold:
            note = "jev není mezi sledovanými – bez e-mailu"
        result["notified"] = notified
        result["note"] = note
        self.record(result)
        return result

    def episode_seen(self, cam) -> dict:
        with db() as con:
            return {r["phenomenon"]: float(r["last_seen"]) for r in con.execute("SELECT phenomenon, last_seen FROM episodes WHERE camera=?", (cam,))}

    def episode_mark(self, cam, phenomena, ts):
        with db() as con:
            con.executemany("INSERT INTO episodes (camera, phenomenon, last_seen) VALUES (?,?,?) "
                            "ON CONFLICT(camera, phenomenon) DO UPDATE SET last_seen=excluded.last_seen",
                            [(cam, p, ts) for p in phenomena])

    def record(self, r: dict, **extra) -> int:
        r.update(extra)
        with db() as con:
            cur = con.execute(
                "INSERT INTO evaluations (ts,camera,image,score,phenomenon,description,notified,skipped,error,raw,phenomena,note)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (r.get("ts"), r.get("camera"), r.get("image"), r.get("score"), r.get("phenomenon"),
                 r.get("description"), r.get("notified", 0), r.get("skipped", 0), r.get("error"), r.get("raw"),
                 ",".join(r.get("phenomena") or []), r.get("note")),
            )
            r["id"] = cur.lastrowid
        if r.get("error"):
            log(f"[{r.get('camera')}] {r['error']}")
        return int(r["id"])

    def record_update(self, rid: int, **fields):
        with db() as con:
            con.execute("UPDATE evaluations SET " + ", ".join(f"{k}=?" for k in fields) + " WHERE id=?", (*fields.values(), rid))

    # ---- hlídání výpadků kamer, Frigate a HDD
    def watchdog(self, cfg):
        if time.time() - self._last_watchdog < 60:
            return
        self._last_watchdog = time.time()
        al = cfg.get("alerts", {})
        fs = frigate_status(cfg)
        now = time.time()
        try:
            problem = frigate_safe_mode() if fs["online"] else ""
        except Exception:
            problem = ""
        if problem and not self.frigate_problem:
            log(f"Frigate: nouzový režim, NENAHRÁVÁ – {problem}")
            if frigate_fix_config(cfg):
                frigate_restart()
                problem += " (konfigurace automaticky opravena, Frigate se restartuje)"
            else:
                try:
                    deliver(cfg, "Nahrávání neběží – Frigate odmítl konfiguraci",
                            f"Frigate běží v nouzovém režimu a nenahrává.\nChyba: {problem}\nOtevři Atmovio → Systém → Opravit konfiguraci nahrávání.",
                            kind="system")
                except Exception as e:
                    log(f"Frigate: upozornění se nepodařilo odeslat: {e}")
        elif not problem and self.frigate_problem:
            log("Frigate: konfigurace v pořádku, nahrávání obnoveno")
        self.frigate_problem = problem
        # Pojistka: tunel WireGuard nesmí nikdy odříznout domácí síť (ani po restartu RPi).
        try:
            iface = cfg["vpn"]["iface"]
            if vpn_is_up(iface):
                broken = vpn_breaks_lan(iface)
                if broken:
                    run(["systemctl", "disable", "--now", f"wg-quick@{iface}"], timeout=60)
                    _camera_info_cache.clear()
                    self.vpn_problem = broken + " Tunel je vypnutý i pro start po restartu; oprav AllowedIPs v Síť a VPN."
                    log("VPN: " + self.vpn_problem)
        except Exception as e:
            log(f"VPN: kontrola tunelu selhala: {e}")
        if al.get("frigate", True):
            self.track_outage(cfg, "frigate", "Frigate (nahrávání)", fs["online"], now,
                              "Frigate neběží nebo neodpovídá – kamery se nenahrávají. Zkontroluj Atmovio → Systém.")
        if al.get("storage", True):
            mode = storage_status()["mode"]
            self.track_outage(cfg, "storage", "Disk pro záznamy (HDD)", mode in ("recording", "legacy"), now,
                              "HDD není připravený nebo neprošel kontrolou zápisu. Frigate běží jen v živém náhledu bez záznamu.")
        if al.get("camera_outage", True) and fs["online"]:
            for cam in frigate_cameras(cfg):
                s = fs["cameras"].get(cam) or {}
                up = bool(s.get("fps")) and float(s.get("fps") or 0) > 0
                info = camera_info(cfg, cam)
                self.track_outage(cfg, f"cam:{cam}", f"Kamera {cam_label(cfg, cam)}", up, now,
                                  f"Kamera {cam_label(cfg, cam)} ({info['ip'] or 'IP neznámá'}, {info['via']}) neposílá obraz. "
                                  f"Zkontroluj napájení, síť{' a VPN tunel' if 'VPN' in info['via'] else ''} kamery.")
        if web_ready(cfg):
            try:
                web_heartbeat(cfg, fs, self.status, self.outages)
                if getattr(self, "web_fail_logged", False):
                    log(f"Spojení s webem obnoveno (výpadek od {getattr(self, 'web_error_since', '?')}, {getattr(self, 'web_fail_n', 0)} min)")
                self.web_error = ""
                self.web_fail_n = 0
                self.web_fail_logged = False
            except Exception as e:
                # Hosting občas na minutu neodpoví (timeout, 502/503) – to se do logu nepíše. Zaloguje se až výpadek delší než 3 minuty.
                if not self.web_error:
                    self.web_error_since = dt.datetime.now().strftime("%H:%M")
                    self.web_fail_n = 0
                self.web_error = str(e)
                self.web_fail_n = getattr(self, "web_fail_n", 0) + 1
                if self.web_fail_n == 3 and not getattr(self, "web_fail_logged", False):
                    self.web_fail_logged = True
                    log(f"Heartbeat na web selhává už 3 minuty (od {self.web_error_since}): {e} – zkouším dál každou minutu, zaloguji obnovení")

    def track_outage(self, cfg, key, label, up, now, message):
        al = cfg.get("alerts", {})
        grace = int(al.get("outage_min", 5)) * 60
        repeat = int(al.get("repeat_h", 6)) * 3600
        st = self.outages.setdefault(key, {"down_since": None, "notified_at": None, "label": label})
        st["label"] = label
        if not up:
            if st["down_since"] is None:
                st["down_since"] = now
            elif now - st["down_since"] >= grace and (st["notified_at"] is None or now - st["notified_at"] >= repeat):
                duration = human_duration(now - st["down_since"])
                st["notified_at"] = now
                emailed = self.alert_mail(cfg, f"VÝPADEK: {label}", f"{message}\n\nBez signálu už {duration}.\n", "outage", key)
                add_event("outage", f"Výpadek: {label}", message, emailed)
            return
        if st["down_since"] is not None:
            if st["notified_at"] is not None:
                duration = human_duration(now - st["down_since"])
                emailed = 0
                if al.get("recovery", True):
                    emailed = self.alert_mail(cfg, f"OBNOVENO: {label}", f"{label} opět funguje. Výpadek trval {duration}.\n", "recovery", key)
                add_event("recovery", f"Obnoveno: {label}", f"Výpadek trval {duration}.", emailed)
            st["down_since"] = None
            st["notified_at"] = None

    def alert_mail(self, cfg, subject, body, kind="system", key="") -> int:
        if not email_ready(cfg) and not web_ready(cfg):
            return 0
        camera = key[4:] if key.startswith("cam:") else ""
        try:
            deliver(cfg, f"[Atmovio] {subject}", body, kind=kind, camera=camera)
            return 1
        except Exception as e:
            log(f"Upozornění se nepodařilo odeslat: {e}")
            return 0

    def outage_state(self) -> dict:
        """Pro dashboard: klíč → sekundy výpadku (None = běží)."""
        now = time.time()
        return {k: (now - v["down_since"] if v["down_since"] else None) for k, v in self.outages.items()}

    def cleanup(self, cfg):
        """Maže staré snímky a záznamy v DB (1× za hodinu)."""
        if time.time() - self._last_cleanup < 3600:
            return
        self._last_cleanup = time.time()
        keep = int(cfg["ai"].get("keep_days", 14))
        cutoff = dt.datetime.now(ZoneInfo(cfg["tz"])).date() - dt.timedelta(days=keep)
        base = Path(cfg["snapshot_dir"])
        if base.exists():
            for d in base.iterdir():
                try:
                    if not d.is_symlink() and d.is_dir() and dt.date.fromisoformat(d.name) < cutoff:
                        shutil.rmtree(d, ignore_errors=True)
                except ValueError:
                    pass
        with db() as con:
            con.execute("DELETE FROM evaluations WHERE ts < ?", (cutoff.isoformat(),))
            con.execute("DELETE FROM events WHERE ts < ?", (cutoff.isoformat(),))
            con.execute("DELETE FROM ai_stats WHERE day < ?", ((cutoff - dt.timedelta(days=366)).isoformat(),))
            con.execute("DELETE FROM auto_exports WHERE created < ?", (cutoff.isoformat(),))
        try:
            n = _delete_evaluations(cfg, "skipped=1", ())
            if n:
                log(f"Úklid: smazáno {n} přeskočených snímků (předfiltr) – nově se už neukládají.")
        except Exception as e:
            log(f"Úklid přeskočených snímků selhal: {e}")


def image_diff(a: bytes, b: bytes) -> float:
    """Průměrná absolutní odchylka (0–255) mezi dvěma zmenšenými snímky."""
    ia = Image.open(io.BytesIO(a)).convert("L").resize((64, 36))
    ib = Image.open(io.BytesIO(b)).convert("L").resize((64, 36))
    return ImageStat.Stat(ImageChops.difference(ia, ib)).mean[0]


watcher = AtmovioWatcher()


# --------------------------------------------------------------------------- vyhledávání kamer

RTSP_GUESSES = [
    ("Hikvision / HiLook / Annke", "/Streaming/Channels/101", "/Streaming/Channels/102"),
    ("Dahua / Imou / Amcrest", "/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"),
    ("Reolink", "/h264Preview_01_main", "/h264Preview_01_sub"),
    ("TP-Link Tapo / Vigi", "/stream1", "/stream2"),
    ("Xiaomi / Wyze (RTSP fw)", "/live", ""),
    ("Uniview", "/media/video1", "/media/video2"),
    ("Axis", "/axis-media/media.amp", ""),
    ("obecné", "/", ""),
]


def ws_discovery(timeout=3.0) -> dict:
    """ONVIF WS-Discovery: multicast Probe, vrátí {ip: {"xaddr":..., "name":..., "hw":...}}"""
    msg_id = f"urn:uuid:{uuid.uuid4()}"
    probe = f"""<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<e:Header><w:MessageID>{msg_id}</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
<w:Action a:mustUnderstand="true" xmlns:a="http://www.w3.org/2003/05/soap-envelope">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>
<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>"""
    found = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    try:
        sock.bind(("", 0))
        for _ in range(2):
            sock.sendto(probe.encode(), ("239.255.255.250", 3702))
            time.sleep(0.2)
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except Exception:
                break
            txt = data.decode("utf-8", "ignore")
            xaddrs = re.findall(r"<[^>]*XAddrs[^>]*>([^<]+)<", txt)
            scopes = " ".join(re.findall(r"<[^>]*Scopes[^>]*>([^<]+)<", txt))
            ip = addr[0]
            xaddr = ""
            for x in (xaddrs[0].split() if xaddrs else []):
                if ip in x:
                    xaddr = x
                    break
            if not xaddr and xaddrs:
                xaddr = xaddrs[0].split()[0]
            def scope(key):
                m = re.search(r"onvif://www\.onvif\.org/" + key + r"/([^\s]+)", scopes)
                return requests.utils.unquote(m.group(1)) if m else ""
            found[ip] = {"xaddr": xaddr, "name": scope("name"), "hw": scope("hardware")}
    finally:
        sock.close()
    return found


def port_scan(subnets: list, ports=(554, 80, 8000, 8080, 8554), timeout=0.4) -> dict:
    hosts = set()
    for sn in subnets:
        try:
            net = ipaddress.ip_network(sn, strict=False)
        except ValueError as e:
            raise ValueError(f"Neplatná síť: {sn}") from e
        if net.version != 4 or net.num_addresses > 1024:
            raise ValueError("Hledání podporuje IPv4 sítě nejvýše /22 (1024 adres).")
        hosts.update(str(h) for h in net.hosts())
        if len(hosts) > 1024:
            raise ValueError("Celkem lze prohledat nejvýše 1024 adres najednou.")
    result = {}

    def probe(ip_port):
        ip, port = ip_port
        try:
            with socket.create_connection((ip, port), timeout=timeout):
                return ip, port
        except Exception:
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=128) as ex:
        for r in ex.map(probe, [(h, pt) for h in hosts for pt in ports]):
            if r:
                result.setdefault(r[0], []).append(r[1])
    return result


def _onvif_security(user, password):
    nonce = os.urandom(16)
    created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + password.encode()).digest()).decode()
    return f"""<s:Header><wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
 xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken>
<wsse:Username>{escape(user)}</wsse:Username>
<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</wsse:Password>
<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{base64.b64encode(nonce).decode()}</wsse:Nonce>
<wsu:Created>{created}</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>"""


def _soap(url, body_xml, user="", password="", timeout=6):
    header = _onvif_security(user, password) if user else ""
    env = f"""<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">{header}<s:Body>{body_xml}</s:Body></s:Envelope>"""
    r = requests.post(url, data=env.encode(), headers={"Content-Type": "application/soap+xml; charset=utf-8"}, timeout=timeout)
    r.raise_for_status()
    return ET.fromstring(r.content)


def _findall_local(root, name):
    return [el for el in root.iter() if el.tag.split("}")[-1] == name]


def onvif_streams(ip: str, xaddr: str, user: str, password: str) -> dict:
    """Vrátí {"model":..., "streams":[{"name","uri","res"}], "error":...}"""
    out = {"model": "", "streams": [], "error": ""}
    dev_url = xaddr or f"http://{ip}/onvif/device_service"
    try:
        try:
            info = _soap(dev_url, '<tds:GetDeviceInformation xmlns:tds="http://www.onvif.org/ver10/device/wsdl"/>', user, password)
            mf = _findall_local(info, "Manufacturer"); md = _findall_local(info, "Model")
            out["model"] = " ".join(x.text or "" for x in (mf[:1] + md[:1])).strip()
        except Exception:
            pass
        media_url = ""
        try:
            svc = _soap(dev_url, '<tds:GetServices xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>', user, password)
            for service in _findall_local(svc, "Service"):
                ns = "".join(x.text or "" for x in _findall_local(service, "Namespace"))
                xa = "".join(x.text or "" for x in _findall_local(service, "XAddr"))
                if "media" in ns.lower() and "ver10" in ns and xa:
                    media_url = xa
                    break
                if "media" in ns.lower() and xa and not media_url:
                    media_url = xa
        except Exception:
            pass
        if not media_url:
            media_url = dev_url.replace("device_service", "media_service")
        # kamera může v XAddr vracet jinou IP (NAT) – vynuť tu, na kterou jsme se ptali
        media_url = re.sub(r"//[^/:]+", f"//{ip}", media_url, count=1)
        profiles = _soap(media_url, '<trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>', user, password)
        for prof in _findall_local(profiles, "Profiles"):
            token = prof.get("token", "")
            name = "".join(x.text or "" for x in _findall_local(prof, "Name")[:1])
            w = _findall_local(prof, "Width"); h = _findall_local(prof, "Height")
            res = f"{w[0].text}×{h[0].text}" if w and h else ""
            try:
                su = _soap(media_url, f"""<trt:GetStreamUri xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
<trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>
<trt:ProfileToken>{escape(token)}</trt:ProfileToken></trt:GetStreamUri>""", user, password)
                uri = "".join(x.text or "" for x in _findall_local(su, "Uri")[:1])
                if uri:
                    uri = re.sub(r"^rtsp://([^@/]*@)?[^/:]+", f"rtsp://{ip}", uri, count=1)
                    if user:
                        uri = uri.replace("rtsp://", f"rtsp://{requests.utils.quote(user, safe='')}:{requests.utils.quote(password, safe='')}@", 1)
                    out["streams"].append({"name": name or token, "uri": uri, "res": res})
            except Exception as e:
                out["error"] = f"GetStreamUri: {e}"
    except Exception as e:
        out["error"] = str(e)
    if out["streams"]:
        # Kamery přes ONVIF často nahlásí adresu bez videa nebo se špatným portem – každou ověř tak, jak ji uvidí Frigate.
        cfg = load_config()
        def check(st):
            fixed, info, _mode = find_working_stream(cfg, st["uri"])
            if not fixed:
                return None
            res = f"{info['w']}×{info['h']}" if info and info.get("w") else st["res"]
            return {**st, "uri": fixed, "res": f"{res} {info['codec'].upper()}".strip() if info else res}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            checked = list(pool.map(check, out["streams"]))
        dropped = len([c for c in checked if c is None])
        out["streams"] = [c for c in checked if c]
        if dropped and not out["streams"]:
            out["error"] = "Kamera přes ONVIF nabídla jen adresy bez videa. Zkus adresu zadat ručně (port 554) nebo v kameře zapni H.264 stream."
        elif dropped:
            out["error"] = f"{dropped}× profil bez videa vynechán."
        out["streams"].sort(key=lambda s: -int((s.get("res") or "0").split("×")[0] or 0) if "×" in (s.get("res") or "") else 0)
    return out


def local_subnet() -> str:
    try:
        _rc, out = run("ip -o -4 route show default", timeout=5)
        dev = out.split("dev")[1].split()[0]
        _rc, addr = run(["ip", "-o", "-4", "addr", "show", dev], timeout=5)
        cidr = addr.split("inet")[1].split()[0]
        return str(ipaddress.ip_network(cidr, strict=False))
    except Exception:
        return "192.168.1.0/24"


def discover_cameras(subnets: list, user: str, password: str) -> list:
    onvif = ws_discovery()
    ports = port_scan(subnets)
    ips = sorted(set(onvif) | set(ports), key=lambda x: ipaddress.ip_address(x))
    rows = []
    for ip in ips:
        o = onvif.get(ip, {})
        row = {"ip": ip, "onvif": bool(o), "name": o.get("name", ""), "hw": o.get("hw", ""),
               "ports": sorted(ports.get(ip, [])), "streams": [], "model": "", "error": ""}
        if o or 80 in row["ports"] or 8000 in row["ports"] or 8080 in row["ports"]:
            if user:
                res = onvif_streams(ip, o.get("xaddr", ""), user, password)
                row.update(streams=res["streams"], model=res["model"], error=res["error"])
        if 554 in row["ports"] or o:
            rows.append(row)
    return rows


# --------------------------------------------------------------------------- web app – šablony

# --------------------------------------------------------------------------- aktualizace Atmovio z GitHub Releases

_update_lock = threading.Lock()
_update_state: dict = {}


def version_tuple(v) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", str(v or "")))


def update_state() -> dict:
    """Poslední známý stav kontroly (v paměti + v souboru, aby přežil restart služby)."""
    global _update_state
    if not _update_state and UPDATE_STATE_FILE.exists():
        try:
            _update_state = json.loads(UPDATE_STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            _update_state = {}
    st = dict(_update_state)
    st["current"] = APP_VERSION
    st["available"] = bool(st.get("latest")) and version_tuple(st["latest"]) > version_tuple(APP_VERSION)
    return st


def _save_update_state(st: dict):
    global _update_state
    _update_state = st
    try:
        atomic_write(UPDATE_STATE_FILE, json.dumps(st, ensure_ascii=False, indent=1))
    except Exception as e:
        log(f"Aktualizace: stav se nepodařilo uložit: {e}")


def check_for_update() -> dict:
    """Zeptá se GitHubu na poslední vydání (jen dotaz, nic se neinstaluje). Chyba se uloží do state['error']."""
    keys = ("latest", "tag", "name", "url", "published", "notes", "script_url", "sums_url")
    prev = update_state()
    st = {"checked": dt.datetime.now().isoformat(timespec="seconds"), "error": ""}
    try:
        r = requests.get(f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest", timeout=15,
                         headers={"Accept": "application/vnd.github+json", "User-Agent": f"Atmovio/{APP_VERSION}"})
        if r.status_code == 404:
            st.update({k: "" for k in keys})   # repozitář zatím nemá žádné vydání
        else:
            r.raise_for_status()
            rel = r.json()
            assets = {a.get("name"): a.get("browser_download_url") for a in rel.get("assets") or []}
            st.update({
                "latest": str(rel.get("tag_name") or "").lstrip("vV"), "tag": rel.get("tag_name") or "",
                "name": rel.get("name") or "", "url": rel.get("html_url") or "", "published": (rel.get("published_at") or "")[:10],
                "notes": (rel.get("body") or "").replace("\r", "")[:6000],
                "script_url": assets.get("update-atmovio.sh") or "", "sums_url": assets.get("SHA256SUMS") or "",
            })
        if st.get("latest") and version_tuple(st["latest"]) > version_tuple(APP_VERSION) and prev.get("latest") != st["latest"]:
            log(f"K dispozici je nová verze Atmovio {st['latest']} (běží {APP_VERSION}) – Nastavení → Systém → Aktualizace")
    except Exception as e:
        st.update({k: prev.get(k, "") for k in keys})
        st["error"] = f"{type(e).__name__}: {e}"[:300]
    _save_update_state(st)
    return update_state()


def update_running() -> bool:
    _rc, out = run(["systemctl", "is-active", f"{UPDATE_UNIT}.service"], timeout=10)
    return out.strip() in ("active", "activating", "deactivating")


def update_log_tail(n: int = 80) -> str:
    try:
        lines = UPDATE_LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(lines[-n:])
    except Exception:
        return ""


def start_update() -> str:
    """Stáhne update-atmovio.sh z vydání, ověří SHA-256 a spustí ho jako samostatnou systemd jednotku
    (musí přežít zastavení atmovio.service, které aktualizátor sám provede). Vrací '' nebo text chyby."""
    with _update_lock:
        st = update_state()
        if not st.get("available"):
            return "Žádná nová verze není k dispozici."
        if not st.get("script_url") or not st.get("sums_url"):
            return "Vydání na GitHubu nemá přiložený update-atmovio.sh a SHA256SUMS – aktualizuj ručně přes SSH."
        if update_running():
            return "Aktualizace už běží."
        dl = APP_DIR / ".update-dl"
        shutil.rmtree(dl, ignore_errors=True)
        dl.mkdir(parents=True)
        script = dl / "update-atmovio.sh"
        try:
            hdr = {"User-Agent": f"Atmovio/{APP_VERSION}"}
            r = requests.get(st["script_url"], timeout=180, headers=hdr)
            r.raise_for_status()
            data = r.content
            r = requests.get(st["sums_url"], timeout=30, headers=hdr)
            r.raise_for_status()
            sums = {ln.split()[-1].lstrip("*"): ln.split()[0].lower() for ln in r.text.splitlines() if len(ln.split()) >= 2}
            expected = sums.get("update-atmovio.sh", "")
            if not expected or not secrets.compare_digest(expected, hashlib.sha256(data).hexdigest()):
                return "Kontrolní součet staženého skriptu nesouhlasí – aktualizace zastavena."
            if not data.startswith(b"#!/usr/bin/env bash") or b"SKY_DIR=/opt/nvr/atmovio" not in data[:2000]:
                return "Stažený soubor nevypadá jako aktualizační skript Atmovio."
            script.write_bytes(data)
            script.chmod(0o700)
        except Exception as e:
            return f"Stažení se nepovedlo: {e}"
        UPDATE_LOG_FILE.write_text(f"== {dt.datetime.now().isoformat(timespec='seconds')} aktualizace {APP_VERSION} → {st['latest']}\n",
                                   encoding="utf-8")
        run(["systemctl", "reset-failed", f"{UPDATE_UNIT}.service"], timeout=10)
        rc, out = run(["systemd-run", "--unit", UPDATE_UNIT, "--collect", "--quiet",
                       "-p", f"StandardOutput=append:{UPDATE_LOG_FILE}", "-p", f"StandardError=append:{UPDATE_LOG_FILE}",
                       "/bin/bash", str(script)], timeout=30)
        if rc != 0:
            return f"Aktualizaci se nepodařilo spustit: {out[-400:]}"
        log(f"Aktualizace {APP_VERSION} → {st['latest']} spuštěna z webu")
        return ""


# --------------------------------------------------------------------------- šablony

TEMPLATES = {}

LOGO_SVG = """<svg class="logo" viewBox="0 0 64 64" width="34" height="34" aria-hidden="true">
<defs>
<linearGradient id="at-sky" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#0b2a6f"/><stop offset="0.55" stop-color="#1e63d6"/><stop offset="1" stop-color="#38bdf8"/></linearGradient>
<linearGradient id="at-lens" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2f7de1"/><stop offset="1" stop-color="#0b2a6f"/></linearGradient>
<linearGradient id="at-wave" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#7dd3fc"/><stop offset="1" stop-color="#2b7fe0"/></linearGradient>
<clipPath id="at-clip"><circle cx="32" cy="32" r="30"/></clipPath>
</defs>
<circle cx="32" cy="32" r="30" fill="url(#at-sky)"/>
<g clip-path="url(#at-clip)">
<path d="M-2 40 C 14 22, 50 22, 66 40 L 66 70 L -2 70 Z" fill="#eaf5ff"/>
<path d="M2 47a7 7 0 0 1 8-6 8 8 0 0 1 15-1 6 6 0 0 1 7 7H2z" fill="#bfe4ff"/>
<path d="M36 46a6 6 0 0 1 8-5 8 8 0 0 1 14-1 6 6 0 0 1 8 6H36z" fill="#bfe4ff"/>
<path d="M-2 52 C 18 44, 46 44, 66 56 L 66 70 L -2 70 Z" fill="url(#at-wave)"/>
<path d="M-2 58 C 20 50, 44 52, 66 62 L 66 70 L -2 70 Z" fill="#1e63d6"/>
</g>
<path d="M46 12l1.2 3 3 1.2-3 1.2-1.2 3-1.2-3-3-1.2 3-1.2z" fill="#fff"/>
<circle cx="52" cy="20" r="1.4" fill="#fff"/><circle cx="55.5" cy="26" r="1" fill="#fff"/>
<circle cx="32" cy="34" r="11.5" fill="#0f172a"/>
<circle cx="32" cy="34" r="9.5" fill="url(#at-lens)"/>
<circle cx="32" cy="34" r="6" fill="#0b2a6f"/>
<circle cx="32" cy="34" r="3.2" fill="#1e3a8a"/>
<circle cx="28.5" cy="30.5" r="2.4" fill="#fff"/>
</svg>"""

BASE_CSS = ""  # vzhled je v static/atmovio.css (nad Pico CSS)

NAV_PRIMARY = [("/", "Přehled", "⌂"), ("/live", "Kamery", "📷"), ("/storage", "Záznamy", "💾"),
               ("/history", "Detekce a AI", "🖼"), ("/videos", "Videa", "🎬")]
NAV_SETTINGS = [("/cameras", "Kamery – přidání a úpravy", "🎥"), ("/ai", "AI hlídání oblohy", "☁"), ("/email", "Upozornění (e-mail, web)", "✉"),
                ("/studio/settings", "Video studio (zrychlení, intro, hudba)", "⏩"),
                ("/vpn", "Síť a VPN", "🔗"), ("/system", "Systém a disky", "⚙"), ("/logs", "Logy (diagnostika)", "📜")]
BOTTOM_LABELS = {"/": "Přehled", "/live": "Kamery", "/storage": "Záznamy", "/history": "Historie", "/videos": "Videa"}
NAV_ITEMS = NAV_PRIMARY + NAV_SETTINGS
NAV = [(h, n) for h, n, _ in NAV_ITEMS]
BOTTOM_NAV = ["/", "/live", "/history", "/videos"]

# Ikony (inline SVG, stroke = currentColor) pro dlaždice a hlavičku.
ICONS = {
    "camera": '<svg class="i" viewBox="0 0 24 24"><path d="M4 7h3l2-2h6l2 2h3v12H4z"/><circle cx="12" cy="13" r="3.5"/></svg>',
    "disk": '<svg class="i" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><circle cx="7" cy="7.5" r="1"/><circle cx="7" cy="16.5" r="1"/></svg>',
    "brain": '<svg class="i" viewBox="0 0 24 24"><path d="M9 4a3 3 0 0 0-3 3v1a3 3 0 0 0-2 3 3 3 0 0 0 2 3v1a3 3 0 0 0 3 3h1V4zM15 4a3 3 0 0 1 3 3v1a3 3 0 0 1 2 3 3 3 0 0 1-2 3v1a3 3 0 0 1-3 3h-1V4z"/><path d="M10 9h4M10 15h4"/></svg>',
    "bell": '<svg class="i" viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20a2 2 0 0 0 4 0"/></svg>',
    "sun": '<svg class="i" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
    "moon": '<svg class="i" viewBox="0 0 24 24"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>',
    "cpu": '<svg class="i" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/></svg>',
    "ram": '<svg class="i" viewBox="0 0 24 24"><rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 17v3M10 17v3M14 17v3M18 17v3M6 10v4M10 10v4M14 10v4M18 10v4"/></svg>',
    "clock": '<svg class="i" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    "temp": '<svg class="i" viewBox="0 0 24 24"><path d="M10 4a2 2 0 0 1 4 0v9.5a4 4 0 1 1-4 0z"/><path d="M12 9v6"/></svg>',
    "check": '<svg class="i" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="m8.5 12.5 2.5 2.5 4.5-5"/></svg>',
    "play": '<svg class="i" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>',
    "cog": '<svg class="i" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
    "plus": '<svg class="i" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    "menu": '<svg class="i" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    "ext": '<svg class="i" viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>',
    "cloud": '<svg class="i" viewBox="0 0 24 24"><path d="M7 18a4 4 0 0 1-.5-8 6 6 0 0 1 11.5 1.5A3.5 3.5 0 0 1 17.5 18z"/></svg>',
    "bolt": '<svg class="i" viewBox="0 0 24 24"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>',
    "video": '<svg class="i" viewBox="0 0 24 24"><rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3z"/></svg>',
    "image": '<svg class="i" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.5"/><path d="m21 16-5-5-8 8"/></svg>',
    "wifi": '<svg class="i" viewBox="0 0 24 24"><path d="M2 8.5a15 15 0 0 1 20 0M5.5 12a10 10 0 0 1 13 0M9 15.5a5 5 0 0 1 6 0"/><circle cx="12" cy="19" r="1"/></svg>',
}
NAV_ICONS = {"/": "sun", "/live": "camera", "/storage": "disk", "/history": "image", "/videos": "video",
             "/cameras": "camera", "/ai": "brain", "/email": "bell", "/vpn": "wifi", "/system": "cpu", "/logs": "clock", "/studio": "video"}

TEMPLATES["base.html"] = """<!doctype html>
<html lang="cs" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light"><meta name="theme-color" content="#0b1220">
<title>Atmovio – {{ title }}</title>
<link rel="icon" href="data:image/svg+xml,{{ favicon }}">
<script>try{var t=localStorage.getItem('atmovio-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>
<link rel="stylesheet" href="{{ pico_css }}">
<link rel="stylesheet" href="/static/atmovio.css?v={{ version }}">
<script defer src="/static/atmovio.js?v={{ version }}"></script>
<script defer src="{{ alpine_js }}"></script>
</head><body>
<div class="app" x-data='shell({flashes: {{ flashes|tojson }}})' @keydown.escape.window="menu=false;dd=''">
<header class="top"><div class="inner">
 <button type="button" class="ico-btn menu-btn" @click="menu=!menu" aria-label="Menu">""" + ICONS["menu"] + """</button>
 <a class="brand" href="/">""" + LOGO_SVG + """<span>Atmovio<small>NVR · kamery · AI</small></span></a>
 <nav class="menu" :class="{open: menu}">
  {% for href,name,ic in nav_primary %}<a class="{% if active==href %}active{% endif %}" href="{{ href }}">{{ name }}</a>{% endfor %}
  <div class="dd" :class="{open: dd==='set'}" @click.outside="if (dd==='set') dd=''"><button type="button" class="{% if settings_open %}active{% endif %}" @click="dd = dd==='set' ? '' : 'set'">Nastavení <span class="caret">▾</span></button>
   <div class="dd-panel" x-show="dd==='set'" x-cloak>
   {% for href,name,ic in nav_settings %}<a class="{% if active==href %}active{% endif %}" href="{{ href }}"><span class="ic">{{ ic }}</span>{{ name }}</a>{% endfor %}
   </div></div>
  <div class="dd" :class="{open: dd==='ext'}" @click.outside="if (dd==='ext') dd=''"><button type="button" @click="dd = dd==='ext' ? '' : 'ext'">Nástroje <span class="caret">▾</span></button>
   <div class="dd-panel" x-show="dd==='ext'" x-cloak>
   <a href="{{ frigate_ui }}" target="_blank" rel="noopener"><span class="ic">▶</span>Frigate – přehrávač a export videa ↗</a>
   <a href="{{ cockpit_ui }}" target="_blank" rel="noopener"><span class="ic">🖥</span>Cockpit – systém, síť, aktualizace ↗</a>
   <a href="{{ portainer_ui }}" target="_blank" rel="noopener"><span class="ic">📦</span>Portainer – kontejnery ↗</a>
   <hr><a href="https://www.atmovio.com/api/" target="_blank" rel="noopener"><span class="ic">🏠</span>API a Home Assistant ↗</a>
   <a href="https://github.com/{{ github_repo }}" target="_blank" rel="noopener"><span class="ic">🐙</span>GitHub – dokumentace ↗</a>
   </div></div>
 </nav>
 <div class="right">
  <div class="head-status">
   <a href="/live" title="Kamery"><span class="dot {{ 'err' if side.down else ('ok' if storage.mode in ['recording','legacy'] else 'warn') }}"></span>{% if side.down %}{{ side.down }} výpadek{% else %}{{ 'nahrává' if storage.mode in ['recording','legacy'] else 'jen náhled' }}{% endif %}</a>
   {% if side.ai_on %}<a href="/ai" title="AI hlídání oblohy"><span class="dot ok"></span>AI {{ side.ai_used }}{% if side.ai_limit %}/{{ side.ai_limit }}{% endif %}</a>{% endif %}
  </div>
  <a class="btn small ghost" href="/live/all" title="Živý náhled všech kamer">""" + ICONS["play"] + """<span>Živý náhled</span></a>
  <a class="btn small" href="/discover">""" + ICONS["plus"] + """<span>Přidat kameru</span></a>
  <button type="button" class="ico-btn" @click="toggleTheme()" :title="theme==='dark' ? 'Světlý režim' : 'Tmavý režim'" aria-label="Přepnout vzhled"><span x-show="theme==='dark'">""" + ICONS["sun"] + """</span><span x-show="theme!=='dark'" x-cloak>""" + ICONS["moon"] + """</span></button>
  <div class="dd" :class="{open: dd==='usr'}" @click.outside="if (dd==='usr') dd=''"><button type="button" class="ico-btn user" @click="dd = dd==='usr' ? '' : 'usr'" title="Účet">A{% if update_info and update_info.available %}<span class="n"></span>{% endif %}</button>
   <div class="dd-panel end" x-show="dd==='usr'" x-cloak>
   <div class="label">Atmovio {{ version }}</div>
   {% if update_info and update_info.available %}<a href="/system/update"><span class="ic">🆕</span>Aktualizace na {{ update_info.latest }}</a>{% endif %}
   <a href="/system"><span class="ic">⚙</span>Systém a disky</a>
   <a href="/logs"><span class="ic">📜</span>Logy</a>
   <hr><form method="post" action="/logout" data-nobusy><button type="submit" class="item"><span class="ic">⏻</span>Odhlásit</button></form>
   </div></div>
 </div>
</div></header>
<main class="page">
{% if storage.mode not in ['recording', 'legacy'] %}<div class="flash warn"><span>⚠️</span><div><b>Režim bez záznamu.</b> {{ storage.reason }} <a href="/storage">Nastavit disk pro záznamy</a> · <a href="{{ frigate_ui }}" target="_blank">Živý náhled kamer ↗</a></div></div>{% endif %}
{% if disk_warning[1] %}<div class="flash {{ disk_warning[0] }}"><span>💽</span><div><b>{% if disk_warning[0] == 'err' %}Disk selhává.{% else %}Disk hlásí vadné sektory – sleduji.{% endif %}</b> {{ disk_warning[1] }}. {% if disk_warning[0] == 'err' %}Zálohuj a disk vyměň.{% else %}Když počet zůstane stejný, není třeba nic dělat; když poroste, upozorním červeně.{% endif %} <a href="/system">Stav disků</a></div></div>{% endif %}
{% if vpn_problem %}<div class="flash err"><span>⛔</span><div><b>VPN tunel zastaven pojistkou.</b> {{ vpn_problem }} <a href="/vpn">Síť a VPN</a></div></div>{% endif %}
{% if frigate_problem %}<div class="flash err"><span>⛔</span><div><b>Nahrávání neběží – Frigate odmítl konfiguraci.</b> {{ frigate_problem }}
<form method="post" action="/system/ctl" style="display:inline;margin-left:8px"><button class="btn small" name="action" value="fix_frigate">Opravit konfiguraci a restartovat nahrávání</button></form></div></div>{% endif %}
{% if update_info and update_info.available and active in ['/', '/system'] and req_path != '/system/update' %}<div class="flash"><span>🆕</span><div><b>K dispozici je Atmovio {{ update_info.latest }}</b> (běží {{ version }}). <a href="/system/update">Co je nového a aktualizace</a></div></div>{% endif %}
{% block head %}<div class="page-head"><div><h1>{{ title }}</h1>{% if subtitle %}<p class="sub">{{ subtitle }}</p>{% endif %}</div>{% block actions %}{% endblock %}</div>{% endblock %}
{% block content %}{% endblock %}
</main>
<footer class="brand-foot"><div>© Atmovio {{ now_year }} · v{{ version }} · <span class="mut">NVR pro kamery a hlídání oblohy</span></div><div><a href="https://github.com/{{ github_repo }}" target="_blank" rel="noopener">GitHub</a><a href="https://www.atmovio.com/" target="_blank" rel="noopener">Dokumentace</a><a href="https://www.atmovio.com/donate/" target="_blank" rel="noopener">♥ Podpořit</a><span class="tag">Kamery, které vidí víc.</span></div></footer>
<div class="toasts"><template x-for="t in toasts" :key="t.id"><div class="toast" :class="t.kind"><span x-text="t.text"></span><button type="button" class="x" @click="dismiss(t.id)" aria-label="Zavřít">×</button></div></template></div>
<div class="lightbox" x-show="lb.open" x-cloak @click.self="lbClose()" role="dialog" aria-modal="true"><button type="button" class="close" @click="lbClose()" aria-label="Zavřít">×</button>
<button type="button" class="nav-btn prev" x-show="lb.items.length>1" @click="lbStep(-1)" aria-label="Předchozí">‹</button><button type="button" class="nav-btn next" x-show="lb.items.length>1" @click="lbStep(1)" aria-label="Další">›</button>
<figure><img :src="lb.src" alt=""><figcaption x-text="lb.caption"></figcaption></figure></div>
</div>
<div id="busy" hidden><div class="busy-box"><span class="spin"></span><div><b id="busy-text">Zpracovávám…</b><div class="hint" id="busy-hint">Stránka se sama obnoví, až bude hotovo.</div></div></div></div>
</body></html>"""

TEMPLATES["login.html"] = """<!doctype html><html lang="cs" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>Atmovio – přihlášení</title>
<link rel="icon" href="data:image/svg+xml,{{ favicon }}">
<link rel="stylesheet" href="{{ pico_css }}"><link rel="stylesheet" href="/static/atmovio.css?v={{ version }}">
<style>body{min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0b1220 radial-gradient(1200px 600px at 20% -10%,#1e3a5f 0%,transparent 60%)}
.login{background:var(--pico-card-background-color);padding:1.8rem 1.7rem;border-radius:1.1rem;width:min(380px,92vw);border:1px solid var(--pico-card-border-color);box-shadow:0 20px 60px rgba(0,0,0,.45)}
.login .brand{color:var(--pico-color);padding:0 0 .9rem;font-size:1.35rem;justify-content:center}.login .brand small{color:var(--pico-muted-color)}
.e{color:var(--sw-err);margin:.4rem 0;font-weight:600}</style></head>
<body><form class="login" method="post" action="/login"><div class="brand">""" + LOGO_SVG + """<span>Atmovio<small>NVR · hlídání oblohy</small></span></div>
{% if error %}<div class="e">{{ error }}</div>{% endif %}
<label>Heslo administrátora</label><input type="password" name="password" autofocus autocomplete="current-password"><button class="btn block" style="margin-top:.9rem">Přihlásit</button></form></body></html>"""

TEMPLATES["dashboard.html"] = """{% extends "base.html" %}{% block head %}{% endblock %}{% block content %}
<div x-data="autorefresh(60)"></div>
{% set rec = storage.mode in ['recording','legacy'] %}
{% set ns = namespace(online=0) %}{% for c in cameras %}{% set s = fs.cameras.get(c) %}{% if s and s.fps and not outages.get('cam:' ~ c) %}{% set ns.online = ns.online + 1 %}{% endif %}{% endfor %}
{% set ai_on = cfg.ai.enabled and cfg.ai.api_key %}

<section class="hero">
 <div class="grow"><h1>Přehled</h1><p class="sub">Kamery, nahrávání, AI detekce a hlídání oblohy na jednom místě.</p><div class="tag">Obloha má příběh…</div></div>
 <div class="pill"><div><div class="k">{{ now_dt|czdate }}</div><div class="big">{{ now_dt|cztime }}</div></div></div>
 <div class="pill"><div><div class="sun"><span class="tw"><small>svítání</small>{{ sun.dawn }}</span><span class="main"><small>🌅 východ</small>{{ sun.sunrise }}</span><span class="main"><small>🌇 západ</small>{{ sun.sunset }}</span><span class="tw"><small>soumrak</small>{{ sun.dusk }}</span></div><div class="hint" style="color:rgba(255,255,255,.6);font-size:.68rem;margin-top:.2rem;text-align:center">AI hlídá od svítání do soumraku</div></div></div>
 {% if golden %}<span class="badge warn">svítání/soumrak – rychlé kontroly</span>{% endif %}
</section>

<div class="tiles">
 <a class="tile {{ 'err' if down_count else ('ok' if cameras else 'warn') }}" href="/live"><span class="ico blue">{{ icons.camera|safe }}</span><div class="tx"><div class="k">Kamery</div><div class="v">{{ ns.online }} / {{ cameras|length }}</div><div class="d">{% if not cameras %}zatím žádné – přidat{% elif down_count %}{{ down_count }} {{ 'výpadek' if down_count == 1 else 'výpadky' }}{% elif not fs.online %}Frigate neodpovídá{% else %}v provozu{% endif %}</div>{% if cameras %}<div class="bar"><i class="{{ 'err' if down_count else 'ok' }}" style="width:{{ (ns.online * 100 / cameras|length)|int }}%"></i></div>{% endif %}</div><span class="arrow">›</span></a>
 <a class="tile {{ ('err' if disk.pct > 92 else ('warn' if disk.pct > 80 else 'ok')) if rec else 'warn' }}" href="/storage"><span class="ico sky">{{ icons.disk|safe }}</span><div class="tx"><div class="k">Úložiště</div><div class="v">{% if rec %}{{ disk.pct }} %{% else %}bez disku{% endif %}</div><div class="d">{% if rec %}volné {{ disk.free_h }} z {{ disk.total_h }} · {{ retain_days }} dní{% else %}připoj HDD a nastav ho v Záznamech{% endif %}</div>{% if rec %}<div class="bar"><i class="{{ 'err' if disk.pct > 92 else ('warn' if disk.pct > 80 else '') }}" style="width:{{ disk.pct }}%"></i></div>{% endif %}</div><span class="arrow">›</span></a>
 <a class="tile {{ 'ok' if ai_on else 'warn' }}" href="/history"><span class="ico green">{{ icons.brain|safe }}</span><div class="tx"><div class="k">AI detekce</div><div class="v">{% if ai_on %}{{ stats7[0].notified if stats7 else 0 }}{% else %}vypnuto{% endif %}</div><div class="d">{% if ai_on %}dnes · {{ ai_used }}{% if ai_limit %} z {{ ai_limit }}{% endif %} dotazů{% else %}nastav klíč v Nastavení → AI{% endif %}</div>{% if ai_on and ai_limit %}<div class="bar"><i style="width:{{ ai_pct }}%"></i></div>{% endif %}</div><span class="arrow">›</span></a>
 <a class="tile {{ 'err' if down_count else ('ok' if email_ok else 'warn') }}" href="/email"><span class="ico amber">{{ icons.bell|safe }}</span><div class="tx"><div class="k">Upozornění</div><div class="v">{% if down_count %}{{ down_count }} {{ 'výpadek' if down_count == 1 else 'výpadky' }}{% elif email_ok %}v pořádku{% else %}nenastaveno{% endif %}</div><div class="d">{% if events %}poslední událost {{ events[0].ts|cztime }}{% elif cfg.web.enabled and cfg.web.token %}webhook na {{ cfg.web.url|urlhost }}{% elif email_ok %}e-mail na {{ cfg.email.to }}{% else %}kam posílat zprávy{% endif %}</div></div><span class="arrow">›</span></a>
 {% set tnum = sysinfo.temp|replace(' °C','')|float(0) %}
 <a class="tile {{ 'err' if tnum > 75 else ('warn' if tnum > 65 else 'ok') }}" href="/system"><span class="ico {{ 'red' if tnum > 75 else 'violet' }}">{{ icons.temp|safe }}</span><div class="tx"><div class="k">Raspberry Pi{% if update_info and update_info.available %} <span class="badge warn">🆕 {{ update_info.latest }}</span>{% endif %}</div><div class="v">{{ sysinfo.temp }}</div><div class="d">{% if update_info and update_info.available %}k dispozici Atmovio {{ update_info.latest }} (běží {{ version }}){% else %}{% if not fs.online %}Frigate neběží{% elif rec %}nahrává · Frigate {{ fs.version }}{% else %}jen náhled{% endif %} · běží {{ sysinfo.uptime }}{% endif %}</div></div><span class="arrow">›</span></a>
</div>

{% set setup_cams = cameras|length > 0 %}{% set setup_web = email_ok %}{% set setup_ai = ai_on %}{% set setup_disk = rec %}
{% if not (setup_cams and setup_web and setup_ai and setup_disk) %}
<div class="card accent"><div class="section-head"><h2>Dokončit nastavení</h2><span class="hint">zbývá {{ [setup_cams, setup_disk, setup_web, setup_ai]|reject('eq', true)|list|length }} z 4 kroků</span></div>
<ol class="steps">
<li>{% if setup_cams %}<span class="badge ok">hotovo</span>{% endif %} <b>Přidat kamery</b> – <a href="/discover">nechat je vyhledat v síti</a> (stačí uživatel a heslo kamery).</li>
<li>{% if setup_disk %}<span class="badge ok">hotovo</span>{% endif %} <b>Disk pro záznamy</b> – <a href="/storage">připojit HDD a připravit ho</a> jedním kliknutím.</li>
<li>{% if setup_web %}<span class="badge ok">hotovo</span>{% endif %} <b>Kam posílat upozornění</b> – <a href="/email">propojit s webem</a> nebo nastavit e-mail.</li>
<li>{% if setup_ai %}<span class="badge ok">hotovo</span>{% endif %} <b>Zapnout hlídání oblohy</b> – <a href="/ai">vložit klíč od Google (zdarma) a zapnout</a>.</li>
</ol></div>
{% endif %}

<div class="card">
<div class="section-head"><h2>Kamery <span class="count">({{ ns.online }} z {{ cameras|length }})</span>{% if cameras %}{% if down_count %}<span class="badge err">{{ down_count }} {{ 'výpadek' if down_count == 1 else 'výpadky' }}</span>{% elif ns.online == cameras|length %}<span class="badge ok">všechny kamery v pořádku</span>{% else %}<span class="badge warn">{{ cameras|length - ns.online }} bez obrazu</span>{% endif %}{% endif %}</h2>
 <div style="display:flex;gap:.5rem;align-items:center;flex-wrap:wrap"><span class="seg"><span class="on">Vše <b>{{ cameras|length }}</b></span><span>Živé <b>{{ ns.online }}</b></span><span>Offline <b>{{ cameras|length - ns.online }}</b></span></span><a class="btn small sec" href="/live">{{ icons.play|safe }} Živý náhled</a><a class="btn small sec" href="/cameras">{{ icons.cog|safe }} Správa kamer</a></div></div>
<div class="cams">
{% for c in cameras %}{% set s = fs.cameras.get(c) %}{% set info = caminfo[c] %}{% set out = outages.get('cam:' ~ c) %}
<div class="cam"><a class="img" href="/camera/{{ c }}" title="Otevřít kameru"><img src="/live/{{ c }}.jpg?t={{ now_ts }}" alt="" loading="lazy" onerror="window.swImgFail?swImgFail(this):this.style.display='none'">
{% if out %}<span class="live"><span class="dot err"></span>VÝPADEK</span>{% elif s and s.fps %}<span class="live"><span class="dot ok"></span>ŽIVĚ</span><span class="fps" title="snímků/s náhledového streamu pro AI a náhled; záznam se ukládá v plné kvalitě kamery">{{ '%.0f'|format(s.fps) }} fps</span>{% else %}<span class="live"><span class="dot warn"></span>BEZ SIGNÁLU</span>{% endif %}</a>
<div class="body"><div class="name"><span>{{ cam(c) }}</span>{% if out %}<span class="badge err">{{ out }}</span>{% endif %}</div>
<div class="meta"><span>🖥 {{ info.ip or 'IP ?' }}</span><span>·</span><span>{{ info.via }}</span>{% if c in cfg.ai.cameras and cfg.ai.enabled %}<span class="badge info">AI hlídá</span>{% endif %}{% if cfg.ai.enabled and cfg.ai.auto_export.enabled and c in cfg.ai.auto_export.cameras %}<span class="badge ok" title="Po upozornění se automaticky vystřihne video">🎬 auto video</span>{% endif %}</div>
{% set le = last_eval.get(c) %}
{% if c in cfg.ai.cameras and cfg.ai.enabled %}<a class="ai-note{{ ' hit' if le and le.notified else '' }}" href="{% if le %}/detection/{{ le.id }}{% else %}/history?camera={{ c }}&show=all{% endif %}" title="Poslední hodnocení AI – kliknutím otevřeš detail">
{% if le %}<span class="sc {{ 'ok' if le.score >= rule(c).threshold else 'mut' }}">{{ le.score }}/10</span><span class="t"><b>{{ le.phenomenon or 'nic zvláštního' }}</b> <small>{{ le.ts|cztime }}{% if le.ts|czdate != now_dt|czdate %} {{ le.ts|czdate }}{% endif %}</small><span class="desc">{{ le.description or '–' }}</span></span>
{% else %}<span class="sc mut">AI</span><span class="t"><small>zatím žádné hodnocení – první proběhne za světla</small></span>{% endif %}</a>{% endif %}
<div class="acts"><a class="btn sec" href="/live/{{ c }}">{{ icons.play|safe }} Živý náhled</a><a class="btn sec" href="/camera/{{ c }}">{{ icons.cog|safe }} Nastavení</a></div></div></div>
{% endfor %}
<a class="cam add" href="/discover"><span class="plus">+</span><b>Přidat kameru</b><span class="hint">vyhledat v síti nebo zadat RTSP adresu</span></a>
</div></div>

<div class="card"><div class="section-head"><h2>Poslední upozornění na oblohu</h2><span class="hint">detekce, na které přišlo upozornění</span><a class="btn small sec" href="/history">Historie</a></div>
<div class="gallery">
{% for e in recent[:5] %}<div class="shot"><a href="/detection/{{ e.id }}"><img src="/snapshot/{{ e.image }}" alt="" loading="lazy"></a>
<div class="b"><div class="line"><span class="s">{{ e.score }}/10</span><span class="when">{{ e.ts|cztime }}</span><span class="hint">{{ e.ts|czdate }}</span>{% if e.exported %}<a class="badge info" href="/videos" title="Z této detekce je vystřižené video">🎬</a>{% endif %}</div><div><b>{{ e.phenomenon }}</b> <span class="hint">· {{ cam(e.camera) }}</span></div><div class="hint desc2">{{ e.description or '' }}</div></div></div>{% endfor %}
{% if not recent %}<div class="hint">Zatím nic. Až AI najde zajímavou oblohu (skóre ≥ {{ cfg.ai.threshold }}) a pošle upozornění, objeví se tady.</div>{% endif %}
</div></div>

<div class="grid-3">
<div class="card"><div class="section-head"><h2>Úložiště</h2><a class="btn small sec" href="/storage">Detail</a></div>
{% if rec %}
<div class="ai-today"><div class="ring {{ 'err' if disk.pct > 92 else ('warn' if disk.pct > 80 else '') }}" style="--p:{{ disk.pct }}"><span>{{ disk.pct }} %</span></div>
<div><div class="hint">Využito úložiště záznamů</div><div class="big" style="font-size:1.3rem">{{ disk.used_h }} <span class="hint">/ {{ disk.total_h }}</span></div><div class="hint">volné {{ disk.free_h }}</div></div></div>
<ul class="legend" style="margin-top:.8rem">
 <li><span class="sw"></span>Záznamy z kamer<b>{{ disk.used_h }}</b></li>
 <li><span class="sw" style="background:var(--pico-muted-border-color)"></span>Volné<b>{{ disk.free_h }}</b></li>
 <li><span class="sw" style="background:var(--c-amber)"></span>Uchovávání<b>{{ retain_days }} dní</b></li>
 <li><span class="sw" style="background:var(--c-green)"></span>Frigate<b>{% if fs.online %}{{ fs.version }}{% else %}neběží{% endif %}</b></li>
</ul>
{% else %}<p class="hint">Bez disku se nic neukládá. <a href="/storage">Připoj HDD a připrav ho</a> jedním kliknutím – kamery zatím jedou jen v živém náhledu.</p>{% endif %}
</div>

<div class="card"><div class="section-head"><h2>AI detekce (dnes)</h2><a class="btn small sec" href="/ai">Nastavení</a></div>
{% if ai_on %}
<div class="ai-today"><div class="ring" style="--p:{{ ai_pct }}"><span>{{ ai_pct }} %</span></div>
<div><div class="big" style="font-size:1.4rem">{{ ai_used }}{% if ai_limit %} <span class="hint">z {{ ai_limit }} dotazů</span>{% else %} <span class="hint">dotazů</span>{% endif %}</div><div class="hint">{{ watcher_status }}</div></div></div>
<ul class="legend" style="margin-top:.8rem">
 {% set t = stats7[0] if stats7 else {'calls': 0, 'interesting': 0, 'notified': 0, 'skipped': 0, 'errors': 0} %}
 <li><span class="sw" style="background:var(--c-amber)"></span>Zajímavá obloha<b>{{ t.interesting }}</b></li>
 <li><span class="sw" style="background:var(--c-green)"></span>Upozornění<b>{{ t.notified }}</b></li>
 <li><span class="sw" style="background:var(--pico-muted-border-color)"></span>Přeskočeno (beze změny)<b>{{ t.skipped }}</b></li>
 <li><span class="sw" style="background:var(--c-red)"></span>Chyby<b>{{ t.errors }}</b></li>
 <li><span class="sw" style="background:var(--c-violet)"></span>Práh · kontrola<b>{{ cfg.ai.threshold }}/10 · {{ cfg.ai.interval_min }} min</b></li>
</ul>
<details style="margin:.7rem 0 0"><summary>Posledních 7 dní</summary>
<div class="stats7"><table><thead><tr><th>Den</th><th>Dotazů</th><th>Zajímavé</th><th>Upoz.</th><th>Přesk.</th><th>Chyby</th></tr></thead><tbody>
{% for d in stats7 %}<tr{% if loop.first %} class="today"{% endif %}><td>{{ d.label }} <span class="hint">{{ d.dow }}</span></td><td><b>{{ d.calls }}</b></td><td>{{ d.interesting }}</td><td>{% if d.notified %}<span class="badge ok">{{ d.notified }}</span>{% else %}0{% endif %}</td><td class="hint">{{ d.skipped }}</td><td>{% if d.errors %}<span class="badge err">{{ d.errors }}</span>{% else %}0{% endif %}</td></tr>{% endfor %}
</tbody></table></div></details>
{% if pending_auto %}<div class="hint" style="margin-top:.5rem">🎬 Čeká na vytvoření: {% for j in pending_auto %}{{ j.name }} (v {{ j.due_h }}){% if not loop.last %} · {% endif %}{% endfor %}</div>{% endif %}
{% else %}<p class="hint">Hlídání oblohy je vypnuté. <a href="/ai">Vlož klíč od Google (zdarma) a zapni ho</a> – Atmovio pak sám hlásí červánky, bouřky, duhy a další jevy.</p>{% endif %}
</div>

<div class="card"><div class="section-head"><h2>Systém</h2><a class="btn small sec" href="/system">Detail</a></div>
<div class="kpi">
 <div class="item ic"><span class="ico blue">{{ icons.cpu|safe }}</span><div><div class="k">Zátěž</div><div class="v">{{ sysinfo.load.split(' ')[0] }}</div><div class="d">{{ sysinfo.load }}</div></div></div>
 <div class="item ic"><span class="ico violet">{{ icons.ram|safe }}</span><div><div class="k">RAM</div><div class="v" style="font-size:.95rem">{{ sysinfo.mem }}</div><div class="d">použito / celkem</div></div></div>
 <div class="item ic"><span class="ico sky">{{ icons.disk|safe }}</span><div><div class="k">Systémový disk</div><div class="v" style="font-size:.95rem">{{ sysinfo.rootfs.split(' (')[1].rstrip(')') if '(' in sysinfo.rootfs else sysinfo.rootfs }}</div><div class="d">{{ sysinfo.rootfs.split(' (')[0] }}</div></div></div>
 <div class="item ic"><span class="ico teal">{{ icons.clock|safe }}</span><div><div class="k">Uptime</div><div class="v" style="font-size:.95rem">{{ sysinfo.uptime }}</div><div class="d">{{ sysinfo.hostname }} · {{ sysinfo.ip.split(' ')[0] }}</div></div></div>
 <div class="item ic"><span class="ico {{ 'red' if not fs.online else 'green' }}">{{ icons.check|safe }}</span><div><div class="k">Služby</div><div class="v" style="font-size:.95rem">{% if fs.online and rec %}vše v pořádku{% elif fs.online %}jen náhled{% else %}Frigate neběží{% endif %}</div><div class="d">Frigate {{ fs.version if fs.online else '–' }} · Atmovio {{ version }}</div></div></div>
 <div class="item ic"><span class="ico {{ 'amber' if update_info and update_info.available else 'green' }}">{{ icons.bolt|safe }}</span><div><div class="k">Aktualizace</div><div class="v" style="font-size:.95rem">{% if update_info and update_info.available %}<a href="/system/update">verze {{ update_info.latest }} →</a>{% else %}aktuální{% endif %}</div><div class="d">{% if update_info and update_info.checked %}kontrola {{ update_info.checked|czdt }}{% else %}denní kontrola GitHubu{% endif %}</div></div></div>
 <div class="item ic"><span class="ico {{ 'red' if tnum > 75 else ('amber' if tnum > 65 else 'green') }}">{{ icons.temp|safe }}</span><div><div class="k">Teplota</div><div class="v">{{ sysinfo.temp }}</div><div class="d">{% if tnum > 75 %}vysoká{% elif tnum > 65 %}teplejší{% else %}v normě{% endif %}</div></div></div>
</div></div>
</div>

<details class="card" id="guide" data-keep><summary>Nápověda – kam chodit a co kde najdu</summary>
<div class="guide">
<div><b>Atmovio (tady)</b> je jediná administrace: kamery, disk, AI hlídání oblohy, upozornění, síť, systém. Když nic neměníš, nemusíš sem chodit. Když něco nefunguje, podívej se do <a href="/logs">Logů</a>.</div>
<div><b>Frigate</b> <a href="{{ frigate_ui }}" target="_blank" rel="noopener">{{ frigate_ui }} ↗</a> – přehrávání záznamů a <b>stažení videa od–do</b> (Review → Historie → Export). Uživatel <code>admin</code>, heslo stejné jako sem.</div>
<div><b>Vlastní web (webhook)</b>{% if cfg.web.enabled and cfg.web.token %} <span class="badge ok">propojeno – {{ cfg.web.url|urlhost }}</span>{% else %} <span class="badge mut">nepropojeno – volitelné, nastav v <a href="/email">Upozornění</a></span>{% endif %} – Atmovio umí posílat stav kamer a upozornění na libovolný web (ukázkový přijímač v PHP je v repozitáři). Web pak zprávy zobrazí nebo rozešle dál; RPi nemusí mít SMTP.</div>
<div><b>REST API a Home Assistant</b> – klíč vytvoříš v <a href="/system">Systému</a>; hotové YAML a PHP skripty jsou na <a href="https://www.atmovio.com/api/" target="_blank" rel="noopener">atmovio.com/api ↗</a>.</div>
<div><b>Cockpit</b> <a href="{{ cockpit_ui }}" target="_blank" rel="noopener">{{ cockpit_ui }} ↗</a> – servis systému (statická IP, aktualizace, disky). <b>Portainer</b> běžně nepotřebuješ.</div>
<div>Aktualizace Atmovio: v menu Nastavení → Systém, nebo přes SSH <code>sudo bash update-atmovio.sh</code>. Verze {{ version }}.</div>
</div></details>
{% endblock %}"""

TEMPLATES["cameras.html"] = """{% extends "base.html" %}{% block content %}
{% if not cams and not pre.main %}<div class="card" style="border-color:var(--ac)"><h2>Krok 1 · Najdi kamery v síti</h2>
<p>Nejjednodušší cesta: klikni na tlačítko, zadej <b>uživatele a heslo kamery</b> (stejné, jakým se přihlašuješ do kamery) a Atmovio kamery sám najde i s adresami videa. Pak jen potvrdíš název a klikneš <b>Přidat kameru</b>.</p>
<a class="btn" href="/discover">🔍 Vyhledat kamery v síti</a></div>{% endif %}
<div class="card"><div class="section-head"><h2 style="margin:0">Nastavené kamery</h2><a class="btn small" href="/discover">🔍 Vyhledat kamery v síti</a></div>
<div class="tw"><table><tr><th>Název</th><th>IP · cesta</th><th>Hlavní stream (záznam)</th><th>Substream (náhled)</th><th></th></tr>
{% for name,c in cams.items() %}<tr><td><a href="/camera/{{ name }}"><b>{{ cam(name) }}</b></a><div class="hint">ID ve Frigate: <code>{{ name }}</code></div></td><td class="hint">{{ c.ip or '?' }}<br>{{ c.via }}</td><td class="hint" style="word-break:break-all">{{ c.main }}</td><td class="hint" style="word-break:break-all">{{ c.sub or '–' }}</td>
<td style="white-space:nowrap"><a class="btn small" href="/cameras/edit/{{ name }}">Upravit</a> <a class="btn small sec" href="/camera/{{ name }}">Detail</a>
<form method="post" action="/cameras/delete" style="display:inline" onsubmit="return confirm('Odebrat kameru {{ cam(name) }} z konfigurace? Záznamy zůstanou na disku.')"><input type="hidden" name="name" value="{{ name }}"><button class="btn small danger">Odebrat</button></form></td></tr>{% endfor %}
{% if not cams %}<tr><td colspan="5" class="hint">Žádné kamery. Přidej první níže – nebo ji nech <a href="/discover">vyhledat v síti</a>.</td></tr>{% endif %}</table></div>
<p class="hint">Video se ukládá tak, jak ho kamera kóduje (H.264/H.265, bez překódování – CPU se nezatěžuje). Substream v nízkém rozlišení slouží jen pro náhled ve Frigate. Po každé změně se Frigate restartuje (cca 20–40 s). Masky, zóny a detekci objektů nastavíš ve <a href="{{ frigate_ui }}" target="_blank">Frigate ↗</a>.</p></div>

<details class="card" id="pridat" style="padding:0 18px" {% if pre.main %}open{% endif %}><summary>{% if pre.replace %}Upravit kameru „{{ pre.name }}“{% else %}Přidat kameru ručně (když ji hledání nenajde nebo znáš adresu videa){% endif %}</summary>
{% if pre.replace %}<div class="flash">Uprav název nebo adresy a klikni na <b>Uložit změny</b>. Adresy se před uložením znovu ověří; nastavení ve Frigate (masky, zóny) zůstane.</div>
{% elif pre.main %}<div class="flash">Formulář je předvyplněný z hledání – zkontroluj název a klikni na <b>Přidat kameru</b>.</div>{% endif %}
<form method="post" action="/cameras/add" style="padding-bottom:14px"><input type="hidden" name="replace" value="{{ pre.replace }}">
<div class="row"><div><label>Název kamery (libovolný, např. <code>Zahrada – západ</code>)</label><input type="text" name="name" required value="{{ pre.name }}"><div class="hint">Frigate potřebuje interní ID bez mezer a diakritiky – vytvoří se automaticky (např. <code>sehradice_zapad</code>), ty uvidíš všude svůj název.</div></div></div>
<div class="row"><div><label>Uživatel kamery</label><input type="text" name="user" value="{{ pre.user }}" placeholder="admin" autocomplete="off"></div>
<div><label>Heslo kamery</label><input type="password" name="password" value="{{ pre.password }}" autocomplete="off"></div></div>
<div class="hint">Přihlášení se doplní do adres streamů automaticky. Když už adresa přihlášení obsahuje (rtsp://uzivatel:heslo@…), pole můžeš nechat prázdná.</div>
<label>Adresa videa – hlavní stream (RTSP, plné rozlišení, tak se ukládá)</label>
<input type="text" name="main" required placeholder="rtsp://192.168.1.50:554/stream1" value="{{ pre.main }}">
<label>Adresa videa – vedlejší stream (nízké rozlišení pro náhled; doporučeno, ale není nutné)</label>
<input type="text" name="sub" placeholder="rtsp://192.168.1.50:554/stream2" value="{{ pre.sub }}">
<div class="hint">Adresy najdeš v návodu ke kameře nebo v jejím webovém rozhraní (hledej „RTSP“). Typické: Hikvision <code>/Streaming/Channels/101</code>, Dahua/Imou <code>/cam/realmonitor?channel=1&amp;subtype=0</code>, Reolink <code>/h264Preview_01_main</code>, Tapo <code>/stream1</code>.</div>
<label class="check"><input type="checkbox" name="test" checked> Před uložením ověřit, že kamera odpovídá (cca 10 s)</label>
{% if not pre.replace %}<label class="check"><input type="checkbox" name="atmovio" checked> Hlídat oblohu z této kamery pomocí AI</label>{% endif %}
<button class="btn">{% if pre.replace %}Uložit změny{% else %}Přidat kameru{% endif %}</button>
<p class="hint">Kamera za VPN: použij její adresu ve vzdálené síti (např. <code>rtsp://10.10.10.4:554/…</code>) a raději nižší bitrate. Dostupnost ověříš v <a href="/vpn">Síť a VPN</a>.</p></form></details>
{% endblock %}"""

TEMPLATES["discover.html"] = """{% extends "base.html" %}{% block content %}
<div class="card"><h2>Hledání kamer</h2>
<p>Zadej <b>uživatele a heslo kamery</b> (to, čím se přihlašuješ do kamery – bez nich kamera video nevydá) a klikni na <b>Hledat</b>. U nalezených kamer pak jen potvrdíš název a klikneš <b>Přidat kameru</b>.</p>
<form method="post" action="/discover">
<div class="row">
<div><label>Uživatel kamery</label><input type="text" name="user" value="{{ user }}" placeholder="admin" autocomplete="off"></div>
<div><label>Heslo kamery</label><input type="password" name="password" value="{{ password }}" autocomplete="off"></div>
<div><label>Kde hledat (síť; přes VPN přidej i vzdálenou, oddělené čárkou)</label><input type="text" name="subnets" value="{{ subnets }}" placeholder="192.168.1.0/24, 10.10.10.0/24"></div>
</div>
<button class="btn">🔍 Hledat (cca 10–30 s)</button> <a class="btn sec" href="/cameras">Zpět na kamery</a></form>
<p class="hint"><b>Uživatel a heslo kamery zadej i tady</b> – bez nich kamera stream nevydá (chyba 401). Hledá se přes ONVIF (multicast – jen v lokální síti RPi) a skenem portů 554/80/8000/8080/8554 v zadaných sítích (funguje i přes VPN, např. 10.10.10.0/24).
Se zadaným přihlášením se z ONVIF vytáhnou RTSP adresy streamů a každá se ověří tak, jak ji uvidí nahrávání (adresy bez videa se vynechají, špatný port se opraví); bez přihlášení se nabídnou typické adresy podle výrobce. Ověření trvá i minutu.</p></div>
{% if results is not none %}
<div class="card"><h2>Nalezená zařízení ({{ results|length }})</h2>
{% if not results %}<p class="hint">Nic nenalezeno. Zkontroluj, že kamery jsou ve stejné síti, mají zapnuté RTSP/ONVIF, případně zadej správný rozsah sítě.</p>{% endif %}
{% for r in results %}
<div class="card tight" style="background:var(--bg2)">
<div><b>{{ r.ip }}</b> {% if r.onvif %}<span class="badge ok">ONVIF</span>{% endif %} {% if 554 in r.ports %}<span class="badge ok">RTSP 554</span>{% endif %}
<span class="hint">{{ r.model or r.hw }} {{ r.name }} · porty {{ r.ports|join(', ') }}</span></div>
{% if r.error %}<div class="hint" style="color:var(--warn)">ONVIF: {{ r.error }}</div>{% endif %}
{% if r.streams %}
<div class="tw"><table><tr><th>Profil</th><th>Rozlišení</th><th>RTSP adresa</th><th></th></tr>
{% for st in r.streams %}<tr><td>{{ st.name }}</td><td>{{ st.res }}</td><td class="hint" style="word-break:break-all">{{ st.uri|mask_rtsp }}</td>
<td>{% if loop.index > 1 %}<form method="post" action="/cameras/prepare"><input type="hidden" name="name" value="{{ r.model or r.name or ('Kamera ' ~ r.ip) }}"><input type="hidden" name="user" value="{{ user }}"><input type="hidden" name="password" value="{{ password }}"><input type="hidden" name="main" value="{{ st.uri }}"><button class="btn small sec">Použít jako hlavní</button></form>{% endif %}</td></tr>{% endfor %}</table></div>
<form method="post" action="/cameras/add" class="row" style="align-items:end;margin-top:8px">
<input type="hidden" name="main" value="{{ r.streams[0].uri }}">{% if r.streams|length > 1 %}<input type="hidden" name="sub" value="{{ r.streams[1].uri }}">{% endif %}<input type="hidden" name="test" value="on">
<div style="flex:2"><label>Název kamery</label><input type="text" name="name" required value="{{ r.model or r.name or ('Kamera ' ~ r.ip) }}"></div>
<input type="hidden" name="user" value="{{ user }}"><input type="hidden" name="password" value="{{ password }}">
<div><label class="check" style="margin:0 0 8px"><input type="checkbox" name="atmovio" checked> hlídat oblohu (AI)</label></div>
<div><button class="btn">➕ Přidat kameru</button> <button class="btn small sec" formaction="/cameras/prepare" formnovalidate>Upravit před přidáním</button></div>
</form>
<div class="hint">Hlavní stream {{ r.streams[0].res }}{% if r.streams|length > 1 %} + substream {{ r.streams[1].res }} pro náhled{% endif %}. Přidání ověří spojení (ffprobe) a restartuje Frigate.</div>
{% else %}
<form method="post" action="/cameras/prepare" class="row" style="align-items:end">
<input type="hidden" name="name" value="{{ r.model or r.name or ('Kamera ' ~ r.ip) }}"><input type="hidden" name="user" value="{{ user }}"><input type="hidden" name="password" value="{{ password }}">
<div><label>Typ kamery (odhad RTSP cesty)</label><select name="guess" data-base="{{ rtsp_base(r.ip, user, password) }}" onchange="var o=this.options[this.selectedIndex];this.form.main.value=this.dataset.base+o.dataset.m;this.form.sub.value=o.dataset.s?this.dataset.base+o.dataset.s:'';">
<option value="">– vyber výrobce –</option>{% for g in guesses %}<option data-m="{{ g[1] }}" data-s="{{ g[2] }}">{{ g[0] }}</option>{% endfor %}</select></div>
<div><label>Hlavní stream</label><input type="text" name="main" value="{{ rtsp_base(r.ip, user, password) }}/"></div>
<div><label>Substream</label><input type="text" name="sub" value=""></div>
<div><button class="btn small">Předvyplnit formulář</button></div></form>
{% endif %}
</div>{% endfor %}</div>
{% endif %}
{% endblock %}"""

TEMPLATES["storage.html"] = """{% extends "base.html" %}{% block content %}
{% if not ready %}
<div class="card" style="border-color:var(--warn)"><h2>Disk pro záznamy není připojený</h2>
{% if not disks %}<p>Nenašel jsem žádný externí disk. Zapoj HDD/SSD do <b>modrého USB 3.0 portu</b> Raspberry Pi a tuto stránku obnov. U 2,5" disků bez vlastního napájení použij originální 27W zdroj.</p>
{% else %}<p>Našel jsem externí disk, ale ještě není připravený pro záznamy. Vyber ho níže – Atmovio ho připojí (nebo naformátuje a připojí) a nahrávání se pak zapne samo.</p>{% endif %}</div>
{% endif %}
<div class="card"><div class="section-head"><h2 style="margin:0">Disky</h2><a class="btn small sec" href="/storage">Obnovit</a></div>
{% if not disks %}<p class="hint">Žádný externí disk nenalezen (systémový disk se nezobrazuje).</p>{% endif %}
{% for d in disks %}
<div class="card tight" style="background:var(--bg2)">
<div><b>{{ d.dev }}</b> {{ d.model }} · {{ d.size_h }} {% if d.tran %}· {{ d.tran }}{% endif %}
{% if d.state == 'nvr' %}<span class="badge ok">disk pro záznamy</span>{% elif d.state == 'ready' %}<span class="badge warn">připravený, nepřipojený</span>{% elif d.state == 'foreign' %}<span class="badge warn">cizí formát</span>{% else %}<span class="badge warn">prázdný / bez formátu</span>{% endif %}</div>
{% if d.parts %}<div class="tw"><table><tr><th>Oddíl</th><th>Formát</th><th>Název</th><th>Velikost</th><th>Připojení</th></tr>
{% for p in d.parts %}<tr><td>{{ p.dev }}</td><td>{{ p.fstype or '–' }}</td><td>{{ p.label or '–' }}</td><td>{{ p.size_h }}</td><td>{{ p.mountpoint or 'nepřipojeno' }}</td></tr>{% endfor %}</table></div>
{% else %}<div class="hint">Disk nemá žádný oddíl ani souborový systém.</div>{% endif %}
{% if d.state == 'nvr' and d.usage %}
<div class="big" style="margin-top:8px">{{ d.usage.used_h }} <span class="hint">z {{ d.usage.total_h }}</span></div>
<div class="bar"><i class="{{ 'err' if d.usage.pct > 92 else ('warn' if d.usage.pct > 80 else '') }}" style="width:{{ d.usage.pct }}%"></i></div>
<div class="hint">{{ d.usage.pct }} % obsazeno · volné {{ d.usage.free_h }} · připojeno v /mnt/nvr</div>
{% elif d.state == 'ready' %}
<form method="post" action="/storage/disk" style="margin-top:8px"><input type="hidden" name="dev" value="{{ d.dev }}"><input type="hidden" name="action" value="mount">
<button class="btn" data-busy="Připojuji disk">Připojit jako disk pro záznamy</button> <span class="hint">Disk už má formát ext4 – data na něm zůstanou.</span></form>
{% else %}
<form method="post" action="/storage/disk" class="row" style="align-items:end;margin-top:8px" onsubmit="return confirm('Naformátovat {{ d.dev }}? Všechna data na něm budou nenávratně smazána.')"><input type="hidden" name="dev" value="{{ d.dev }}"><input type="hidden" name="action" value="format">
<div><label>Pro potvrzení napiš SMAZAT</label><input type="text" name="confirm" placeholder="SMAZAT" autocomplete="off" required></div>
<div><button class="btn danger" data-busy="Formátuji a připojuji disk">Naformátovat a použít pro záznamy</button></div>
<div class="hint" style="flex-basis:100%">Disk {{ d.dev }} ({{ d.size_h }}) se celý smaže{% if d.state == 'foreign' %} – je na něm {{ d.parts|map(attribute='fstype')|join(', ') }}{% endif %}, naformátuje na ext4 a připojí do /mnt/nvr. Trvá do minuty.</div></form>
{% endif %}
</div>
{% endfor %}
<p class="hint">Po připojení disku se nahrávání zapne samo do minuty (hlídač disku ho ověří třemi zápisy). Disk se nikdy neuspává. Když ho odpojíš, Atmovio přejde na živý náhled bez záznamu a po připojení zpět nahrávání obnoví.</p></div>
<div class="grid">
{% if ready %}<div class="card"><h2>Záznamy na disku</h2>
<div class="big">{{ disk.used_h }} <span class="hint">z {{ disk.total_h }}</span></div>
<div class="bar"><i class="{{ 'err' if disk.pct > 92 else ('warn' if disk.pct > 80 else '') }}" style="width:{{ disk.pct }}%"></i></div>
<div class="hint">{{ disk.path }} · volné {{ disk.free_h }}</div>
<div class="tw"><table style="margin-top:10px"><tr><th>Kamera</th><th>Velikost záznamů</th><th></th></tr>
{% for c,s in sizes.items() %}<tr><td>{{ cam(c) }}{% if not s.active %}<div class="hint">kamera už není nastavená – staré záznamy</div>{% endif %}</td><td>{{ s.size }}</td>
<td style="text-align:right"><form method="post" action="/storage/delete-camera" style="display:inline" onsubmit="return confirm('Smazat všechny záznamy kamery {{ cam(c) }} ({{ s.size }})? Nevratné.')"><input type="hidden" name="camera" value="{{ c }}"><button class="btn small {{ 'danger' if not s.active else 'sec' }}" data-busy="Mažu záznamy">Smazat vše</button></form></td></tr>{% endfor %}{% if not sizes %}<tr><td colspan="3" class="hint">Zatím žádné záznamy.</td></tr>{% endif %}</table></div>
<p class="hint">Vybraný časový úsek jedné kamery smažeš dole v „Smazat záznamy ručně“.</p></div>{% endif %}
<div class="card"><h2>Jak dlouho uchovávat záznamy</h2>
<form method="post" action="/storage/retain">
<label>Uchovávat záznamy (dní)</label><input type="number" name="days" min="1" max="60" value="{{ retain_days }}">
<p class="hint">Starší záznamy se mažou samy. Když by disku došlo místo, smažou se nejstarší dřív. Po uložení se nahrávání na chvíli (cca 30 s) restartuje.</p>
<button class="btn">Uložit</button></form></div>
</div>
<div class="card"><h2>Přehrát nebo stáhnout video</h2>
<p>Záznamy přehrává a stahuje přehrávač Frigate: <a class="btn small" href="{{ frigate_ui }}/review" target="_blank" rel="noopener">Otevřít přehrávač záznamů ↗</a> (uživatel <code>admin</code>, heslo najdeš v <a href="/system">Systému</a>). Tam: <b>Review</b> → <b>Historie</b> → vyber kameru a čas od–do → <b>Export</b>. Hotové video (MP4) je pak v záložce <b>Export</b>.</p></div>
<details><summary>Smazat záznamy ručně (běžně netřeba – mažou se samy)</summary>
<form method="post" action="/storage/delete" onsubmit="return confirm('Opravdu nevratně smazat vybrané záznamy?')">
<div class="row">
<div><label>Kamera</label><select name="camera"><option value="*">všechny kamery</option>{% for c in cameras %}<option value="{{ c }}">{{ cam(c) }}</option>{% endfor %}</select></div>
<div><label>Od (datum)</label><input type="date" name="from_date" required></div>
<div><label>Od (hodina)</label><input type="number" name="from_hour" min="0" max="23" value="0"></div>
<div><label>Do (datum)</label><input type="date" name="to_date" required></div>
<div><label>Do (hodina, včetně)</label><input type="number" name="to_hour" min="0" max="23" value="23"></div>
</div>
<button class="btn danger">Smazat</button>
<p class="hint">Smaže video vybrané kamery v zadaném rozmezí (kromě právě nahrávané hodiny). Časová osa v přehrávači se srovná do jednoho dne.</p></form></details>
{% endblock %}"""

TEMPLATES["ai.html"] = """{% extends "base.html" %}{% block head %}{% endblock %}{% block content %}
{% set thr_opts = [(4, '4 – i docela obyčejná obloha (hodně upozornění)'), (5, '5 – hezká obloha'), (6, '6 – hezká, spíš výraznější'), (7, '7 – výrazný jev (doporučeno)'), (8, '8 – opravdu výrazný'), (9, '9 – jen výjimečná podívaná')] %}
<div x-data="{tab: (location.hash || '#kdo').slice(1)}" x-init="$watch('tab', t => history.replaceState(null, '', '#' + t))">
<div class="page-head"><div><h1>AI hlídání oblohy</h1><p class="sub">Umělá inteligence se dívá do kamer a dá vědět, když je na obloze něco pěkného nebo nebezpečného.</p></div>
<div class="actions">{% if ai.enabled and (ai.api_key or ai.provider == 'ollama') %}<span class="badge ok">zapnuto · {{ ai.cameras|length }} {{ 'kamera' if ai.cameras|length == 1 else ('kamery' if ai.cameras|length < 5 else 'kamer') }} · dnes {{ used_today }} dotazů</span>{% else %}<span class="badge warn">vypnuto</span>{% endif %}</div></div>

<div class="tabs big">
 <button type="button" :class="{on: tab==='kdo'}" @click="tab='kdo'"><span class="n">1</span>Kdo hodnotí</button>
 <button type="button" :class="{on: tab==='kamery'}" @click="tab='kamery'"><span class="n">2</span>Kamery a jevy</button>
 <button type="button" :class="{on: tab==='kdy'}" @click="tab='kdy'"><span class="n">3</span>Kdy se dívat</button>
 <button type="button" :class="{on: tab==='video'}" @click="tab='video'"><span class="n">4</span>Video automaticky</button>
 <button type="button" :class="{on: tab==='test'}" @click="tab='test'"><span class="n">5</span>Vyzkoušet a statistika</button>
</div>

<form method="post" action="/ai" id="aiform"><input type="hidden" name="tab" :value="tab">
<!-- ===== 1 · kdo hodnotí ===== -->
<div x-show="tab==='kdo'">
<div class="card" x-data="{p: '{{ ai.provider }}'}"><div class="section-head"><h2>Kdo se na oblohu dívá</h2>{% if ai.api_key or ai.provider == 'ollama' %}<span class="badge ok">{{ provider_info[ai.provider].name }} · {{ ai.model or 'auto' }}</span>{% else %}<span class="badge warn">chybí klíč</span>{% endif %}</div>
<p class="hint">Snímek z kamery se pošle „vision“ modelu s otázkou, co je na obloze; ten vrátí skóre 0–10, jevy a popis. <b>Google Gemini je zdarma a stačí na start.</b> Placené Claude / OpenAI popisují přesněji za pár desítek korun měsíčně.</p>
<div class="prov">
{% for pid, pi in provider_info.items() %}
<label class="prov-card" :class="{on: p==='{{ pid }}'}"><input type="radio" name="provider" value="{{ pid }}" x-model="p">
<div class="ph"><b>{{ pi.name }}</b><span class="badge {{ 'ok' if pi.kind == 'free' else ('info' if pi.kind == 'local' else 'warn') }}">{{ pi.tag }}</span></div>
<div class="pr"><span>💰</span><span>{{ pi.price }}</span></div>
<div class="pr"><span>📊</span><span>{{ pi.limits }}</span></div>
<div class="pr"><span>🎯</span><span>{{ pi.quality }}</span></div>
</label>
{% endfor %}
</div>
{% for pid, pi in provider_info.items() %}
<div x-show="p==='{{ pid }}'" {% if ai.provider != pid %}x-cloak{% endif %}>
{% if pid != 'ollama' %}
<ol class="steps" style="margin-top:.8rem"><li>Otevři <a href="{{ pi.key_url }}" target="_blank" rel="noopener">{{ pi.key_url|replace('https://','') }}</a>{% if pid == 'gemini' %} a přihlas se Google účtem{% endif %}.</li><li>Klikni na <b>{{ pi.key_label }}</b> a klíč zkopíruj{% if pi.kind == 'paid' %} (nejdřív dobij kredit, obvykle 5 USD){% endif %}.</li><li>Vlož ho níže a klikni na <b>Uložit a ověřit klíč</b>.{% if pi.usage_url %} Spotřebu vidíš na <a href="{{ pi.usage_url }}" target="_blank" rel="noopener">{{ pi.usage_url|replace('https://','') }}</a>.{% endif %}</li></ol>
{% else %}
<p class="hint" style="margin-top:.8rem">Ollama musí běžet na Pi (<a href="{{ pi.key_url }}" target="_blank" rel="noopener">ollama.com</a>) a model musí být stažený: <code>ollama pull {{ pi.models[0][0] }}</code>. Klíč není potřeba.</p>
{% endif %}
<label>Doporučené modely</label><select onchange="if(this.value){document.getElementById('model').value=this.value}"><option value="">– vybrat –</option>{% for m, note in pi.models %}<option value="{{ m }}" {% if ai.provider==pid and ai.model==m %}selected{% endif %}>{{ m }} – {{ note }}</option>{% endfor %}</select>
</div>
{% endfor %}
<div class="row" style="align-items:end">
<div style="flex:2" x-show="p!=='ollama'"><label>API klíč</label><input type="password" name="api_key" value="{{ ai.api_key }}" autocomplete="off" placeholder="vlož zkopírovaný klíč"></div>
<div><label>Název modelu <span class="hint">(lze přepsat ručně)</span></label><input type="text" name="model" id="model" value="{{ ai.model }}" placeholder="auto"></div>
</div>
<div x-show="p==='openai_compat'" {% if ai.provider != 'openai_compat' %}x-cloak{% endif %}><label>Adresa API (base URL)</label><input type="text" name="base_url" value="{{ ai.base_url }}" placeholder="https://api.groq.com/openai/v1"><div class="hint">Groq: https://api.groq.com/openai/v1 · OpenRouter: https://openrouter.ai/api/v1</div></div>
<div x-show="p==='ollama'" {% if ai.provider != 'ollama' %}x-cloak{% endif %}><label>Ollama URL</label><input type="text" name="ollama_url" value="{{ ai.ollama_url }}"></div>
<div style="display:flex;gap:.5rem;flex-wrap:wrap;align-items:center;margin-top:.6rem"><button class="btn sec" formaction="/ai/check" formnovalidate>Uložit a ověřit klíč</button><span class="hint">Pošle jeden testovací dotaz – u placených stojí zlomek haléře.</span></div>
{% if check %}<pre style="margin-top:10px">{{ check }}</pre>{% endif %}
<p class="hint" style="margin-top:.6rem">Snímky odcházejí jen k vybranému poskytovateli, záznamy z kamer nikdy.</p>
</div>
</div>

<!-- ===== 2 · kamery a jevy ===== -->
<div x-show="tab==='kamery'" x-cloak>
<div class="card"><label class="check" style="margin:0;font-size:1.05rem"><input type="checkbox" name="enabled" {% if ai.enabled %}checked{% endif %}> <b>Hlídání oblohy zapnuto</b></label>
<p class="hint" style="margin:.4rem 0 0">U každé kamery zapneš hlídání a řekneš, <b>od jakého skóre</b> a <b>na které jevy</b> chceš upozornit. AI hodnotí oblohu 0–10 (0–3 nudná, 4–6 hezká, 7–8 výrazný jev, 9–10 výjimečná). Kamera s hezkým výhledem si vystačí s prahem 7, horší kamera nebo kamera na sever klidně 5.</p></div>

<div class="card"><div class="section-head"><h2>Výchozí nastavení</h2><span class="hint">platí pro každou kameru, která nemá vlastní</span></div>
<label>Upozornit, když je obloha aspoň…</label><select name="threshold">{% for v, t in thr_opts %}<option value="{{ v }}" {% if ai.threshold == v %}selected{% endif %}>{{ t }}</option>{% endfor %}</select>
<label class="check any"><input type="checkbox" name="any_photo" {% if ai.get('any_photogenic', True) %}checked{% endif %}> <b>Cokoli fotogenického</b> <span class="hint">– upozornit i tehdy, když nejde o žádný z vybraných jevů, ale záběr vypadá výjimečně (skóre dosáhne prahu)</span></label>
<label>…a navíc tyto konkrétní jevy</label>
<div class="chips">{% for pid, label, desc in phenomena %}<label class="chip" title="{{ desc }}"><input type="checkbox" name="ph_{{ pid }}" {% if pid in ai.phenomena %}checked{% endif %}> {{ label }}</label>{% endfor %}</div>
<div class="hint">Nezaškrtnuté jevy AI pořád vidí a zapíše do historie, jen na ně nepřijde upozornění. Vlastní jev přidáš níže.</div>
</div>

<div class="cam-rules">
{% for c in cameras %}{% set r = cam_rules.get(c) or {} %}
<div class="card cam-rule" x-data="{on: {{ 'true' if c in ai.cameras else 'false' }}, mode: '{{ 'custom' if r.custom else 'default' }}'}" :class="{off: !on}">
 <div class="section-head"><h2>📷 {{ cam(c) }}</h2><label class="check" style="margin:0"><input type="checkbox" name="cam_{{ c }}" x-model="on"> <span x-text="on ? 'AI hlídá' : 'nehlídá se'"></span></label></div>
 <div x-show="on">
 <div class="seg" style="margin:.2rem 0 .6rem"><label class="{{ 'on' if not r.custom }}" :class="{on: mode==='default'}"><input type="radio" name="mode_{{ c }}" value="default" x-model="mode" hidden>Použít výchozí nastavení</label><label :class="{on: mode==='custom'}"><input type="radio" name="mode_{{ c }}" value="custom" x-model="mode" hidden>Vlastní práh a jevy</label></div>
 <div x-show="mode==='default'" class="hint">Upozorní od skóre <b>{{ ai.threshold }}</b>{% if ai.get('any_photogenic', True) %} na cokoli fotogenického a{% else %} na{% endif %} výchozí jevy ({{ ai.phenomena|length }} z {{ phenomena|length }}).</div>
 <div x-show="mode==='custom'" x-cloak>
  <label>Upozornit, když je obloha aspoň…</label><select name="thr_{{ c }}">{% for v, t in thr_opts %}<option value="{{ v }}" {% if (r.threshold or ai.threshold) == v %}selected{% endif %}>{{ t }}</option>{% endfor %}</select>
  <label class="check any"><input type="checkbox" name="cany_{{ c }}" {% if r.get('any', ai.get('any_photogenic', True)) %}checked{% endif %}> <b>Cokoli fotogenického</b> <span class="hint">– i bez shody s jevy, když je záběr výjimečný</span></label>
  <label>…a navíc tyto konkrétní jevy</label>
  <div class="chips">{% for pid, label, desc in phenomena %}<label class="chip" title="{{ desc }}"><input type="checkbox" name="cph_{{ c }}_{{ pid }}" {% if pid in (r.phenomena or ai.phenomena) %}checked{% endif %}> {{ label }}</label>{% endfor %}</div>
 </div>
 <label class="check" style="margin-top:.6rem"><input type="checkbox" name="ax_cam_{{ c }}" {% if c in ai.auto_export.cameras %}checked{% endif %}> 🎬 Po upozornění automaticky vystřihnout video <span class="hint">(délku nastavíš v záložce Video)</span></label>
 </div>
</div>
{% endfor %}
{% if not cameras %}<div class="card"><p class="hint" style="margin:0">Nejprve <a href="/cameras">přidej kamery</a>.</p></div>{% endif %}
</div>
</div>

<!-- ===== 3 · kdy se dívat ===== -->
<div x-show="tab==='kdy'" x-cloak>
<div class="card"><h2>Jak často</h2>
<div class="row">
<div><label>Běžně každých (minut)</label><input type="number" name="interval_min" min="1" max="1440" value="{{ ai.interval_min }}"></div>
<div><label>Kolem východu/západu každých (minut)</label><input type="number" name="fast_interval_min" min="1" max="60" value="{{ ai.fast_interval_min }}"><div class="hint">Červánky trvají krátce – tady se dívá častěji.</div></div>
<div><label>Nejvíc dotazů na AI za den</label><input type="number" name="daily_limit" min="0" max="100000" value="{{ ai.daily_limit }}"><div class="hint">Dnes použito <b>{{ used_today }}</b>. Hlídá bezplatný limit poskytovatele.</div></div>
</div>
<label class="check"><input type="checkbox" name="fast_mode" {% if ai.fast_mode %}checked{% endif %}> Kolem východu/západu a po zajímavém snímku se dívat častěji</label>
<label class="check"><input type="checkbox" name="prefilter" {% if ai.prefilter %}checked{% endif %}> Neptat se AI, když se obraz skoro nezměnil (šetří limit)</label>
<div class="hint">Odhad: asi <b>{{ estimate }}</b> dotazů denně (méně, když se obraz nemění nebo je tma).</div>
</div>
<div class="card"><h2>Kdy je světlo</h2>
<label class="check"><input type="checkbox" name="day_only" {% if ai.day_only %}checked{% endif %}> Dívat se jen od svítání do soumraku (v noci nemá smysl)</label>
<div class="row">
<div><label>Co je „světlo“</label><select name="twilight">
<option value="civil" {% if ai.twilight == 'civil' %}selected{% endif %}>občanský soumrak – cca 35 min před východem / po západu</option>
<option value="nautical" {% if ai.twilight == 'nautical' %}selected{% endif %}>nautický soumrak – cca 75 min (doporučeno, červánky)</option>
<option value="astronomical" {% if ai.twilight == 'astronomical' %}selected{% endif %}>astronomický soumrak – cca 2 h (v létě skoro celá noc)</option>
<option value="minutes" {% if ai.twilight == 'minutes' %}selected{% endif %}>pevně: východ/západ ± rezerva v minutách (níže)</option></select></div>
<div><label class="check" style="margin:1.9rem 0 .3rem"><input type="checkbox" name="dark_skip" {% if ai.dark_skip %}checked{% endif %}> Tmavý snímek AI neposílat</label><div class="hint">V noci nebo v infra režimu kamery se snímek jen změří a přeskočí.</div></div>
</div>
<div class="hint">Dnes: svítání {{ sun.dawn }} · východ {{ sun.sunrise }} · západ {{ sun.sunset }} · soumrak {{ sun.dusk }} → hlídá se {{ sun.dawn }}–{{ sun.dusk }}.</div>
<details><summary>Pokročilé (poloha, prahy, odstupy, pokyny pro AI)</summary>
<div class="row"><div><label>Zeměpisná šířka</label><input type="text" name="lat" value="{{ cfg.lat }}"></div><div><label>Zeměpisná délka</label><input type="text" name="lon" value="{{ cfg.lon }}"></div></div>
<div class="hint">Jen pro výpočet svítání/soumraku – stačí na desetiny stupně.</div>
<div class="row">
<div><label>Zlatá hodina – minut kolem východu/západu</label><input type="number" name="golden_min" min="0" max="180" value="{{ ai.golden_min }}"></div>
<div><label>Rezerva před východem / po západu (min, volba „pevně“)</label><input type="number" name="margin_min" min="0" max="240" value="{{ ai.margin_min }}"></div>
<div><label>Práh tmy (jas 0–255)</label><input type="number" name="dark_level" min="0" max="120" value="{{ ai.dark_level }}"><div class="hint">Výchozí 22; když přeskakuje moc brzo za šera, sniž na 12–15.</div></div>
</div>
<div class="row">
<div><label>Stejný jev znovu hlásit nejdřív za (minut)</label><input type="number" name="episode_gap_min" min="5" max="1440" value="{{ ai.episode_gap_min }}"><div class="hint">Červánky trvající 40 minut = jedno upozornění, ne deset.</div></div>
<div><label>Minimální odstup upozornění z jedné kamery (minut)</label><input type="number" name="cooldown_min" min="0" max="1440" value="{{ ai.cooldown_min }}"></div>
<div><label>Citlivost na změnu obrazu (0–255, menší = citlivější)</label><input type="text" name="prefilter_diff" value="{{ ai.prefilter_diff }}"></div>
<div><label>Uchovávat snímky a historii (dní)</label><input type="number" name="keep_days" min="1" max="365" value="{{ ai.keep_days }}"></div>
</div>
<label>Doplňující pokyny pro AI (volitelné)</label><textarea name="prompt_extra" placeholder="např. Kamera míří na západ, v dolní části je střecha – ignoruj ji.">{{ ai.prompt_extra }}</textarea>
</details>
</div>
</div>

<!-- ===== 4 · video ===== -->
<div x-show="tab==='video'" x-cloak>
<div class="card"><div class="section-head"><h2>Video automaticky</h2>{% if ai.auto_export.enabled and ai.auto_export.cameras %}<span class="badge ok">zapnuto · {{ ai.auto_export.cameras|length }} {{ 'kamera' if ai.auto_export.cameras|length == 1 else ('kamery' if ai.auto_export.cameras|length < 5 else 'kamer') }}</span>{% else %}<span class="badge mut">vypnuto</span>{% endif %}</div>
<p>Když přijde upozornění, Atmovio vystřihne video kolem snímku samo – najdeš ho ve <a href="/videos">Videích</a> a nemusíš se bát, že se záznam mezitím smaže. Které kamery to dělají, zaškrtneš u kamer v záložce <a href="#kamery" @click.prevent="tab='kamery'">Kamery a jevy</a>.</p>
<label class="check"><input type="checkbox" name="ax_enabled" {% if ai.auto_export.enabled %}checked{% endif %}> Automatické video zapnuto</label>
<div class="row">
<div><label>Minut před snímkem</label><input type="number" name="ax_before" min="0" max="60" value="{{ ai.auto_export.before_min }}"></div>
<div><label>Minut po snímku</label><input type="number" name="ax_after" min="0" max="60" value="{{ ai.auto_export.after_min }}"><div class="hint">Video vznikne, až tahle doba uplyne.</div></div>
<div><label>Rychlost videa</label><select name="ax_playback"><option value="realtime" {% if ai.auto_export.playback != 'timelapse_25x' %}selected{% endif %}>normální (hotové hned)</option><option value="timelapse_25x" {% if ai.auto_export.playback == 'timelapse_25x' %}selected{% endif %}>zrychlené 25× (překóduje se)</option></select></div>
</div>
<div class="hint">Kamery s automatickým videem: {% for c in ai.auto_export.cameras %}<b>{{ cam(c) }}</b>{% if not loop.last %}, {% endif %}{% else %}žádná{% endfor %}. Videa se mažou po {{ ai.export_keep_days }} dnech (nastavíš ve Videích).</div>
</div>
</div>

<div class="savebar" x-show="tab!=='test'"><button class="btn">Uložit nastavení</button><span class="hint">Uloží se všechny záložky najednou.</span></div>
</form>

<!-- vlastní jevy (mimo hlavní formulář) -->
<div x-show="tab==='kamery'" x-cloak>
<div class="card"><div class="section-head"><h2>Vlastní jevy</h2><span class="hint">něco, co v seznamu chybí – AI ho bude hledat podle tvého popisu</span></div>
{% if custom_phenomena %}<ul class="plainlist">{% for c in custom_phenomena %}<li><b>{{ c.label }}</b> <span class="hint">– {{ c.desc }}</span><form method="post" action="/ai/phenomena/delete" data-nobusy style="display:inline;margin-left:.6rem"><input type="hidden" name="pid" value="{{ c.id }}"><button class="btn small sec">Odebrat</button></form></li>{% endfor %}</ul>{% endif %}
<form method="post" action="/ai/phenomena/add" class="row" style="align-items:end" data-nobusy>
<div><label>Název jevu</label><input type="text" name="label" maxlength="60" placeholder="např. Kondenzační stopy" required></div>
<div style="flex:2"><label>Popis pro AI (jak to na snímku poznat)</label><input type="text" name="desc" maxlength="300" placeholder="např. dlouhé bílé čáry za letadly, rovné nebo rozpité"></div>
<button class="btn">Přidat jev</button></form>
</div>
</div>

<!-- ===== 5 · test a statistika ===== -->
<div x-show="tab==='test'" x-cloak>
<div class="card"><h2>Vyzkoušet hned</h2>
<form method="post" action="/ai/test" class="row" style="align-items:end"><div><label>Kamera</label><select name="camera">{% for c in cameras %}<option value="{{ c }}">{{ cam(c) }}</option>{% endfor %}</select></div>
<div><button class="btn">Vyhodnotit oblohu teď</button></div></form>
<div class="hint">Vezme aktuální snímek, zeptá se AI a ukáže odpověď. Upozornění se při zkoušce neposílá.</div>
{% if test %}<pre>{{ test }}</pre>{% endif %}</div>
<div class="card"><div class="section-head"><h2>Statistika dotazů za posledních 7 dní</h2><a class="btn small sec" href="/history?show=all">Historie hodnocení</a></div>
<div class="stats7"><table><thead><tr><th>Den</th><th>Dotazů</th><th>Zajímavé</th><th>Upozornění</th><th>Přeskočeno</th><th>Chyby</th></tr></thead><tbody>
{% for d in stats7 %}<tr{% if loop.first %} class="today"{% endif %}><td>{{ d.label }} <span class="hint">{{ d.dow }}</span></td><td><b>{{ d.calls }}</b></td><td>{{ d.interesting }}</td><td>{% if d.notified %}<span class="badge ok">{{ d.notified }}</span>{% else %}0{% endif %}</td><td class="hint">{{ d.skipped }}</td><td>{% if d.errors %}<span class="badge err">{{ d.errors }}</span>{% else %}0{% endif %}</td></tr>{% endfor %}
<tr class="sum"><td>celkem</td><td><b>{{ stats7|sum(attribute='calls') }}</b></td><td>{{ stats7|sum(attribute='interesting') }}</td><td>{{ stats7|sum(attribute='notified') }}</td><td class="hint">{{ stats7|sum(attribute='skipped') }}</td><td>{{ stats7|sum(attribute='errors') }}</td></tr>
</tbody></table></div>
<div class="hint">„Dotazů“ = kolikrát se AI opravdu ptalo (počítá se do denního limitu{% if ai.daily_limit %} {{ ai.daily_limit }}{% endif %}). „Zajímavá obloha“ = skóre dosáhlo prahu. „Přeskočeno“ = obraz se od minula nezměnil, snímek se AI neposlal.</div></div>
</div>
</div>
{% endblock %}"""

TEMPLATES["email.html"] = """{% extends "base.html" %}{% block content %}
<div class="card"><div class="section-head"><h2 style="margin:0">Kam chodí upozornění: vlastní web (webhook)</h2>{% if web_ok %}<span class="badge ok">propojeno</span>{% elif web.enabled %}<span class="badge warn">chybí token</span>{% else %}<span class="badge mut">vypnuto</span>{% endif %}</div>
<form method="post" action="/web">
<p>Atmovio může posílat upozornění (se snímkem) a každou minutu stav kamer i všechna data REST API (detekce, videa, události) na <b>libovolný web</b> – třeba tvůj vlastní, kde se pak dají prohlížet z internetu nebo rozesílat e-mailem. Formát zpráv je popsaný v dokumentaci (<code>docs/webhook.md</code>); ukázkový přijímač v PHP je ve složce <code>examples/webhook-php</code> repozitáře.</p>
{% if not web_ok %}<ol class="steps"><li>Na svůj web nahraj přijímač (nebo napiš vlastní podle dokumentace) a nastav v něm tajný token.</li><li>Sem vlož adresu přijímače a stejný token.</li><li>Klikni <b>Uložit a otestovat spojení</b> – přijde testovací upozornění.</li></ol>{% endif %}
<label class="check"><input type="checkbox" name="enabled" {% if web.enabled %}checked{% endif %}> Posílat upozornění, stav kamer a data API na web</label>
<div class="row"><div><label>Adresa přijímače (webhook URL)</label><input type="text" name="url" value="{{ web.url }}" placeholder="https://muj-web.cz/atmovio/webhook.php"></div>
<div><label>Token (stejný jako v přijímači)</label><input type="password" name="token" value="{{ web.token }}" autocomplete="off" placeholder="dlouhý náhodný řetězec"></div></div>
<details><summary>Pokročilé</summary>
<div><label>Jak se má tento záznamník na webu jmenovat</label><input type="text" name="nvr_name" value="{{ web.nvr_name }}"></div>
<label class="check"><input type="checkbox" name="thumbs" {% if web.thumbs %}checked{% endif %}> Posílat každou minutu malé náhledy z kamer</label></details>
<button class="btn">Uložit</button> <button class="btn sec" formaction="/web/test">Uložit a otestovat spojení</button></form>
<p class="hint">RPi jen posílá – web ho nijak neovládá. Poslední stav spojení: {{ web_error or 'v pořádku' }}</p></div>
<div class="grid"><div class="card"><h2>Hlídání výpadků</h2>
<form method="post" action="/alerts">
<label class="check"><input type="checkbox" name="camera_outage" {% if al.camera_outage %}checked{% endif %}> Kamera přestala posílat obraz</label>
<label class="check"><input type="checkbox" name="frigate" {% if al.frigate %}checked{% endif %}> Nahrávání neběží</label>
<label class="check"><input type="checkbox" name="storage" {% if al.storage %}checked{% endif %}> Disk pro záznamy není dostupný</label>
<label class="check"><input type="checkbox" name="recovery" {% if al.recovery %}checked{% endif %}> Dát vědět, i když se to zase spraví</label>
<div class="row"><div><label>Hlásit až po (minutách bez obrazu)</label><input type="number" name="outage_min" min="1" max="1440" value="{{ al.outage_min }}"></div>
<div><label>Trvající výpadek připomenout každých (hodin)</label><input type="number" name="repeat_h" min="1" max="168" value="{{ al.repeat_h }}"></div></div>
<button class="btn">Uložit</button></form>
<div class="hint" style="margin-top:10px">Kontroluje se každou minutu. V upozornění je i IP kamery a jestli je připojená přes LAN, nebo VPN.</div></div>
<div class="card"><h2>E-mail přímo z RPi</h2><p class="hint">Použij, jen když upozornění neposíláš přes web – web e-maily rozesílá sám.</p>
<form method="post" action="/email">
<label>Server</label><input type="text" name="host" value="{{ em.host }}" placeholder="smtp.seznam.cz / smtp.gmail.com">
<div class="row"><div><label>Port</label><input type="number" name="port" value="{{ em.port }}"></div>
<div><label>Zabezpečení</label><select name="security"><option value="starttls" {% if em.security=='starttls' %}selected{% endif %}>STARTTLS (587)</option><option value="ssl" {% if em.security=='ssl' %}selected{% endif %}>SSL/TLS (465)</option><option value="none" {% if em.security=='none' %}selected{% endif %}>žádné (25)</option></select></div></div>
<label>Uživatel</label><input type="text" name="user" value="{{ em.user }}">
<label>Heslo (u Gmailu „heslo aplikace“)</label><input type="password" name="password" value="{{ em.password }}" autocomplete="off">
<label>Odesílatel</label><input type="email" name="from" value="{{ em.from }}">
<label>Příjemce (víc adres oddělených čárkou)</label><input type="text" name="to" value="{{ em.to }}">
<label class="check"><input type="checkbox" name="attach" {% if em.attach %}checked{% endif %}> Přiložit snímek k e-mailu o obloze</label>
<button class="btn">Uložit</button> <button class="btn sec" formaction="/email/test">Uložit a poslat test</button>
<p class="hint">Seznam.cz: smtp.seznam.cz, 465 SSL, uživatel = celý e-mail. Gmail: smtp.gmail.com, 587 STARTTLS, nutné 2FA + heslo aplikace.</p></form></div></div>
<div class="card"><h2>Poslední události</h2><ul class="events">
{% for ev in events %}<li><span class="t">{{ ev.ts[8:10] }}.{{ ev.ts[5:7] }}. {{ ev.ts[11:16] }}</span><span>{% if ev.kind == 'outage' %}<span class="badge err">výpadek</span>{% elif ev.kind == 'recovery' %}<span class="badge ok">obnoveno</span>{% else %}<span class="badge info">obloha</span>{% endif %} {{ ev.subject }}<div class="hint">{{ ev.message }}{% if ev.emailed %} · e-mail odeslán{% endif %}</div></span></li>{% endfor %}
{% if not events %}<li class="hint">Žádné události.</li>{% endif %}</ul></div>
{% endblock %}"""

TEMPLATES["vpn.html"] = """{% extends "base.html" %}{% block content %}
<div class="card"><h2>Vidí RPi na vzdálenou kameru?</h2>
<p>Zadej IP adresu vzdálené kamery (např. na chatě) a klikni <b>Ověřit</b>. Když odpoví, je vše v pořádku a nic dalšího nastavovat nemusíš. Když neodpoví, je potřeba na RPi zapnout VPN tunel (níže v části pro pokročilé) – nebo kamera jen neodpovídá na ping, pak ji zkus rovnou <a href="/discover">vyhledat</a>.</p>
<form method="post" action="/vpn/ping" class="row" style="align-items:end"><div><label>IP adresa vzdálené kamery</label><input type="text" name="test_ip" value="{{ v.test_ip }}" placeholder="10.10.10.4"></div><div><button class="btn">Ověřit</button></div></form>
{% if ping %}<pre>{{ ping }}</pre>{% endif %}</div>
<div class="card"><h2>Toto Raspberry Pi</h2><div class="tw"><table class="kv"><tr><td>Název v síti</td><td>{{ s.hostname }}</td></tr><tr><td>IP adresa RPi</td><td>{{ s.ip }}{% if s.ip_vpn %} <span class="hint">· ve VPN {{ s.ip_vpn }}</span>{% endif %}</td></tr><tr><td>Kamery</td><td>{% for c,i in caminfo.items() %}<div><b>{{ cam(c) }}</b> – {{ i.ip or '?' }} · {{ i.via }}</div>{% endfor %}{% if not caminfo %}–{% endif %}</td></tr></table></div>
<p class="hint">Aby se IP adresa RPi neměnila, nastav jí v routeru rezervaci (DHCP). Případně statickou IP v <a href="{{ cockpit_ui }}" target="_blank" rel="noopener">Cockpitu ↗</a> → Síť.</p></div>
<details class="card" style="padding:0 18px" {% if up %}open{% endif %}><summary>Pro pokročilé: VPN tunel WireGuard na RPi (jen když router vzdálenou síť nesměruje)</summary>
<div class="grid" style="padding-bottom:14px"><div class="card"><h2>Tunel ({{ v.iface }})</h2>
<div>Stav: {% if up %}<span class="badge ok">aktivní</span>{% else %}<span class="badge warn">neaktivní</span>{% endif %}
{% if enabled %}<span class="badge ok">start po restartu</span>{% endif %}</div>
<pre>{{ wg or 'žádný tunel' }}</pre>
<form method="post" action="/vpn/ctl" style="display:inline"><button class="btn small" name="action" value="up">Start</button><button class="btn small sec" name="action" value="down">Stop</button><button class="btn small sec" name="action" value="restart">Restart</button><button class="btn small danger" name="action" value="remove" onclick="return confirm('Odstranit konfiguraci tunelu?')">Odstranit</button></form></div>
<div class="card"><h2>Konfigurace tunelu</h2>
<form method="post" action="/vpn/save"><textarea name="conf" style="min-height:240px" placeholder="[Interface]
PrivateKey = ...
Address = 10.8.0.5/32

[Peer]
PublicKey = ...
Endpoint = router.example.cz:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25">{{ conf }}</textarea>
<p class="hint">V routeru vytvoř nového klienta WireGuard, zkopíruj jeho konfiguraci a vlož ji sem <b>celou, tak jak je</b>. Atmovio si ji sám upraví: řádky, které RPi nepotřebuje (DNS, skripty), vynechá a <code>AllowedIPs = 0.0.0.0/0</code> nahradí jen vzdálenou sítí, aby tunelem chodil pouze provoz ke kameře. Nejdřív nahoře vyplň a ověř IP adresu vzdálené kamery – podle ní se síť pozná.</p>
<button class="btn">Uložit a aktivovat</button></form></div></div></details>
{% endblock %}"""

TEMPLATES["system.html"] = """{% extends "base.html" %}{% block content %}
<div class="grid-wide">
<div class="card"><h2>Raspberry Pi</h2>
<div class="tw"><table class="kv"><tr><td>Název v síti</td><td>{{ s.hostname }}</td></tr><tr><td>IP adresa</td><td>{{ s.ip }}</td></tr><tr><td>Teplota</td><td>{{ s.temp }}</td></tr><tr><td>Zátěž</td><td>{{ s.load }}</td></tr><tr><td>Paměť</td><td>{{ s.mem }}</td></tr><tr><td>Běží od restartu</td><td>{{ s.uptime }}</td></tr><tr><td>Systémový disk</td><td>{{ s.rootfs }}</td></tr><tr><td>Atmovio</td><td>verze {{ version }}</td></tr></table></div>
<form method="post" action="/system/ctl" style="display:inline"><button class="btn small" name="action" value="restart_frigate">Restartovat nahrávání</button> <button class="btn small sec" name="action" value="fix_frigate">Opravit konfiguraci nahrávání</button> <button class="btn small danger" name="action" value="reboot" onclick="return confirm('Restartovat celé Raspberry Pi? Nahrávání se na minutu přeruší.')">Restartovat Raspberry Pi</button></form>
<p class="hint" style="margin-top:10px">Když něco nefunguje, zkus nejdřív restart nahrávání; restart celého RPi až potom.</p></div>
<div class="card"><h2>Zdraví disků (S.M.A.R.T.)</h2>
{% if not disks_health %}<p class="hint">Zatím žádné měření – první proběhne do hodiny po startu Atmovio.</p>{% endif %}
{% for d in disks_health %}<div style="display:flex;gap:.6rem;align-items:flex-start;margin-bottom:.7rem"><span class="dot {{ d.level }}" style="margin-top:.45rem;width:10px;height:10px;border-radius:50%;flex:none"></span>
<div><b>{{ d.role }}</b> · {{ d.model or d.dev }}{% if d.temp %} · {{ d.temp }} °C{% endif %}
<div class="hint">{% if d.level == 'ok' %}bez vadných sektorů, stav {{ 'OK' if d.healthy else '?' }}{% else %}nečitelné {{ d.pending or 0 }} · přemapované {{ d.reallocated or 0 }} · neopravitelné {{ d.uncorrectable or 0 }}<br>{{ d.trend }}{% endif %} <span class="mut">· měřeno {{ d.ts[8:10] }}. {{ d.ts[5:7]|int }}. {{ d.ts[11:16] }}</span></div></div></div>{% endfor %}
<p class="hint">Měří se každou hodinu. Nečitelné (pending) sektory jsou místa, která disk nedokázal přečíst – když jejich počet zůstane stejný, jde o jednorázovou chybu (typicky tvrdé vypnutí); když roste, disk končí a je čas ho vyměnit. Atmovio to sleduje a lišta nahoře zčervená jen při růstu nebo selhání.</p></div>
<div class="card"><h2>Heslo do přehrávače záznamů (Frigate)</h2>
<p class="hint">Přehrávač má vlastní přihlášení: uživatel <b>admin</b>, heslo stejné jako do Atmovio (nastaví se při instalaci i při každé změně hesla níže). Když se rozejdou, nech si vygenerovat nové – zobrazí se tady.</p>
<form method="post" action="/system/ctl"><button class="btn small sec" name="action" value="frigate_pw" onclick="return confirm('Vygenerovat nové heslo pro přehrávač? Trvá cca 30 s, nahrávání se krátce restartuje.')">Vygenerovat nové heslo</button></form>
{% if frigate_pw %}<pre>Uživatel: admin
Heslo:    {{ frigate_pw }}</pre>{% endif %}</div>
<div class="card" id="api"><h2>API pro jiné systémy</h2>
<p class="hint">Jen čtení: stav, kamery, snímky, detekce, videa (<code>/api/v1/…</code>, popis v <code>docs/api.md</code>). Hodí se pro Home Assistant, vlastní web nebo skripty. Klíč pošli v hlavičce <code>Authorization: Bearer &lt;klíč&gt;</code>.</p>
<div class="flash" style="font-weight:400"><span>📤</span><div><b>Odesílání na tvůj web</b> (každou minutu stav + stejná data jako API, plus upozornění se snímkem) se nastavuje v <a href="/email">Upozornění → vlastní web (webhook)</a>{% if web_ok %} – <span class="badge ok">propojeno</span>{% else %} – <span class="badge warn">nenastaveno</span>{% endif %}. Tam se zadává adresa a token; API klíč níže slouží jen pro čtení <i>z</i> RPi.</div></div>
{% if new_api_key %}<div class="flash"><span>🔑</span><div><b>Nový klíč (zobrazí se jen teď):</b><pre id="apikey" style="margin:.3rem 0 0;user-select:all">{{ new_api_key }}</pre><button type="button" class="btn small sec" onclick="swCopy('apikey', this)">Kopírovat</button></div></div>{% endif %}
{% if api_keys %}<div class="tw"><table><tr><th>Název</th><th>Klíč</th><th>Vytvořen</th><th></th></tr>{% for k in api_keys %}<tr><td>{{ k.name }}</td><td><code>{{ k.hint }}</code></td><td class="hint">{{ k.created|czdt }}</td><td><form method="post" action="/system/api_key/delete" onsubmit="return confirm('Zrušit klíč {{ k.name }}? Co ho používá, přestane fungovat.')"><input type="hidden" name="hint" value="{{ k.hint }}"><button class="btn small sec">Zrušit</button></form></td></tr>{% endfor %}</table></div>{% endif %}
<form method="post" action="/system/api_key" class="row" style="align-items:end;margin-top:.5rem"><div><label>Název nového klíče</label><input type="text" name="name" placeholder="např. Home Assistant" maxlength="40"></div><div style="flex:0"><button class="btn small">Vytvořit klíč</button></div></form>
<div class="hint" style="margin-top:.4rem">Zkus: <code>curl -H "Authorization: Bearer KLÍČ" http://{{ s.ip.split(' ')[0] }}/api/v1/status</code></div></div>
<div class="card" id="update"><h2>Aktualizace Atmovio</h2>
<div class="tw"><table class="kv"><tr><td>Nainstalováno</td><td>verze {{ version }}</td></tr><tr><td>Nejnovější vydání</td><td>{% if update_info.latest %}verze {{ update_info.latest }}{% elif update_info.checked %}zatím žádné{% else %}ještě nezjištěno{% endif %}{% if update_info.checked %} <span class="hint">· zjištěno {{ update_info.checked|czdt }}</span>{% endif %}</td></tr></table></div>
{% if update_info.available %}<div class="flash"><span>🆕</span><div><b>K dispozici je verze {{ update_info.latest }}.</b></div></div>{% elif update_info.error %}<div class="flash warn"><span>⚠️</span><div>Kontrola se nepovedla: {{ update_info.error }}</div></div>{% endif %}
<a class="btn small{% if not update_info.available %} sec{% endif %}" href="/system/update">{% if update_info.available %}Co je nového a aktualizovat{% else %}Kontrola a novinky{% endif %}</a>
<p class="hint" style="margin-top:10px">Nové verze se berou z GitHubu ({{ github_repo }}). Instaluje se jen na kliknutí, původní verze se zálohuje a při chybě se sama vrátí.</p></div>
<div class="card"><h2>Heslo do Atmovio</h2>
<form method="post" action="/system/password"><label>Nové heslo (min. 12 znaků)</label><input type="password" name="pw1" required minlength="12" autocomplete="new-password"><label>Znovu</label><input type="password" name="pw2" required minlength="12" autocomplete="new-password"><button class="btn">Změnit heslo</button></form></div>
</div>
<details><summary>Pro pokročilé: služby, aktualizace, logy</summary>
<pre>{{ docker }}</pre>
<form method="post" action="/system/ctl" style="display:inline"><button class="btn small sec" name="action" value="restart_portainer">Restart Portainer</button> <button class="btn small sec" name="action" value="update" onclick="return confirm('Stáhnout verze z docker-compose.yml a restartovat kontejnery?')">Aktualizovat kontejnery</button></form>
<p class="hint">Aktualizace systému, síť, uživatelé a disky: <a href="{{ cockpit_ui }}" target="_blank" rel="noopener">Cockpit ↗</a>. Kontejnery: <a href="{{ portainer_ui }}" target="_blank" rel="noopener">Portainer ↗</a>. Aktualizace Atmovio: karta výše, nebo ručně přes SSH <code>sudo bash update-atmovio.sh</code>.</p>
<p class="hint">Logy všech částí (Atmovio, disk, VPN, nahrávání, systém) najdeš v sekci <a href="/logs">Logy</a>.</p></details>
{% endblock %}"""

TEMPLATES["update.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/system">← Systém</a></div>{% endblock %}{% block content %}
<div x-data="updater({{ 'true' if running else 'false' }}, {{ version|tojson }}, {{ log_text|tojson }})">
<div class="grid">
<div class="card"><h2>Verze</h2>
<div class="tw"><table class="kv"><tr><td>Nainstalováno</td><td>verze {{ version }}</td></tr><tr><td>Nejnovější vydání</td><td>{% if st.latest %}verze {{ st.latest }}{% if st.published %} <span class="hint">· vydáno {{ st.published }}</span>{% endif %}{% elif st.checked %}zatím žádné vydání{% else %}ještě nezjištěno{% endif %}</td></tr><tr><td>Naposledy zjištěno</td><td>{% if st.checked %}{{ st.checked|czdt }}{% else %}–{% endif %}</td></tr></table></div>
{% if st.error %}<div class="flash warn"><span>⚠️</span><div>Kontrola se nepovedla: {{ st.error }}<br><span class="hint">RPi potřebuje přístup na api.github.com a github.com.</span></div></div>{% endif %}
{% if running %}<div class="flash"><span>⏳</span><div><b>Aktualizace probíhá…</b> Web se na chvíli odmlčí, až se Atmovio restartuje. Nech stránku otevřenou, sama ukáže výsledek.</div></div>
{% elif st.available %}<div class="flash"><span>🆕</span><div><b>K dispozici je verze {{ st.latest }}.</b> Trvá to zhruba 2–4 minuty; nahrávání kamer běží dál, jen web Atmovio je chvíli nedostupný. Původní verze se zálohuje a při chybě se sama vrátí.</div></div>
<form method="post" action="/system/update/start" data-nobusy><button class="btn" :disabled="running" onclick="return confirm('Nainstalovat Atmovio {{ st.latest }}? Web bude asi minutu nedostupný.')">Nainstalovat verzi {{ st.latest }}</button></form>
{% elif st.checked %}<p class="hint">Máš nejnovější verzi.</p>{% else %}<p class="hint">Klikni na Zkontrolovat teď.</p>{% endif %}
<form method="post" action="/system/update/check" style="margin-top:.6rem"><button class="btn small sec" :disabled="running" data-busy="Ptám se GitHubu">Zkontrolovat teď</button></form>
<form method="post" action="/system/update/auto" data-nobusy style="margin-top:.8rem"><label><input type="checkbox" name="auto_check" value="1" {% if auto_check %}checked{% endif %} onchange="this.form.submit()"> Kontrolovat nové verze automaticky (1× denně jen dotaz na GitHub; nic se neinstaluje samo)</label></form>
</div>
<div class="card"><h2>Co je nového{% if st.latest %} ve verzi {{ st.latest }}{% endif %}</h2>
{% if st.notes %}<pre style="white-space:pre-wrap;max-height:22rem;overflow:auto">{{ st.notes }}</pre>{% else %}<p class="hint">Popis vydání se zobrazí po kontrole.</p>{% endif %}
{% if st.url %}<a href="{{ st.url }}" target="_blank" rel="noopener">Vydání na GitHubu ↗</a>{% endif %}</div>
</div>
<div class="card" x-show="running || log" x-cloak>
 <h2>Průběh aktualizace</h2>
 <div class="flash" x-show="phase=='run'"><span>⏳</span><div>Připravuji novou verzi (stažení knihoven, kontrola)…</div></div>
 <div class="flash" x-show="phase=='restart'"><span>⏳</span><div>Atmovio se restartuje, čekám na odpověď…</div></div>
 <div class="flash" x-show="phase=='done'"><span>✅</span><div><b>Hotovo.</b> Běží verze <span x-text="newVersion"></span>. <a href="/system/update">Obnovit stránku</a></div></div>
 <div class="flash err" x-show="phase=='failed'"><span>⛔</span><div><b>Aktualizace selhala</b>, původní verze byla obnovena. Podrobnosti v záznamu níže.</div></div>
 <pre style="max-height:24rem;overflow:auto;font-size:.8rem;white-space:pre-wrap" x-text="log"></pre>
</div>
</div>
{% endblock %}"""

TEMPLATES["logs.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions">{% if issue_url %}<a class="btn small" href="{{ issue_url }}" target="_blank" rel="noopener" title="Otevře GitHub s předvyplněným hlášením – chybové řádky a verze, nic osobního">🐛 Nahlásit chybu na GitHub</a>{% endif %}<form method="post" action="/logs/clear" data-nobusy onsubmit="return confirm('Vymazat tento log? Zobrazí se pak jen nové záznamy.')"><input type="hidden" name="src" value="{{ src }}"><button class="btn small danger">Vymazat tento log</button></form></div>{% endblock %}{% block content %}
<div class="card">
<div class="tabs">{% for key, name, _d in sources %}<a class="tab{% if key == src %} active{% endif %}" href="/logs?src={{ key }}&n={{ n }}{% if q %}&q={{ q|urlencode }}{% endif %}">{{ name }}</a>{% endfor %}</div>
<p class="hint" style="margin-top:8px">{{ desc }}</p>
<form method="get" action="/logs" class="row" style="align-items:end"><input type="hidden" name="src" value="{{ src }}">
<div><label>Hledat v logu</label><input type="text" name="q" value="{{ q }}" placeholder="např. chata, chyba, VPN"></div>
<div><label>Počet řádků</label><select name="n">{% for v in (100, 300, 1000) %}<option value="{{ v }}"{% if v == n %} selected{% endif %}>{{ v }}</option>{% endfor %}</select></div>
{% if src == 'frigate' %}<div><label class="check" style="margin:0 0 8px"><input type="checkbox" name="raw" value="1" {% if raw %}checked{% endif %}> i provozní řádky webserveru</label></div>{% endif %}
<div><button class="btn small">Zobrazit</button> <a class="btn small sec" href="/logs?src={{ src }}&n={{ n }}{% if q %}&q={{ q|urlencode }}{% endif %}{% if raw %}&raw=1{% endif %}">Obnovit</a> <button type="button" class="btn small sec" onclick="swCopy('logtext', this)">Kopírovat</button> <a class="btn small sec" href="/logs/download?src={{ src }}">Stáhnout</a></div></form>
{% if since %}<div class="hint" style="margin-top:6px">zobrazeno od {{ since }} (starší část logu byla vymazána)</div>{% endif %}
{% if summary %}<div class="row" style="gap:8px;margin:8px 0;align-items:center">{% for label, cls in summary %}<span class="badge {{ cls }}">{{ label }}</span>{% endfor %}{% if src == 'atmovio' %}<a class="hint" style="margin-left:auto" href="/logs?src={{ src }}&n={{ n }}{% if q %}&q={{ q|urlencode }}{% endif %}{% if not raw %}&raw=1{% endif %}">{% if raw %}přehledně{% else %}surový text{% endif %}</a>{% endif %}</div>{% endif %}
{% if rows %}<div class="loglist">{% for r in rows|reverse %}<div class="lrow {{ r.level }}"><span class="lt">{{ r.ts[5:16] if r.ts else '' }}</span><span class="li">{% if r.level == 'err' %}✖{% elif r.level == 'warn' %}⚠{% elif r.level == 'note' %}◌{% else %}·{% endif %}</span><span class="lx">{{ r.text }}{% if r.why %}<small>{{ r.why }}</small>{% endif %}</span></div>{% endfor %}{% if not rows %}<div class="hint">Log je prázdný.</div>{% endif %}</div>
<pre class="logbox" id="logtext" hidden>{{ text }}</pre>
<p class="hint">Nejnovější nahoře. ✖ chyba = něco je potřeba udělat · ⚠ stojí za pozornost · ◌ přechodné (hosting nebo AI chvíli neodpověděly, vyřešilo se samo) · · běžný provoz.</p>
{% else %}<pre class="logbox" id="logtext">{{ text or 'Log je prázdný.' }}</pre>{% endif %}
<p class="hint">Nejnovější řádky jsou dole; časy jsou v místním čase RPi. Systémové logy (Disk, VPN, Systém) ukazují i starší události od posledního startu – „Vymazat“ jen posune, odkdy se zobrazují. Tlačítko Kopírovat zkopíruje celý log do schránky.</p>
</div>
{% endblock %}"""

TEMPLATES["detection.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/history">← Historie</a></div>{% endblock %}{% block content %}
<div class="grid-2" style="grid-template-columns:minmax(0,3fr) minmax(300px,2fr)">
<div>
<div class="card" style="padding:0;overflow:hidden">
{% if use_export %}
<video id="clip" controls preload="metadata" playsinline style="width:100%;display:block;background:#000;aspect-ratio:16/9" poster="{% if e.image %}/snapshot/{{ e.image }}{% endif %}" src="/videos/{{ use_export.id }}/play.mp4"></video>
{% elif clip_state == 'ok' %}
<video id="clip" controls preload="metadata" playsinline style="width:100%;display:block;background:#000;aspect-ratio:16/9" poster="{% if e.image %}/snapshot/{{ e.image }}{% endif %}" src="/clip/{{ e.camera }}.mp4?start={{ '%.0f'|format(clip_start) }}&end={{ '%.0f'|format(clip_end) }}"></video>
{% elif e.image %}<a href="/snapshot/{{ e.image }}" data-lightbox="detail" data-caption="{{ cam(e.camera) }} · {{ e.ts[8:10] }}. {{ e.ts[5:7]|int }}. {{ e.ts[0:4] }} {{ e.ts[11:16] }}"><img src="/snapshot/{{ e.image }}" alt="" style="width:100%;display:block"></a>{% else %}<div class="hint" style="padding:18px">Snímek už není k dispozici.</div>{% endif %}
<div style="padding:.6rem .9rem;display:flex;gap:.8rem;align-items:center;flex-wrap:wrap">
<form method="get" action="/detection/{{ e.id }}" class="row" style="align-items:end;gap:.5rem;flex:1">
<div style="min-width:110px"><label>Minut před</label><input type="number" name="before" min="0" max="60" value="{{ before }}"></div>
<div style="min-width:110px"><label>Minut po</label><input type="number" name="after" min="0" max="60" value="{{ after }}"></div>
<div style="flex:0"><button class="btn small sec">Přehrát úsek</button></div></form>
{% if e.image %}<a class="btn small sec" href="/snapshot/{{ e.image }}" data-lightbox="detail" data-caption="{{ cam(e.camera) }} · {{ e.ts[11:16] }}">🖼 Snímek AI</a>{% endif %}
</div>
{% if use_export %}<div class="hint" style="padding:0 .9rem .7rem">🎬 Přehrává se <b>vystřižené video</b> „{{ use_export.name }}“ ({{ use_export.range_h }}, {{ use_export.duration_h }}) – plynule, s posuvníkem. Jiný rozsah přímo ze záznamu zobrazíš tlačítkem <b>Přehrát úsek</b>.</div>
{% elif clip_state == 'ok' %}<div class="hint" style="padding:0 .9rem .7rem">Přehrává se surový záznam {{ before }} min před a {{ after }} min po snímku, který Frigate skládá z 10s úseků – čas v přehrávači proto může skákat a posuvník je nepřesný. Pro plynulé přehrání si video níže vystřihni; pak se tady přehraje samo.</div>
{% elif clip_state == 'none' %}<div class="flash warn" style="margin:0 .9rem .7rem"><span>🎞</span><div>Pro tento čas <b>není záznam</b> – kamera v tu dobu nenahrávala (výpadek, živý režim bez disku) nebo už byl smazán po {{ retain }} dnech. Video tedy nelze přehrát ani vystřihnout; snímek AI zůstává.</div></div>
{% elif clip_state == 'offline' %}<div class="flash warn" style="margin:0 .9rem .7rem"><span>⏳</span><div>Frigate právě neodpovídá (startuje nebo se restartuje) – zkus to za minutu.</div></div>
{% else %}<div class="hint" style="padding:0 .9rem .7rem">Záznam není k dispozici – disk pro záznamy není připojený.</div>{% endif %}
</div>

<div class="card"><div class="section-head"><h2>Vystřihnout video ke stažení</h2>{% if my_exports %}<a class="btn small sec" href="/videos">Moje videa ({{ my_exports|length }})</a>{% endif %}</div>
{% if clip_state == 'ok' %}
<form method="post" action="/detection/{{ e.id }}/export">
<div class="row" style="align-items:end">
<div style="flex:3"><label>Název videa</label><input type="text" name="name" value="{{ default_name }}" maxlength="80"></div>
<div><label>Minut před snímkem</label><input type="number" name="before" min="0" max="60" value="{{ before }}"></div>
<div><label>Minut po snímku</label><input type="number" name="after" min="0" max="60" value="{{ after }}"></div>
<div><label>Rychlost videa</label><select name="playback"><option value="realtime">normální (bez překódování, hotové hned)</option><option value="timelapse_25x">zrychlené 25× – timelapse (překóduje se, pár minut)</option></select></div>
</div>
<button class="btn" data-busy="Zadávám vystřižení videa">🎬 Vytvořit video</button>
<span class="hint">Video (MP4) se uloží na disk pro záznamy a objeví se ve <a href="/videos">Videa</a> s náhledem, přehrávačem a odkazem ke stažení. Normální video jde v přehrávači zrychlit až 120×; zrychlené 25× je malý soubor vhodný ke sdílení. Samo se smaže po nastavené době.</span></form>
{% elif clip_state == 'none' %}<p class="hint">Pro tento čas není záznam, video nelze vystřihnout.</p>{% elif clip_state == 'offline' %}<p class="hint">Frigate právě neodpovídá – zkus to za minutu.</p>{% else %}<p class="hint">Bez připojeného disku pro záznamy nelze video vystřihnout.</p>{% endif %}
{% for j in pending_auto %}<div class="flash" style="margin-top:.6rem"><span>🎬</span><div>Video −{{ ((j.start_ts and (e_center - j.start_ts) / 60) or 0)|round|int }}/+{{ ((j.end_ts - e_center) / 60)|round|int }} min se vytvoří <b>automaticky v {{ j.due_h }}</b> (až doběhne záznam po snímku).</div></div>{% endfor %}
{% if my_exports %}<div style="margin-top:.6rem;display:flex;gap:.4rem;flex-wrap:wrap;align-items:center"><span class="hint">Z této detekce už existuje:</span>{% for x in my_exports %}<a class="btn small sec" href="/videos/{{ x.id }}/play.mp4" onclick="return swPlayVideo(this.href, this.dataset.title)" data-title="{{ x.name }}">▶ {{ x.name }}</a>{% endfor %}</div>{% endif %}
</div>
</div>

<div class="card">
<div style="display:flex;align-items:baseline;gap:.6rem;flex-wrap:wrap"><span class="big" style="font-size:2rem">{{ e.ts|cztime }}</span><span class="hint" style="font-size:1rem">{{ e.ts|czdate }}</span></div>
<div class="hint" style="margin-bottom:.6rem">📷 <a href="/camera/{{ e.camera }}">{{ cam(e.camera) }}</a> · {{ info.ip or '' }} {{ info.via }}</div>
<div style="display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;margin-bottom:.5rem"><span class="badge info" style="font-size:.95rem;padding:.2rem .7rem">{{ e.score }}/10</span>{% for l in phen %}<span class="badge warn">{{ l }}</span>{% endfor %}{% if e.notified %}<span class="badge ok">upozornění odesláno</span>{% endif %}{% if my_exports %}<a class="badge info" href="/videos#v{{ my_exports[0].id }}">🎬 video exportováno</a>{% endif %}</div>
<p style="font-size:1.02rem;line-height:1.55">{{ e.description }}</p>
{% if e.note %}<div class="hint">{{ e.note }}</div>{% endif %}
<div style="display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.6rem"><a class="btn small sec" href="{{ frigate_ui }}/review" target="_blank" rel="noopener">Frigate ↗</a>
<form method="post" action="/detection/{{ e.id }}/delete" onsubmit="return confirm('Smazat tuto detekci i se snímkem?')"><button class="btn small danger">Smazat detekci</button></form></div>
</div>
</div>

<div class="card"><div class="section-head"><h2>Další upozornění v okolí (všechny kamery)</h2><span class="hint">4 před · 4 po této detekci</span></div>
<div class="gallery">
{% for n in neighbours %}<div class="shot">
<a href="/detection/{{ n.id }}?before={{ before }}&after={{ after }}"><img src="/snapshot/{{ n.image }}" alt="" loading="lazy"></a>
<div class="b"><div class="line"><span class="s">{{ n.score }}/10</span><span class="when">{{ n.ts|cztime }}</span><span class="hint">{{ n.ts|czdate }}</span></div>
<div class="hint"><b>{{ cam(n.camera) }}</b>{% if n.phenomenon %} · {{ n.phenomenon }}{% endif %}</div>
<a class="btn small sec" href="/detection/{{ n.id }}?before={{ before }}&after={{ after }}">Otevřít</a></div></div>{% endfor %}
{% if not neighbours %}<div class="hint">Žádné další upozornění.</div>{% endif %}
</div></div>
{% endblock %}"""

TEMPLATES["live.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions">{% if mode != 'grid' %}<a class="btn small sec" href="/live">← Kamery</a>{% endif %}{% if mode == 'grid' and cameras %}<a class="btn small" href="/live/all">▶ Živě všechny kamery</a>{% endif %}<a class="btn small sec" href="{{ frigate_ui }}" target="_blank" rel="noopener">Frigate – záznamy ↗</a></div>{% endblock %}{% block content %}
{% if not cameras %}<div class="card"><b>Zatím žádné kamery.</b> <a href="/discover">Nech je vyhledat v síti</a>.</div>{% endif %}
{% if not fs.online %}<div class="flash warn"><span>⏳</span><div>Frigate právě neodpovídá (startuje nebo se restartuje) – obraz naskočí, až poběží.</div></div>{% endif %}
{% macro state(c) %}{% set s = fs.cameras.get(c) %}{% set out = outages.get('cam:' ~ c) %}{% if out %}<span class="badge err">výpadek {{ out }}</span>{% elif s and s.fps %}<span class="badge ok" title="snímků/s náhledového streamu (AI, náhled); záznam je v plné kvalitě kamery">{{ '%.0f'|format(s.fps) }} fps</span>{% else %}<span class="badge warn">bez obrazu</span>{% endif %}{% endmacro %}

{% if mode == 'all' %}
<div class="cams big">
{% for c in cameras %}<div class="cam"><a class="img" href="/camera/{{ c }}" title="Otevřít kameru"><img src="/stream/{{ c }}.mjpeg?h=480&fps=5&t={{ now_ts }}" alt="" onerror="window.swImgFail?swImgFail(this,'Kamera zrovna nedává obraz'):this.style.display='none'"><span class="live"><span class="dot ok"></span>ŽIVĚ</span></a>
<div class="body"><div class="name"><span>{{ cam(c) }}</span>{{ state(c) }}</div><div class="meta"><span>{{ caminfo[c].ip or 'IP ?' }}</span><span>·</span><span>{{ caminfo[c].via }}</span><a href="/camera/{{ c }}" style="margin-left:auto">otevřít kameru ▶</a></div></div></div>
{% endfor %}
</div>
<p class="hint" style="margin-top:.8rem">Živý přenos ze všech kamer najednou (do 5 snímků/s z menšího streamu). Když stránku zavřeš, přenos se ukončí. Plynulé video v plném rozlišení a přehrávání záznamů: <a href="{{ frigate_ui }}" target="_blank" rel="noopener">Frigate ↗</a>.</p>

{% else %}
<div class="cams big">
{% for c in cameras %}<div class="cam"><a class="img" href="/camera/{{ c }}" title="Otevřít kameru – velký obraz, živě, nastavení"><img src="/live/{{ c }}.jpg?h=720&t={{ now_ts }}" data-refresh="10" alt="" loading="lazy" onerror="window.swImgFail?swImgFail(this):this.style.display='none'">
{% if outages.get('cam:' ~ c) %}<span class="live"><span class="dot err"></span>VÝPADEK</span>{% elif fs.cameras.get(c) and fs.cameras.get(c).fps %}<span class="live"><span class="dot ok"></span>AKTUÁLNÍ SNÍMEK</span>{% else %}<span class="live"><span class="dot warn"></span>BEZ SIGNÁLU</span>{% endif %}</a>
<div class="body"><div class="name"><span>{{ cam(c) }}</span>{{ state(c) }}</div>
<div class="meta"><span>{{ caminfo[c].ip or 'IP ?' }}</span><span>·</span><span>{{ caminfo[c].via }}</span>{% if c in cfg.ai.cameras and cfg.ai.enabled %}<span class="badge info">AI hlídá</span>{% endif %}{% if cfg.ai.enabled and cfg.ai.auto_export.enabled and c in cfg.ai.auto_export.cameras %}<span class="badge ok" title="Po upozornění se automaticky vystřihne video">🎬 auto video −{{ cfg.ai.auto_export.before_min }}/+{{ cfg.ai.auto_export.after_min }} min</span>{% endif %}</div>
<div class="acts"><a class="btn" href="/camera/{{ c }}">{{ icons.play|safe }} Otevřít kameru</a><a class="btn sec" href="/camera/{{ c }}#nastaveni">{{ icons.cog|safe }} Nastavení</a></div></div></div>
{% endfor %}
</div>
{% if cameras %}<p class="hint" style="margin-top:.8rem">Snímky se samy obnovují každých 10 s. Kliknutím na kameru otevřeš její stránku – velký obraz, živý přenos, stav, nastavení, AI, detekce i videa. <a href="/live/all">Živě všechny kamery najednou</a>.</p>{% endif %}
{% endif %}
{% endblock %}"""

TEMPLATES["camera.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/live">← Kamery</a><a class="btn small sec" href="{{ frigate_ui }}/#{{ camera }}" target="_blank" rel="noopener">Záznamy ve Frigate ↗</a></div>{% endblock %}{% block content %}
{% set s = fs.cameras.get(camera) %}{% set out = outages.get('cam:' ~ camera) %}
<div class="card" style="padding:0;overflow:hidden">
<div class="live-big"><img id="cam-{{ camera }}" src="/live/{{ camera }}.jpg?h=1080&t={{ now_ts }}" data-snap="/live/{{ camera }}.jpg?h=1080" data-stream="/stream/{{ camera }}.mjpeg?h=720&fps=10" data-refresh="10" alt="" onerror="swImgFail(this,'Kamera zrovna nedává obraz')"></div>
<div style="padding:.6rem .9rem;display:flex;gap:.6rem;align-items:center;flex-wrap:wrap">{% if out %}<span class="badge err">výpadek {{ out }}</span>{% elif s and s.fps %}<span class="badge ok">živě · {{ '%.0f'|format(s.fps) }} fps</span>{% else %}<span class="badge warn">bez obrazu</span>{% endif %}<span class="hint">{{ info.ip or '' }} · {{ info.via }}</span>
<span style="margin-left:auto;display:flex;gap:.4rem;flex-wrap:wrap"><button type="button" class="btn small" data-target="cam-{{ camera }}" onclick="swLiveToggle(this)">▶ Spustit živý přenos</button><a class="btn small sec" href="/live/{{ camera }}.jpg?h=1080&t={{ now_ts }}" data-lightbox="one" data-caption="{{ cam(camera) }}">🔍 Celý snímek</a></span></div>
<div class="hint" style="padding:0 .9rem .7rem">Snímek se sám obnovuje každých 10 s. Živý přenos běží jen po kliknutí a dokud stránku neopustíš.</div>
</div>

<div class="tabs" style="margin:.2rem 0 .8rem"><a class="tab" href="#stav">Stav</a><a class="tab" href="#ai">Hlídání oblohy</a><a class="tab" href="#detekce">Detekce</a><a class="tab" href="#videa">Videa</a><span style="margin-left:auto;display:flex;gap:.35rem;flex-wrap:wrap"><a class="tab" href="/cameras/edit/{{ camera }}">⚙ Upravit kameru</a><a class="tab" href="/ai#kamery">☁ Nastavení AI</a></span></div>

<div class="grid-2">
<div class="card" id="stav"><div class="section-head"><h2>Stav</h2></div>
<div class="kpi">
 <div class="item"><div class="k">Obraz</div><div class="v">{% if out %}<span class="badge err">výpadek</span>{% elif s and s.fps %}{{ '%.0f'|format(s.fps) }} fps{% else %}<span class="badge warn">bez signálu</span>{% endif %}</div><div class="d">{% if out %}už {{ out }}{% elif s and s.fps %}náhledový stream (AI a náhled); záznam jde v plné kvalitě kamery{% else %}Frigate z kamery nic nedostává{% endif %}</div></div>
 <div class="item"><div class="k">Nahrávání</div><div class="v">{% if rec_state == 'ok' %}<span class="badge ok">běží</span>{% elif rec_state == 'none' %}<span class="badge warn">bez záznamu</span>{% elif rec_state == 'offline' %}<span class="badge warn">Frigate neběží</span>{% else %}<span class="badge warn">bez disku</span>{% endif %}</div><div class="d">{% if rec_state == 'ok' %}posledních 10 minut je na disku{% elif rec_state == 'none' %}za posledních 10 min nic – kamera nebo disk{% elif rec_state == 'nodisk' %}připoj disk v Záznamech{% else %}zkus za minutu{% endif %}</div></div>
 <div class="item"><div class="k">Adresa</div><div class="v" style="font-size:.95rem">{{ info.ip or '?' }}</div><div class="d">{{ info.via }}{% if info.via == 'VPN' %} · <a href="/vpn">Síť a VPN</a>{% endif %}</div></div>
 <div class="item"><div class="k">Poslední AI</div><div class="v" style="font-size:.95rem">{% if last_eval %}{{ last_eval.ts|cztime }} <span class="hint">{{ last_eval.ts|czdate }}</span>{% else %}–{% endif %}</div><div class="d">{% if last_eval and last_eval.error %}<span class="badge err">chyba</span> {{ last_eval.error[:60] }}{% elif last_eval %}{{ last_eval.score }}/10 · {{ last_eval.phenomenon or 'nic zvláštního' }}{% if last_eval.notified %} · <span class="badge ok">upozorněno</span>{% endif %}{% else %}zatím nevyhodnoceno{% endif %}</div></div>
</div>
{% if outage_events %}<div class="hint" style="margin-top:.6rem">Poslední výpadky: {% for o in outage_events %}{{ o.ts|czdt }}{% if not loop.last %} · {% endif %}{% endfor %}</div>{% endif %}
</div>

<div class="card" id="ai"><div class="section-head"><h2>Hlídání oblohy (AI)</h2>{% if not cfg.ai.enabled %}<span class="badge warn">AI je celkově vypnuté</span>{% elif ai_on %}<span class="badge ok">hlídá se</span>{% else %}<span class="badge mut">nehlídá se</span>{% endif %}</div>
{% set rl = rule(camera) %}
<div class="kpi">
 <div class="item"><div class="k">Upozornit od</div><div class="v">{{ rl.threshold }}/10</div><div class="d">{% if rl.custom %}vlastní nastavení kamery{% else %}výchozí nastavení{% endif %}</div></div>
 <div class="item"><div class="k">Jevy</div><div class="v">{{ rl.phenomena|length }}</div><div class="d">{% if rl.any %}+ cokoli fotogenického{% else %}jen vybrané jevy{% endif %}</div></div>
 <div class="item"><div class="k">Automatické video</div><div class="v" style="font-size:.95rem">{% if auto_on %}zapnuto{% else %}vypnuto{% endif %}</div><div class="d">{% if auto_on %}−{{ ax.before_min }}/+{{ ax.after_min }} min{% if ax.playback == 'timelapse_25x' %}, 25×{% endif %}{% else %}po upozornění nic{% endif %}</div></div>
 <div class="item"><div class="k">Dotazů za 7 dní</div><div class="v">{{ week.calls }}</div><div class="d">{{ week.notified }} upozornění · kontrola každých {{ cfg.ai.interval_min }} min</div></div>
</div>
{% if pending_auto %}<div class="hint" style="margin-top:.5rem">🎬 Čeká na vytvoření: {% for j in pending_auto %}{{ j.name }} (v {{ j.due_h }}){% if not loop.last %} · {% endif %}{% endfor %}</div>{% endif %}
<div style="display:flex;gap:.4rem;flex-wrap:wrap;align-items:center;margin-top:.7rem"><a class="btn small" href="/ai#kamery">Nastavení AI pro tuto kameru</a>
<form method="post" action="/ai/test" data-nobusy style="margin:0"><input type="hidden" name="camera" value="{{ camera }}"><input type="hidden" name="back" value="/camera/{{ camera }}"><button class="btn small sec" {% if not cfg.ai.api_key %}disabled{% endif %}>Vyzkoušet AI na aktuálním snímku</button></form><span class="hint">Výsledek se ukáže v Nastavení → AI → Vyzkoušet (bez upozornění).</span></div>
</div>
</div>

<div class="card" id="detekce"><div class="section-head"><h2>Poslední upozornění z této kamery</h2><a class="btn small sec" href="/history?camera={{ camera }}">Celá historie</a></div>
<div class="gallery">
{% for e in recent %}<div class="shot"><a href="/detection/{{ e.id }}"><img src="/snapshot/{{ e.image }}" alt="" loading="lazy"></a>
<div class="b"><div class="line"><span class="s">{{ e.score }}/10</span><span class="when">{{ e.ts|cztime }}</span><span class="hint">{{ e.ts|czdate }}</span></div><div class="hint">{{ e.phenomenon }}</div>{% if e.exported %}<div><a class="badge info" href="/videos">🎬 video exportováno</a></div>{% endif %}<a class="btn small sec" href="/detection/{{ e.id }}">Detail</a></div></div>{% endfor %}
{% if not recent %}<div class="hint">Zatím žádné upozornění z této kamery.</div>{% endif %}
</div></div>

<div class="card" id="videa"><div class="section-head"><h2>Videa z této kamery</h2><a class="btn small sec" href="/videos">Všechna videa</a></div>
{% if videos %}<div class="tw"><table><tr><th>Název</th><th>Úsek</th><th>Velikost</th><th></th></tr>
{% for v in videos %}<tr><td><b>{{ v.name }}</b>{% if v.auto %} <span class="badge ok">auto</span>{% endif %}</td><td class="hint">{{ v.range_h }} ({{ v.duration_h }})</td><td class="hint">{{ v.size_h or '–' }}</td>
<td style="white-space:nowrap">{% if v.ready %}<a class="btn small" href="/videos/{{ v.id }}/play.mp4" onclick="return swPlayVideo(this.href, this.dataset.title)" data-title="{{ v.name }}">▶ Přehrát</a> <a class="btn small sec" href="/videos/{{ v.id }}/download">⬇</a>{% elif v.expired %}<span class="badge err">záznam už neexistuje</span>{% elif v.stuck %}<span class="badge warn">zaseklo se</span> <form method="post" action="/videos/{{ v.id }}/retry" style="display:inline"><input type="hidden" name="back" value="/camera/{{ camera }}"><button class="btn small" data-busy="Zadávám video znovu">↻ Znovu</button></form> <form method="post" action="/videos/{{ v.id }}/delete" style="display:inline" onsubmit="return confirm('Smazat video {{ v.name }}?')"><button class="btn small sec">Smazat</button></form>{% elif v.in_progress %}<span class="hint">vytváří se…</span>{% else %}<span class="hint">není k dispozici</span>{% endif %}{% if v.expired %} <form method="post" action="/videos/{{ v.id }}/delete" style="display:inline" onsubmit="return confirm('Smazat video {{ v.name }}?')"><button class="btn small sec">Smazat</button></form>{% endif %}</td></tr>{% endfor %}</table></div>
{% else %}<p class="hint">Žádné video. Vytvoříš ho z detailu detekce, nebo zapni automatické video v <a href="/ai#kamery">Nastavení AI</a>.</p>{% endif %}</div>

<div class="card"><div class="section-head"><h2>Nastavení kamery</h2><span class="hint">ID ve Frigate: <code>{{ camera }}</code></span></div>
<dl class="facts"><dt>Hlavní stream</dt><dd><code>{{ settings.main }}</code></dd><dt>Vedlejší stream</dt><dd><code>{{ settings.sub or '–' }}</code></dd></dl>
<div style="display:flex;gap:.4rem;flex-wrap:wrap"><a class="btn small" href="/cameras/edit/{{ camera }}">⚙ Upravit název, adresy a heslo</a><a class="btn small sec" href="{{ frigate_ui }}/config" target="_blank" rel="noopener">Masky a zóny ve Frigate ↗</a></div>
<p class="hint" style="margin:.6rem 0 0">Tahle stránka jen ukazuje stav. Nastavení kamer je na jednom místě v <a href="/cameras">Nastavení → Kamery</a>, hlídání oblohy v <a href="/ai#kamery">Nastavení → AI</a>.</p></div>
{% endblock %}"""

TEMPLATES["videos.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/studio/settings">⚙ Nastavení studia</a></div>{% endblock %}{% block content %}
<div class="section-head" id="studio"><h2>Studio – zrychlená videa</h2><span class="hint">s intrem, textem a hudbou · připravená ke stažení{% if studio_auto %} · automatika zapnutá{% endif %}</span></div>
{% if not studio %}<div class="card"><p class="hint" style="margin:0">Zatím žádné. U hotového videa níže klikni na <b>🎞 Studio</b> – vybereš rychlost (10–240×), intro, text a hudbu, a než se cokoli nahraje, uvidíš výsledek.</p></div>{% endif %}
<div class="gallery videos">
{% for s in studio %}<div class="shot video">
{% if s.ready %}<a class="thumb" href="/studio/v/{{ s.id }}"><img src="{% if s.thumb %}/studio/v/{{ s.id }}/thumb.jpg{% endif %}" alt="" loading="lazy" onerror="this.style.visibility='hidden'"><span class="play">▶</span><span class="dur">{{ s.duration_h }} · {{ s.speed }}×</span></a>
{% else %}<a class="thumb wait" href="/studio/v/{{ s.id }}">{% if s.status == 'failed' %}<span>⚠️ nepodařilo se – {{ s.message }}</span>{% elif s.status == 'rendering' %}<span><span class="spin" style="display:inline-block;vertical-align:middle;width:18px;height:18px;margin-right:.4rem"></span>vytváří se… {{ s.progress }} %{% if s.eta_at %} · hotovo ~{{ s.eta_at }}{% endif %}</span>{% else %}<span>čeká ve frontě{% if s.eta_at %} · hotovo ~{{ s.eta_at }}{% endif %}</span>{% endif %}</a>{% endif %}
<div class="b"><div class="title">{{ s.title or s.name }}{% if s.auto %} <span class="badge ok">auto</span>{% endif %}{% if s.yt_status == 'done' %} <a class="badge info" href="{{ s.yt_url }}" target="_blank" rel="noopener">▶ YouTube</a>{% elif s.yt_status in ('queued', 'uploading') %} <span class="badge info">nahrává se na YouTube</span>{% elif s.yt_status == 'failed' %} <span class="badge err">YouTube selhalo</span>{% endif %}</div>
<dl class="facts"><dt>Kamera</dt><dd>{{ s.camera_label }}</dd><dt>Úpravy</dt><dd>{{ s.speed }}×{% if s.intro %} · intro{% endif %}{% if s.music %} · hudba{% endif %}{% if s.text %} · text{% endif %}</dd><dt>Vytvořeno</dt><dd>{{ s.created|czdt }}</dd></dl>
<div class="acts"><a class="btn small" href="/studio/v/{{ s.id }}">Otevřít</a>{% if s.ready %}<a class="btn small sec" href="/studio/v/{{ s.id }}/download">⬇ Stáhnout</a>{% endif %}
<form method="post" action="/studio/v/{{ s.id }}/delete" onsubmit="return confirm('Smazat video ze studia?')"><button class="btn small sec">Smazat</button></form></div></div></div>{% endfor %}
</div>
<div class="section-head" style="margin-top:1.2rem"><h2>Vystřižené záznamy</h2><span class="hint">v původní rychlosti, tak jak je vystřihl Frigate</span></div>
{% if not videos %}<div class="card"><p>Zatím žádné video. Otevři detekci v <a href="/history">Historii</a> a klikni na <b>Vytvořit video</b> – vybereš, kolik minut před a po snímku se má vystřihnout.</p></div>{% endif %}
<div class="gallery videos">
{% for v in videos %}<div class="shot video" id="v{{ v.id }}">
{% if v.ready %}<a class="thumb" href="/videos/{{ v.id }}/play.mp4" onclick="return swPlayVideo(this.href, this.dataset.title)" data-title="{{ v.name }}"><img src="{% if v.thumb %}/videos/{{ v.id }}/thumb.jpg{% endif %}" alt="" loading="lazy" onerror="this.style.visibility='hidden'"><span class="play">▶</span><span class="dur">{{ v.duration_h }}</span></a>
{% else %}<div class="thumb wait">{% if v.expired %}<span>⚠️ nedokončeno a záznam z té doby už je smazaný – video nejde vytvořit, smaž ho</span>{% elif v.stuck %}<span>⚠️ zaseklo se – Frigate export nedokončil (restart uprostřed)</span>{% elif v.in_progress %}<span><span class="spin" style="display:inline-block;vertical-align:middle;width:18px;height:18px;margin-right:.4rem"></span>vytváří se…</span>{% elif v.missing %}video už není k dispozici{% else %}čekám na Frigate…{% endif %}</div>{% endif %}
<div class="b">
<div class="title">{{ v.name }}{% if v.auto %} <span class="badge ok" title="Vytvořeno automaticky po upozornění">auto</span>{% endif %}</div>
<dl class="facts">
<dt>Kamera</dt><dd>{{ cam(v.camera) }}</dd>
<dt>Úsek</dt><dd>{{ v.range_h }} <span class="hint">({{ v.duration_h }})</span></dd>
<dt>Velikost</dt><dd>{% if v.size_h %}{{ v.size_h }}{% else %}–{% endif %}</dd>
<dt>Vytvořeno</dt><dd>{{ v.created|czdt }}</dd>
<dt>Smaže se</dt><dd>{% if v.days_left > 1 %}za {{ v.days_left }} dní{% elif v.days_left == 1 %}zítra{% else %}dnes{% endif %}</dd>
</dl>
<div class="acts">{% if v.ready %}<a class="btn small" href="/videos/{{ v.id }}/play.mp4" onclick="return swPlayVideo(this.href, this.dataset.title)" data-title="{{ v.name }}">▶ Přehrát</a><a class="btn small" href="/studio/new/{{ v.id }}" title="Zrychlit, přidat intro, text a hudbu">⏩ Studio</a><a class="btn small sec" href="/videos/{{ v.id }}/download">⬇ Stáhnout MP4</a>{% endif %}{% if v.stuck and not v.expired %}<form method="post" action="/videos/{{ v.id }}/retry"><button class="btn small" data-busy="Zadávám video znovu">↻ Vytvořit znovu</button></form>{% endif %}{% if v.detection_id %}<a class="btn small sec" href="/detection/{{ v.detection_id }}">Detekce</a>{% endif %}
<form method="post" action="/videos/{{ v.id }}/delete" onsubmit="return confirm('Smazat video {{ v.name }}?')"><button class="btn small sec">Smazat</button></form></div></div></div>{% endfor %}
</div>
<div class="card" style="margin-top:1rem"><form method="post" action="/videos/keep" class="row" style="align-items:end"><div style="max-width:220px"><label>Videa mazat po (dní)</label><input type="number" name="days" min="1" max="365" value="{{ keep_days }}"></div><div style="flex:0"><button class="btn small">Uložit</button></div>
<div class="hint" style="flex-basis:100%">Vystřižená videa leží na disku pro záznamy (složka exports) a po této době se automaticky smažou – stažené kopie v počítači to neovlivní.</div></form></div>
{% if (videos and videos|selectattr('in_progress')|list) or (studio and studio|rejectattr('ready')|selectattr('status', 'in', ('queued', 'rendering'))|list) %}<div x-data="autorefresh(20)"></div>{% endif %}
{% endblock %}"""

TEMPLATES["history.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small" href="/ai#kamery">⚙ Nastavení AI</a><form method="post" action="/history/delete" data-nobusy style="display:flex;gap:.4rem"><input type="hidden" name="camera" value="{{ f_cam }}"><button class="btn small sec" name="what" value="errors">Smazat chybná</button><button class="btn small danger" name="what" value="all" onclick="return confirm('Smazat celou historii{% if f_cam %} kamery {{ cam(f_cam) }}{% endif %} včetně snímků?')">Smazat vše{% if f_cam %} ({{ cam(f_cam) }}){% endif %}</button></form></div>{% endblock %}{% block content %}
{% macro link(cam_, min_, show_, page_=1) %}/history?camera={{ cam_ }}&min_score={{ min_ }}&show={{ show_ }}{% if page_ > 1 %}&page={{ page_ }}{% endif %}{% endmacro %}
<div class="filters">
 <div class="fgroup"><span class="fl">Zobrazit</span><span class="seg"><a class="{{ 'on' if f_show=='notified' }}" href="{{ link(f_cam, f_min, 'notified') }}">S upozorněním</a><a class="{{ 'on' if f_show=='all' }}" href="{{ link(f_cam, f_min, 'all') }}">Všechna hodnocení</a><a class="{{ 'on' if f_show=='errors' }}" href="{{ link(f_cam, f_min, 'errors') }}">Chyby</a></span></div>
 <div class="fgroup"><span class="fl">Kamera</span><span class="seg"><a class="{{ 'on' if not f_cam }}" href="{{ link('', f_min, f_show) }}">Všechny</a>{% for c in cameras %}<a class="{{ 'on' if c==f_cam }}" href="{{ link(c, f_min, f_show) }}">{{ cam(c) }}</a>{% endfor %}</span></div>
 <div class="fgroup"><span class="fl">Skóre</span><span class="seg"><a class="{{ 'on' if not f_min }}" href="{{ link(f_cam, 0, f_show) }}">vše</a>{% for m in (5, 7, 8, 9) %}<a class="{{ 'on' if f_min==m }}" href="{{ link(f_cam, m, f_show) }}">{{ m }}+</a>{% endfor %}</span></div>
 <span class="hint" style="margin-left:auto">{{ total }} záznamů · {{ per_page }} na stránku · historie se maže po {{ keep_days }} dnech</span>
</div>
{% set ns = namespace(day='') %}
{% for e in rows %}{% set d = e.ts|czdate %}{% if d != ns.day %}{% set ns.day = d %}<h2 class="day">{{ d }}</h2>{% endif %}
<article class="hrow {{ 'err' if e.error else ('hit' if e.notified else '') }}">
 {% if e.image %}<a class="pic" href="{% if not e.error %}/detection/{{ e.id }}{% else %}/snapshot/{{ e.image }}{% endif %}" {% if e.error %}data-lightbox="history"{% endif %}><img src="/snapshot/{{ e.image }}" alt="" loading="lazy"></a>{% endif %}
 <div class="tx">
  <div class="hd"><span class="score {{ 'err' if e.error else ('ok' if e.score >= rule(e.camera).threshold else ('mid' if e.score >= 5 else 'low')) }}">{% if e.error %}chyba{% else %}{{ e.score }}<small>/10</small>{% endif %}</span><span class="when">{{ e.ts|cztime }}</span><b>{{ cam(e.camera) }}</b>{% if e.phenomenon %}<span class="ph">{{ e.phenomenon }}</span>{% endif %}
   {% if e.notified %}<span class="badge ok">upozorněno</span>{% elif not e.error and e.score >= rule(e.camera).threshold %}<span class="badge info">v epizodě</span>{% endif %}{% if e.exported %}<a class="badge info" href="/videos" title="Z této detekce je vystřižené video">🎬 video</a>{% endif %}</div>
  <p class="desc">{{ e.description or e.error or '–' }}</p>
  {% if e.note %}<div class="hint">{{ e.note }}</div>{% endif %}
 </div>
 <div class="ac">{% if not e.error %}<a class="btn small sec" href="/detection/{{ e.id }}">Detail a video</a>{% else %}<form method="post" action="/detection/{{ e.id }}/delete" data-nobusy><button class="btn small sec">Smazat</button></form>{% endif %}</div>
</article>
{% endfor %}
{% if not rows %}<div class="card"><p class="hint" style="margin:0">Nic k zobrazení{% if f_show == 'notified' %} – zkus <a href="{{ link(f_cam, f_min, 'all') }}">všechna hodnocení</a>{% endif %}.</p></div>{% endif %}
{% if pages > 1 %}<nav class="pager">
 <a class="btn small sec {{ 'dis' if page <= 1 }}" href="{{ link(f_cam, f_min, f_show, page - 1) }}">‹ Novější</a>
 <span class="pages">{% for p in range(1, pages + 1) %}{% if p == 1 or p == pages or (p >= page - 2 and p <= page + 2) %}<a class="{{ 'on' if p == page }}" href="{{ link(f_cam, f_min, f_show, p) }}">{{ p }}</a>{% elif p == page - 3 or p == page + 3 %}<span>…</span>{% endif %}{% endfor %}</span>
 <a class="btn small sec {{ 'dis' if page >= pages }}" href="{{ link(f_cam, f_min, f_show, page + 1) }}">Starší ›</a>
</nav>{% endif %}
{% endblock %}"""

TEMPLATES["studio_new.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/videos">← Videa</a><a class="btn small sec" href="/studio/settings">⚙ Nastavení studia</a></div>{% endblock %}{% block content %}
{% set intro_sec = (sc.intro_seconds if intro and intro.suffix|lower in ('.png', '.jpg', '.jpeg') else 0) %}
<form method="post" x-data="{intro: {{ 'true' if values.intro and intro else 'false' }}, textOn: {{ 'true' if values.text_on else 'false' }}}">
<div class="grid-2" style="grid-template-columns:minmax(0,3fr) minmax(320px,2fr)">
<div>
 <div class="card studio-src"><a class="thumb" href="/videos/{{ export.id }}/play.mp4" onclick="return swPlayVideo(this.href, this.dataset.title)" data-title="{{ export.name }}"><img src="/videos/{{ export.id }}/thumb.jpg" alt="" onerror="this.style.visibility='hidden'"><span class="play">▶</span></a>
  <div><div class="hint">Zdrojové video</div><b>{{ export.name }}</b><div class="hint">{{ cam(export.camera) }} · záznam {{ vars.delka }}{% if src.width %} · {{ src.width }}×{{ src.height }}{% endif %}</div></div></div>

 <div class="card" x-data="speedPreview('/videos/{{ export.id }}/play.mp4', {{ values.speed }})"><h2>1. Rychlost</h2>
  <div class="speed-pick"><button type="button" class="btn small sec" @click="speed = Math.max(10, speed - 10)">−10</button><input type="range" name="speed" min="10" max="240" step="10" x-model.number="speed" list="speed-ticks"><button type="button" class="btn small sec" @click="speed = Math.min(240, speed + 10)">+10</button><b class="speed-val" x-text="speed + '×'"></b></div>
  <datalist id="speed-ticks">{% for s in speeds %}<option value="{{ s }}"></option>{% endfor %}</datalist>
  <p class="hint" style="margin:.6rem 0 0">Ze záznamu dlouhého <b>{{ vars.delka }}</b> vznikne video dlouhé <b x-text="fmt({{ '%.1f'|format(src.duration or 0) }} / speed)"></b>; vytvoření potrvá <b x-text="eta({{ '%.1f'|format(src.duration or 0) }}, {{ '%.1f'|format(src.fps or 25) }}, {{ src.width or 1920 }})"></b> (odhad). Doporučení: západ slunce 20–30×, celý den 120–240×.</p>
  <div class="speed-preview" :class="{open: on}">
   <button type="button" class="btn small sec" x-show="!on" @click="play(speed)">▶ Ukázat, jak bude video rychlé</button>
   <div x-show="on" x-cloak>
    <video x-ref="v" muted playsinline preload="metadata" poster="/videos/{{ export.id }}/thumb.jpg" @click="running || !video.paused ? stop() : play(speed)"></video>
    <div class="row" style="align-items:center;margin-top:.4rem"><span class="hint">Náhled zdroje <b x-text="speed + '×'"></b> · <span x-text="pos"></span> · kliknutím na obraz zastavíš / spustíš. Náhled u vyšších rychlostí trochu poskakuje – hotové video bude plynulé (30 sn./s).</span><button type="button" class="btn small sec" @click="stop(); on = false">Zavřít náhled</button></div>
   </div>
  </div></div>

 <div class="card"><h2>2. Intro</h2>
  {% if intro %}<label class="check"><input type="checkbox" name="intro" value="1" x-model="intro">Přidat intro na začátek <span class="hint">({{ intro.name }}{% if intro_sec %}, {{ intro_sec|int }} s{% endif %})</span></label>
  {% else %}<p class="hint" style="margin:0">Zatím nemáš nahrané žádné intro – nahraj ho v <a href="/studio/settings">Nastavení studia</a> (video MP4 nebo obrázek s logem).</p>{% endif %}</div>

 <div class="card"><h2>3. Text v obraze</h2>
  <label class="check"><input type="checkbox" name="text_on" value="1" x-model="textOn">Vypsat text do videa</label>
  <div x-show="textOn"><input type="text" name="text" value="{{ values.text }}" maxlength="200" placeholder="{kamera} · {datum} · {rychlost}×">
  <div class="hint">Zástupné značky: <code>{kamera}</code> <code>{datum}</code> <code>{cas}</code> <code>{jev}</code> <code>{skore}</code> <code>{rychlost}</code>. Umístění a velikost písma nastavíš v Nastavení studia.{% if not font %} <b>Na RPi chybí font – text se nepřidá</b> (nainstaluj balíček fonts-dejavu-core).{% endif %}</div></div></div>

 <div class="card" x-data="musicFinder('{{ values.music }}')"><h2>4. Hudba</h2>
  <select name="music" x-model="music" x-ref="sel"><option value="">bez hudby</option>{% for m in music %}<option value="{{ m.name }}">{{ m.name }}{% if m.duration %} ({{ (m.duration // 60)|int }}:{{ '%02d'|format(m.duration % 60) }}){% endif %}</option>{% endfor %}</select>
  <p class="hint" style="margin:.4rem 0 .6rem">Hudba začne až po intru, plynule zesílí a na konci ztichne ({{ sc.fade_in }} s / {{ sc.fade_out }} s); kratší skladba se opakuje. Do popisu videa se automaticky přidá autor skladby.</p>
  <details class="finder" :open="open" @toggle="open = $el.open"><summary>🔎 Najít hudbu k tomuto videu (Openverse – volně použitelná, CC0 / CC BY)</summary>
   <div class="row" style="margin-top:.5rem;align-items:end"><div><input type="text" x-model="q" @keydown.enter.prevent="search()" placeholder="např. calm piano, sunset, ambient…"></div>
    <div style="flex:0 0 auto;min-width:0"><select x-model="len" style="width:auto"><option value="">libovolná délka</option><option value="short">do 2 min</option><option value="medium">2–10 min</option><option value="long">nad 10 min</option></select></div>
    <button type="button" class="btn small" style="flex:0 0 auto" @click="search()" :disabled="busy">Hledat</button></div>
   <div class="chips">{% for lbl, qq in quick %}<span class="chip" @click="q = '{{ qq }}'; search()">{{ lbl }}</span>{% endfor %}</div>
   <p class="hint" x-show="msg" x-text="msg"></p>
   <div class="tracks" x-show="items.length">
    <template x-for="t in items" :key="t.id"><div class="track">
     <audio controls preload="none" :src="t.url"></audio>
     <div class="tx"><b x-text="t.title"></b> <span class="hint" x-text="(t.creator ? t.creator + ' · ' : '') + (t.duration_h ? t.duration_h + ' · ' : '') + t.license + (t.genres ? ' · ' + t.genres : '')"></span></div>
     <button type="button" class="btn small" @click="use(t)" :disabled="busy" x-text="t.name ? '✓ Vybráno' : 'Použít'"></button>
    </div></template>
   </div>
  </details></div>
</div>
<div>
 <div class="card"><h2>Titulek a popis</h2>
  <div x-data="titleIdeas({vid: {{ export.id }}})"><label>Titulek <span class="hint">(název souboru a titulek na YouTube)</span></label><input type="text" name="title" value="{{ values.title }}" maxlength="100" x-ref="title">
  <div class="ideas"><button type="button" class="btn small sec" @click="ask(document.querySelector('input[name=speed]') ? document.querySelector('input[name=speed]').value : 20)" :disabled="busy" x-text="busy ? 'AI přemýšlí…' : '✨ Navrhnout titulek (AI)'"></button><span class="hint" x-text="msg"></span>
   <div class="chips" x-show="titles.length"><template x-for="t in titles" :key="t"><span class="chip" @click="$refs.title.value = t; msg = 'Vloženo.'" x-text="t"></span></template></div></div></div>
  <label>Popis</label><textarea name="description" rows="8">{{ values.description }}</textarea>
  <div class="hint">Předvyplněno z textu AI a šablon v nastavení – klidně přepiš. Upravit půjde i u hotového videa.</div></div>
 <div class="savebar"><button class="btn" data-busy="Zařazuji do fronty">🎬 Vytvořit video</button><span class="hint">Nikam se nic nenahrává – nejdřív uvidíš výsledek.</span></div>
</div></div>
</form>
{% endblock %}"""

TEMPLATES["studio_video.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/videos#studio">← Videa</a><a class="btn small sec" href="/studio/new/{{ v.export_id }}?again={{ v.id }}">↻ Vytvořit jinak</a></div>{% endblock %}{% block content %}
<div class="grid-2" style="grid-template-columns:minmax(0,3fr) minmax(320px,2fr)">
<div>
 <div class="card" style="padding:0;overflow:hidden">
 {% if v.ready %}<video controls preload="metadata" playsinline style="width:100%;display:block;background:#000;aspect-ratio:16/9" poster="{% if v.thumb %}/studio/v/{{ v.id }}/thumb.jpg{% endif %}" src="/studio/v/{{ v.id }}/play.mp4"></video>
 {% else %}<div class="studio-wait">
  {% if v.status == 'failed' %}<div class="badge err">nepodařilo se</div><p>{{ v.message or 'neznámá chyba' }}</p><a class="btn small" href="/studio/new/{{ v.export_id }}?again={{ v.id }}">Zkusit znovu</a>
  {% elif v.status == 'rendering' %}<div class="spin"></div><p><b>Vytváří se…</b> {{ v.progress }} %</p><div class="pbar"><i style="width:{{ v.progress }}%"></i></div>{% if v.eta_s %}<p class="eta"><span x-data="countdown({{ v.eta_s }})" x-text="txt"></span> · hotovo asi v <b>{{ v.eta_at }}</b></p>{% endif %}<p class="hint">Zrychlení {{ v.speed }}× – odhad se zpřesňuje během práce. Stránka se sama obnovuje.</p>
  {% else %}<div class="spin"></div><p><b>Čeká ve frontě</b>{% if queue_pos %} · před ním {{ queue_pos }}{% endif %}</p>{% if v.eta_s %}<p class="eta"><span x-data="countdown({{ v.eta_s }})" x-text="txt"></span> · hotovo asi v <b>{{ v.eta_at }}</b></p>{% endif %}<p class="hint">Videa se vyrábějí po jednom, aby RPi zvládalo nahrávat.</p>{% endif %}
 </div>{% endif %}</div>
 {% if v.message and v.status == 'ready' %}<div class="card warn"><b>Poznámka:</b> {{ v.message }}</div>{% endif %}
 <div class="card"><dl class="facts">
  <dt>Zdroj</dt><dd>{{ v.name }} <a class="hint" href="/videos#v{{ v.export_id }}">(původní video)</a></dd>
  <dt>Kamera</dt><dd>{{ v.camera_label }}</dd>
  <dt>Rychlost</dt><dd>{{ v.speed }}×</dd>
  <dt>Intro</dt><dd>{{ 'ano' if v.intro else 'ne' }}</dd>
  <dt>Hudba</dt><dd>{{ v.music or 'bez hudby' }}</dd>
  <dt>Text v obraze</dt><dd>{{ v.text or '–' }}</dd>
  {% if v.ready %}<dt>Délka · velikost</dt><dd>{{ v.duration_h }} · {{ v.size_h }}</dd>{% endif %}
  <dt>Vytvořeno</dt><dd>{{ v.created|czdt }}{% if v.auto %} <span class="badge ok">automaticky</span>{% endif %}</dd>
 </dl></div>
</div>
<div>
 <form method="post" action="/studio/v/{{ v.id }}/meta" class="card" x-data="titleIdeas({sid: {{ v.id }}})"><h2>Titulek a popis</h2>
  <label>Titulek</label><input type="text" name="title" value="{{ v.title }}" maxlength="100" x-ref="title">
  <div class="ideas"><button type="button" class="btn small sec" @click="ask()" :disabled="busy" x-text="busy ? 'AI přemýšlí…' : '✨ Navrhnout titulek (AI)'"></button><span class="hint" x-text="msg"></span>
   <div class="chips" x-show="titles.length"><template x-for="t in titles" :key="t"><span class="chip" @click="$refs.title.value = t; msg = 'Vloženo – nezapomeň Uložit.'" x-text="t"></span></template></div></div>
  <label>Popis</label><textarea name="description" rows="9">{{ v.description }}</textarea>
  <div class="row" style="margin-top:.6rem"><button class="btn small">Uložit</button></div></form>
 <div class="card"><h2>Co dál</h2>
  <div class="acts studio-acts">{% if v.ready %}<a class="btn" href="/studio/v/{{ v.id }}/download">⬇ Stáhnout MP4</a>{% endif %}
  <form method="post" action="/studio/v/{{ v.id }}/delete" onsubmit="return confirm('Smazat toto video ze studia? Původní vystřižené video zůstane.')"><button class="btn small sec">Smazat</button></form></div>
  <p class="hint" style="margin:.6rem 0 0">Původní vystřižené video zůstává ve Videích; smazání tady se ho netýká.</p></div>
 <div class="card" id="youtube"><h2>▶ YouTube</h2>
 {% if v.yt_status == 'done' and v.yt_url %}<p><span class="badge ok">nahráno</span> <a href="{{ v.yt_url }}" target="_blank" rel="noopener"><b>{{ v.yt_url }}</b></a></p><p class="hint">Titulek, popis, viditelnost i playlist můžeš dál upravit přímo na YouTube (YouTube Studio).</p>
  <form method="post" action="/studio/v/{{ v.id }}/cleanup" class="cleanup" onsubmit="return confirm('Smazat z RPi vybrané položky? Video na YouTube zůstane.')">
   <h3>Uklidit z RPi</h3>
   <label class="check"><input type="checkbox" checked disabled>Toto video ze studia ({{ v.size_h }})</label>
   <label class="check"><input type="checkbox" name="source" value="1" checked>Vystřižený klip (zdroj, ve Videích)</label>
   <label class="check"><input type="checkbox" name="detection" value="1">Detekci AI včetně snímku (z historie)</label>
   <div class="row" style="align-items:center"><button class="btn small sec">🗑 Smazat z RPi</button><span class="hint">Video je bezpečně na YouTube – uvolní se místo na disku.</span></div>
  </form>
 {% elif v.yt_status in ('queued', 'uploading') %}<p><span class="spin" style="display:inline-block;vertical-align:middle;width:18px;height:18px;margin-right:.4rem"></span><b>{% if v.yt_status == 'queued' %}Čeká na nahrání…{% else %}Nahrávám… {{ v.yt_progress }} %{% endif %}</b></p><div class="pbar"><i style="width:{{ v.yt_progress }}%"></i></div>{% if v.yt_eta_s %}<p class="eta"><span x-data="countdown({{ v.yt_eta_s }})" x-text="txt"></span> · na YouTube asi v <b>{{ v.yt_eta_at }}</b></p>{% endif %}<form method="post" action="/studio/v/{{ v.id }}/youtube/reset" data-nobusy style="margin-top:.5rem"><button class="btn small sec">Zrušit</button></form>
 {% elif not yt_linked %}<p class="hint">YouTube ještě není propojený. Nastavíš to jednou v <a href="/studio/settings#youtube">Nastavení → Video studio → YouTube</a> (průvodce krok za krokem).</p>
 {% elif not v.ready %}<p class="hint">Až bude video hotové, půjde nahrát.</p>
 {% else %}{% if v.yt_status == 'failed' %}<p><span class="badge err">nepodařilo se</span> {{ v.yt_error }}</p>{% endif %}
  <form method="post" action="/studio/v/{{ v.id }}/youtube" x-data="{pl: '{{ yt.playlist_id or '' }}'}">
   <div class="hint">Kanál <b>{{ yt.channel_title }}</b>. Na YouTube jde titulek a popis z rámečku nahoře – pokud jsi je změnil, nejdřív je <b>Ulož</b>.</div>
   <div class="row" style="margin-top:.5rem"><div><label>Viditelnost</label><select name="privacy">{% for k, l in yt_privacy.items() %}<option value="{{ k }}"{% if (yt.privacy or 'unlisted') == k %} selected{% endif %}>{{ l }}</option>{% endfor %}</select></div>
   <div><label>Playlist</label><select name="playlist_id" x-model="pl"><option value="">bez playlistu</option>{% for p in yt.playlists or [] %}<option value="{{ p.id }}">{{ p.title }}</option>{% endfor %}<option value="__new__">＋ nový playlist…</option></select></div></div>
   <div x-show="pl === '__new__'" x-cloak><label>Název nového playlistu</label><input type="text" name="playlist_new" placeholder="např. Západy slunce – Sehradice"></div>
   <div class="row" style="margin-top:.6rem;align-items:center"><button class="btn" data-busy="Zařazuji k nahrání">▶ Nahrát na YouTube</button><span class="hint">Nahrání spotřebuje kousek denní kvóty YouTube API (vejde se ~6 videí denně).</span></div>
  </form>{% endif %}</div>
</div></div>
{% if v.status in ('queued', 'rendering') or v.yt_status in ('queued', 'uploading') %}<div x-data="autorefresh(8)"></div>{% endif %}
{% endblock %}"""

TEMPLATES["studio_settings.html"] = """{% extends "base.html" %}{% block actions %}<div class="actions"><a class="btn small sec" href="/videos">🎬 Videa</a></div>{% endblock %}{% block content %}
<div class="guide"><b>Jak studio funguje:</b> vystřižené video ze Záznamů (ručně z detekce nebo automaticky po upozornění) se zrychlí, případně dostane intro, text v obraze a hudbu. Výsledek si prohlédneš, upravíš titulek s popisem a stáhneš – v příští verzi ho jedním kliknutím nahraješ na YouTube.</div>
<div class="grid-2">
<div>
 <div class="card"><h2>Intro (úvodní znělka)</h2>
 {% if intro %}<div class="studio-intro">{% if intro_is_image %}<img src="/studio/asset/intro" alt="">{% else %}<video src="/studio/asset/intro" controls muted playsinline preload="metadata"></video>{% endif %}
  <div><b>{{ intro.name }}</b><div class="hint">{% if intro_is_image %}obrázek – ve videu {{ sc.intro_seconds|int }} s{% if sc.intro_title %} s názvem kamery a datem{% endif %}{% else %}video{% if intro_info.duration %} · {{ '%.0f'|format(intro_info.duration) }} s{% endif %}{% if intro_info.width %} · {{ intro_info.width }}×{{ intro_info.height }}{% endif %}{% endif %}</div>
  <form method="post" action="/studio/upload/intro/delete" onsubmit="return confirm('Odstranit intro?')" data-nobusy style="margin-top:.4rem"><button class="btn small sec">Odstranit</button></form></div></div>
 {% else %}<p class="hint">Zatím žádné intro. Může to být krátké video (MP4, do 15 s se použije celé) nebo jen obrázek s logem (PNG/JPG) – z něj Atmovio udělá úvod s názvem kamery a datem.</p>{% endif %}
 <form method="post" action="/studio/upload/intro" enctype="multipart/form-data" class="row" style="align-items:end;margin-top:.6rem"><div><label>{{ 'Nahradit' if intro else 'Nahrát' }} intro (MP4/MOV do 100 MB, nebo PNG/JPG)</label><input type="file" name="file" accept=".mp4,.mov,.m4v,.png,.jpg,.jpeg" required></div><button class="btn small" data-busy="Nahrávám intro">Nahrát</button></form></div>

 <div class="card"><h2>Hudba</h2>
 {% if music %}<div class="plainlist">{% for m in music %}<div class="studio-music"><audio controls preload="none" src="/studio/asset/music/{{ m.name }}"></audio><div><b>{{ m.name }}</b>{% if sc.music_default == m.name %} <span class="badge ok">výchozí</span>{% endif %}{% if m.meta %} <span class="badge info">{{ m.meta.license }}</span>{% endif %}<div class="hint">{{ m.size_h }}{% if m.duration %} · {{ (m.duration // 60)|int }}:{{ '%02d'|format(m.duration % 60) }}{% endif %}{% if m.meta %} · {{ m.meta.creator }} · Openverse{% endif %}</div></div>
  <form method="post" action="/studio/upload/music/delete" onsubmit="return confirm('Odstranit tuto hudbu?')" data-nobusy><input type="hidden" name="name" value="{{ m.name }}"><button class="btn small sec">Odstranit</button></form></div>{% endfor %}</div>
 {% else %}<p class="hint">Zatím žádná hudba. Nahraj MP3 (nebo M4A/WAV/OGG/FLAC) – u každého videa pak vybereš, která se použije.</p>{% endif %}
 <form method="post" action="/studio/upload/music" enctype="multipart/form-data" class="row" style="align-items:end;margin-top:.6rem"><div><label>Přidat vlastní hudbu (do 40 MB)</label><input type="file" name="file" accept=".mp3,.m4a,.aac,.wav,.ogg,.flac" required></div><button class="btn small" data-busy="Nahrávám hudbu">Nahrát</button></form>
 <p class="hint" style="margin:.6rem 0 0">Vlastní hudbu nahrávej jen s právy k ní (YouTube cizí skladby ztlumí nebo zablokuje). Hudbu z Openverse hledáš přímo u každého videa v Studiu – je pod licencí CC0 / CC BY a autor se do popisu doplní sám.</p></div>

 <div class="card" id="youtube" x-data="ytLink({{ 'true' if link_active else 'false' }})"><h2>▶ YouTube – propojení kanálu</h2>
 {% if yt.refresh_token %}
  <p><span class="badge ok">propojeno</span> kanál <b>{{ yt.channel_title or '?' }}</b>{% if yt.linked %} <span class="hint">· {{ yt.linked|czdt }}</span>{% endif %} · {{ (yt.playlists or [])|length }} playlistů</p>
  <form method="post" action="/studio/youtube/defaults">
   <div class="row"><div><label>Výchozí viditelnost</label><select name="privacy">{% for k, l in yt_privacy.items() %}<option value="{{ k }}"{% if (yt.privacy or 'unlisted') == k %} selected{% endif %}>{{ l }}</option>{% endfor %}</select></div>
   <div><label>Výchozí playlist</label><select name="playlist_id"><option value="">bez playlistu</option>{% for p in yt.playlists or [] %}<option value="{{ p.id }}"{% if yt.playlist_id == p.id %} selected{% endif %}>{{ p.title }}</option>{% endfor %}</select></div></div>
   <label>Štítky (oddělené čárkou)</label><input type="text" name="tags" value="{{ yt.tags }}" maxlength="400">
   <label class="check"><input type="checkbox" name="auto" value="1"{% if yt.auto %} checked{% endif %}>Automatická videa po upozornění rovnou nahrát na YouTube (s touto viditelností a playlistem)</label>
   <div class="hint">Automatika nahraje jen videa, která vznikla automaticky (Automatika ve studiu musí být zapnutá). Ručně vytvořená videa nahraješ tlačítkem u videa.</div>
   <div class="row" style="margin-top:.6rem"><button class="btn small">Uložit</button></div></form>
  <div class="row" style="margin-top:.8rem"><form method="post" action="/studio/youtube/playlists" data-nobusy><button class="btn small sec">↻ Načíst playlisty</button></form>
   <form method="post" action="/studio/youtube/link" data-nobusy><button class="btn small sec" title="Např. pro jiný kanál nebo brand účet">Propojit znovu / jiný kanál</button></form>
   <form method="post" action="/studio/youtube/unlink" onsubmit="return confirm('Odpojit YouTube? Videa na YouTube zůstanou.')" data-nobusy><button class="btn small sec">Odpojit</button></form></div>
 {% else %}
  <div class="guide"><div><b>Jednorázové nastavení (asi 10 minut).</b> Google nedovolí Atmovio nahrávat na tvůj kanál bez vlastního „klíče aplikace“ – vytvoříš ho zdarma v Google Cloud Console. Postup krok za krokem je i v <a href="https://github.com/{{ github_repo }}/blob/main/docs/youtube.md" target="_blank" rel="noopener">dokumentaci</a>.</div></div>
  <ol class="steps">
   <li>Otevři <a href="https://console.cloud.google.com/projectcreate" target="_blank" rel="noopener">console.cloud.google.com/projectcreate</a>, projekt pojmenuj třeba <b>Atmovio</b> a vytvoř ho (přihlášený účtem, který má YouTube kanál).</li>
   <li>Zapni <a href="https://console.cloud.google.com/apis/library/youtube.googleapis.com" target="_blank" rel="noopener">YouTube Data API v3</a> (tlačítko <b>Povolit / Enable</b>).</li>
   <li>Obrazovka souhlasu: <a href="https://console.cloud.google.com/auth/overview" target="_blank" rel="noopener">Google Auth platform → Začínáme</a>: název aplikace <b>Atmovio</b>, tvůj e-mail, typ <b>Externí</b>, kontaktní e-mail, souhlas → Vytvořit.
    Potom otevři <a href="https://console.cloud.google.com/auth/branding" target="_blank" rel="noopener"><b>Branding</b></a>, doplň, co je označené jako povinné (název aplikace, e-mail podpory, kontaktní e-mail vývojáře) a ulož – teprve pak jde v <a href="https://console.cloud.google.com/auth/audience" target="_blank" rel="noopener"><b>Audience</b></a> kliknout na <b>Publish app</b> (potvrď). Bez publikování by propojení platilo jen 7 dní.
    <span class="hint">Když Publish nejde, je to vždy kvůli nevyplněnému Brandingu. Nouzová cesta: v Audience → Test users přidej svůj e-mail – propojení pak funguje, ale po 7 dnech ho musíš obnovit.</span></li>
   <li><a href="https://console.cloud.google.com/auth/clients/create" target="_blank" rel="noopener">Vytvoř klienta</a>: typ <b>Televize a zařízení s omezeným vstupem</b>, název <b>Atmovio</b> → Vytvořit. Zobrazí se <b>Client ID</b> a <b>Client secret</b> – zkopíruj je sem:</li>
  </ol>
  <form method="post" action="/studio/youtube/client">
   <div class="row"><div><label>Client ID</label><input type="text" name="client_id" value="{{ yt.client_id }}" placeholder="xxxxxxxx.apps.googleusercontent.com" required></div>
   <div><label>Client secret</label><input type="password" name="client_secret" value="{{ yt.client_secret }}" placeholder="GOCSPX-…"{% if not yt.client_secret %} required{% endif %}></div></div>
   <div class="row" style="margin-top:.5rem"><button class="btn small">Uložit klíče</button></div></form>
  {% if yt.client_id and yt.client_secret %}
  <div style="margin-top:.9rem" x-show="!st.status"><form method="post" action="/studio/youtube/link" data-nobusy><button class="btn">▶ Propojit YouTube</button></form>
   <div class="hint">Klikneš, dostaneš krátký kód, zadáš ho na google.com/device, vybereš kanál a povolíš. Hotovo.</div></div>
  <div x-show="st.status === 'waiting'" x-cloak class="yt-code"><div class="hint">1. Otevři <a :href="st.url" target="_blank" rel="noopener" x-text="st.url"></a></div><div class="hint">2. Zadej tento kód:</div><div class="code" x-text="st.user_code"></div><div class="hint">3. Vyber kanál (nebo brand účet) a klikni na <b>Povolit</b>. Tahle stránka se pak sama přepne. <span x-text="'Kód platí ještě ' + Math.floor(st.remaining / 60) + ' min.'"></span></div><p class="hint" x-show="st.error" x-text="st.error"></p></div>
  <div x-show="st.status === 'failed'" x-cloak><p><span class="badge err">nepodařilo se</span> <span x-text="st.error"></span></p><form method="post" action="/studio/youtube/link" data-nobusy><button class="btn small">Zkusit znovu</button></form></div>
  {% endif %}
 {% endif %}</div>

 <div class="card"><h2>Hledání hudby (Openverse)</h2>
 {% if ov.client_id %}<p>Atmovio je u Openverse zaregistrované (<b>{{ ov.email }}</b>, {{ ov.registered|czdt }}). Po kliknutí na potvrzovací odkaz z e-mailu není potřeba nic dalšího – hledání hudby u videí (Videa → ⏩ Studio → 4. Hudba) používá registraci automaticky. <span x-data="{r: ''}"><button type="button" class="btn small sec" @click="r = 'zkouším…'; fetch('/studio/music/search?q=piano').then(x => x.json()).then(d => r = d.error ? '✖ ' + d.error : '✓ hledání funguje (' + d.items.length + ' skladeb pro „piano“)').catch(() => r = '✖ nepodařilo se spojit')">Vyzkoušet hledání</button> <span class="hint" x-text="r"></span></span></p>
  <form method="post" action="/studio/openverse/forget" data-nobusy><button class="btn small sec">Zrušit registraci</button></form>
 {% else %}<p class="hint">Hledání funguje hned, ale anonymně jen pár dotazů za hodinu. Zadej e-mail, Atmovio se u Openverse samo zaregistruje (zdarma) a ty jen klikneš na potvrzovací odkaz v e-mailu.</p>
  <form method="post" action="/studio/openverse/register" class="row" style="align-items:end"><div><label>E-mail pro registraci</label><input type="email" name="email" required placeholder="tvuj@email.cz"></div><button class="btn small" data-busy="Registruji">Zaregistrovat</button></form>{% endif %}</div>
</div>
<div>
<form method="post" action="/studio/settings">
 <div class="card"><h2>Výchozí nastavení videa</h2>
  <label>Výchozí rychlost (po 10×)</label><div class="speed-pick" x-data="{s: {{ sc.speed }}}"><button type="button" class="btn small sec" @click="s = Math.max(10, s - 10)">−10</button><input type="range" name="speed" min="10" max="240" step="10" x-model.number="s"><button type="button" class="btn small sec" @click="s = Math.min(240, s + 10)">+10</button><b class="speed-val" x-text="s + '×'"></b></div>
  <label class="check" style="margin-top:.8rem"><input type="checkbox" name="intro" value="1"{% if sc.intro %} checked{% endif %}>Intro přidávat automaticky (když je nahrané)</label>
  <div class="row"><div><label>Intro z obrázku: délka (s)</label><input type="number" name="intro_seconds" min="1" max="15" step="0.5" value="{{ sc.intro_seconds }}"></div>
  <div><label>Text na intru z obrázku <span class="hint">(řádky = řádky ve videu)</span></label><textarea name="intro_text" rows="2" maxlength="200" style="min-height:0">{{ sc.intro_text }}</textarea></div></div>
  <label class="check"><input type="checkbox" name="intro_title" value="1"{% if sc.intro_title %} checked{% endif %}>Na intro z obrázku vypsat tento text (např. název kamery a datum)</label>
 </div>
 <div class="card"><h2>Text v obraze</h2>
  <label class="check"><input type="checkbox" name="text_enabled" value="1"{% if sc.text_enabled %} checked{% endif %}>Vypisovat text do videa</label>
  <input type="text" name="text" value="{{ sc.text }}" maxlength="200">
  <div class="row"><div><label>Umístění</label><select name="text_pos">{% for k, l in positions.items() %}<option value="{{ k }}"{% if sc.text_pos == k %} selected{% endif %}>{{ l }}</option>{% endfor %}</select></div>
  <div><label>Velikost písma</label><input type="number" name="text_size" min="16" max="96" value="{{ sc.text_size }}"></div></div>
  <div class="hint">Značky: <code>{kamera}</code> <code>{datum}</code> <code>{cas}</code> <code>{jev}</code> <code>{skore}</code> <code>{rychlost}</code> <code>{delka}</code>.{% if not font %} <b>Na RPi chybí font pro text – nainstaluj balíček fonts-dejavu-core</b> (aktualizace Atmovio ho doinstaluje).{% endif %}</div>
 </div>
 <div class="card"><h2>Hudba – hlasitost a prolínání</h2>
  <label>Výchozí skladba</label><select name="music_default"><option value="">bez hudby</option>{% for m in music %}<option value="{{ m.name }}"{% if sc.music_default == m.name %} selected{% endif %}>{{ m.name }}</option>{% endfor %}</select>
  <div class="row"><div><label>Hlasitost (0,1–2)</label><input type="number" name="music_volume" min="0.05" max="2" step="0.05" value="{{ sc.music_volume }}"></div>
  <div><label>Zesílení na začátku (s)</label><input type="number" name="fade_in" min="0" max="15" step="0.5" value="{{ sc.fade_in }}"></div>
  <div><label>Ztišení na konci (s)</label><input type="number" name="fade_out" min="0" max="15" step="0.5" value="{{ sc.fade_out }}"></div></div>
 </div>
 <div class="card"><h2>Obraz – rozjasnění a ztmavení</h2>
  <div class="row"><div><label>Rozjasnění ze tmy na začátku (s)</label><input type="number" name="video_fade_in" min="0" max="10" step="0.5" value="{{ sc.video_fade_in }}"></div>
  <div><label>Ztmavení na konci (s)</label><input type="number" name="video_fade_out" min="0" max="10" step="0.5" value="{{ sc.video_fade_out }}"></div></div>
  <div class="hint">Týká se zrychleného záznamu (ne intra). Hudba ztichne nejpozději se ztmavením obrazu.</div>
 </div>
 <div class="card"><h2>Šablona titulku a popisu</h2>
  <label>Titulek (šablona)</label><input type="text" name="title" value="{{ sc.title }}" maxlength="120">
  <label class="check"><input type="checkbox" name="ai_title" value="1"{% if sc.ai_title %} checked{% endif %}>U automatických videí nechat titulek navrhnout AI (poutavější než šablona; šablona je záloha)</label>
  <label>Popis</label><textarea name="description" rows="5">{{ sc.description }}</textarea>
  <div class="hint">Navíc <code>{popis}</code> = text, který k detekci napsala AI. U každého videa jde titulek i popis ručně upravit.</div>
 </div>
 <div class="card"><h2>Automatika</h2>
  <label class="check"><input type="checkbox" name="auto" value="1"{% if sc.auto %} checked{% endif %}>Automatická videa po upozornění rovnou zrychlit podle tohoto nastavení</label>
  <div class="hint">{% if auto_export_on %}Automatická videa jsou zapnutá v <a href="/ai#video">Nastavení AI → Automatické video</a>. Hotové zrychlené video najdeš ve Videích → Studio{% else %}Aby to mělo co zpracovávat, zapni nejdřív automatické video po upozornění v <a href="/ai#video">Nastavení AI → Automatické video</a>{% endif %}. Nahrávání na YouTube přijde v příští verzi.</div>
 </div>
 <div class="savebar"><button class="btn" data-busy="Ukládám">Uložit nastavení</button></div>
</form>
</div></div>
{% endblock %}"""

# Všechny POST formuláře, včetně přihlášení, dostanou stejnou ochranu.
for _name, _template in TEMPLATES.items():
    TEMPLATES[_name] = re.sub(
        r'(<form\b[^>]*\bmethod="post"[^>]*>)',
        r'\1<input type="hidden" name="csrf_token" value="{{ csrf_token }}">', _template)
jenv = Environment(loader=DictLoader(TEMPLATES), autoescape=True)
jenv.globals["rtsp_base"] = lambda ip, user, password: (
    "rtsp://" + (f"{quote(user, safe='')}:{quote(password, safe='')}@" if user else "") + f"{ip}:554")
jenv.filters["mask_rtsp"] = lambda value: re.sub(r"(rtsps?://)[^/@\s]*@", r"\1***@", value)
jenv.filters["czdt"] = cz_dt
jenv.filters["urlhost"] = lambda u: (urlsplit(str(u or "")).hostname or str(u or ""))
jenv.filters["czdate"] = cz_date
jenv.filters["cztime"] = lambda ts: str(ts or "")[11:16]
FAVICON = quote(LOGO_SVG.replace('class="logo" ', '').replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ', 1), safe="")


# --------------------------------------------------------------------------- web app – aplikace

@asynccontextmanager
async def lifespan(_app):
    on_startup()
    try:
        yield
    finally:
        watcher.running = False
        watcher.stop_event.set()
        await run_in_threadpool(watcher.join, 5)


app = FastAPI(title="Atmovio", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
(APP_DIR / "static" / "vendor").mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")
_cfg0 = load_config()

SUBTITLES = {
    "/": "Stav nahrávání, kamer a hlídání oblohy na jednom místě.",
    "/cameras": "Přidání nové kamery. Vše o jedné kameře (obraz, stav, AI, adresy, detekce, videa) najdeš kliknutím na její název.",
    "/live": "Aktuální snímky ze všech kamer. Kliknutím na kameru otevřeš vše o ní na jednom místě.",
    "/discover": "Najdi kamery v domácí síti i za VPN a načti jejich RTSP adresy.",
    "/storage": "Kolik místa záznamy zabírají, jak dlouho se uchovávají a jak přehrát nebo stáhnout video.",
    "/ai": "Klíč k AI, co hlídat a jak často se dívat.",
    "/history": "Detekce AI, na které přišlo upozornění. Přepínačem zobrazíš i ostatní vyhodnocení.",
    "/email": "Kam chodí upozornění a kdy se hlásí výpadky.",
    "/vpn": "Je vzdálená kamera dostupná? Síťové údaje RPi.",
    "/logs": "Co se v systému děje: hlídání oblohy, kamery, disk, VPN, nahrávání.",
    "/system": "Stav Raspberry Pi, restart, hesla, aktualizace.",
    "/system/update": "Nové verze Atmovio z GitHubu: kontrola, co je nového, instalace jedním tlačítkem.",
    "/videos": "Videa vystřižená ze záznamů – ke stažení, s náhledem. Sama se mažou po nastavené době. Ve studiu je zrychlíš a doplníš intro a hudbu.",
    "/studio/settings": "Jak se vyrábí zrychlená videa: rychlost, intro, text v obraze, hudba, titulek a popis. Ruční i automatický režim.",
}


def render(request: Request, tpl: str, title: str, **ctx) -> HTMLResponse:
    host = request.url.hostname or "localhost"
    flash = request.session.pop("flash", None)
    flash_kind = request.session.pop("flash_kind", "")
    path = request.url.path
    active = path if path in dict(NAV) else "/" + path.split("/")[1]
    if active == "/discover":
        active = "/cameras"
    if active == "/camera":
        active = "/live"
    if active == "/studio":
        active = "/studio/settings" if path.startswith("/studio/settings") or path.startswith("/studio/upload") else "/videos"
    cfg = load_config()
    labels = camera_labels(cfg)
    st = storage_status()
    side = {"ai_on": bool(cfg["ai"].get("enabled")), "ai_used": 0, "ai_limit": int(cfg["ai"].get("daily_limit", 0) or 0),
            "disk_pct": 0, "down": len([v for v in watcher.outage_state().values() if v is not None])}
    if side["ai_on"]:
        try:
            side["ai_used"] = watcher.calls_today(cfg, dt.datetime.now(ZoneInfo(cfg["tz"])))
        except Exception:
            pass
    if st["mode"] in ("recording", "legacy"):
        side["disk_pct"] = disk_info(cfg["recordings_path"]).get("pct", 0)
    flashes = [{"text": flash, "kind": flash_kind}] if flash else []
    ctx.setdefault("version", APP_VERSION)
    html = jenv.get_template(tpl).render(
        cam=lambda c: labels.get(c) or c, rule=lambda c: cam_rule(cfg["ai"], c),
        title=title, subtitle=ctx.pop("subtitle", SUBTITLES.get(path, "")), nav=NAV, nav_items=NAV_ITEMS, bottom_nav=BOTTOM_NAV,
        nav_primary=NAV_PRIMARY, nav_settings=NAV_SETTINGS, bottom_labels=BOTTOM_LABELS, settings_open=active in [h for h, _n, _i in NAV_SETTINGS],
        active=active, favicon=FAVICON, side=side, flashes=flashes, **static_assets(),
        frigate_ui=f"https://{host}:8971", cockpit_ui=f"https://{host}:9090", portainer_ui=f"https://{host}:9443",
        flash=flash, flash_kind=flash_kind, csrf_token=csrf_token(request), storage=st,
        frigate_problem=watcher.frigate_problem, vpn_problem=watcher.vpn_problem, disk_warning=disk_health_warning(),
        update_info=update_state(), req_path=path, github_repo=GITHUB_REPO, icons=ICONS, nav_icons=NAV_ICONS,
        now_year=dt.datetime.now().year, **ctx,
    )
    return HTMLResponse(html)


_smart_cache = {"at": 0.0, "text": "", "rows": []}


def _smart_devices() -> list:
    """(dev, role) pro systémový disk a disk pro záznamy – podle připojení, ne podle /dev/sdX (to se po restartu mění)."""
    out = []
    for mp, role in (("/", "systémový disk (Raspberry Pi OS)"), (DATA_MNT, "disk pro záznamy")):
        _rc, src = run(["findmnt", "-no", "SOURCE", mp], timeout=5)
        src = src.strip().split("[")[0]
        if not src.startswith("/dev/"):
            continue
        _rc, pk = run(["lsblk", "-no", "PKNAME", src], timeout=5)
        dev = "/dev/" + pk.strip().splitlines()[0] if pk.strip() else src
        if dev not in [d for d, _r in out]:
            out.append((dev, role))
    return out


def smart_snapshot() -> list:
    """Přečte S.M.A.R.T. (smartctl -j) pro systémový disk i disk pro záznamy."""
    rows = []
    for dev, role in _smart_devices():
        _rc, out = run(["smartctl", "-j", "-H", "-A", "-i", "-n", "standby", dev], timeout=30)
        try:
            j = json.loads(out[out.index("{"):])
        except Exception:
            continue
        attrs = {a.get("id"): a for a in (j.get("ata_smart_attributes") or {}).get("table") or []}
        def raw(i):
            v = attrs.get(i, {}).get("raw", {}).get("value")
            return int(v) if isinstance(v, (int, float)) else None
        nvme = j.get("nvme_smart_health_information_log") or {}
        rows.append({
            # klíč disku: sériové číslo; bez něj model+role (ne /dev/sdX – to se po restartu prohodí a disk by byl v seznamu dvakrát)
            "dev": dev, "role": role, "model": j.get("model_name") or "", "serial": j.get("serial_number") or f"{j.get('model_name') or 'disk'}|{role}",
            "healthy": 1 if (j.get("smart_status") or {}).get("passed", True) else 0,
            "pending": raw(197) if attrs else None, "reallocated": raw(5) if attrs else nvme.get("media_errors"),
            "uncorrectable": raw(198) if attrs else None,
            "temp": (j.get("temperature") or {}).get("current"),
        })
    return rows


def smart_record():
    """Uloží aktuální S.M.A.R.T. hodnoty (volá watcher 1× za hodinu) – kvůli trendu."""
    try:
        rows = smart_snapshot()
        with db() as con:
            for r in rows:
                prev = con.execute("SELECT pending, reallocated, uncorrectable, healthy FROM disk_smart WHERE serial=? ORDER BY ts DESC LIMIT 1",
                                   (r["serial"],)).fetchone()
                now_bad = ((r["pending"] or 0), (r["reallocated"] or 0), (r["uncorrectable"] or 0), r["healthy"])
                if prev is None or now_bad != ((prev["pending"] or 0), (prev["reallocated"] or 0), (prev["uncorrectable"] or 0), prev["healthy"]):
                    if any(now_bad[:3]) or not r["healthy"] or prev is not None:
                        log(f"S.M.A.R.T. {r['role']} ({r['model'] or r['dev']}): nečitelné {now_bad[0]}, přemapované {now_bad[1]}, "
                            f"neopravitelné {now_bad[2]}, stav {'OK' if r['healthy'] else 'SELHÁNÍ'}"
                            + ("" if prev is None else " – ZMĚNA oproti minulému měření"))
                con.execute("INSERT INTO disk_smart (ts, serial, model, dev, role, healthy, pending, reallocated, uncorrectable, temp) "
                            "VALUES (?,?,?,?,?,?,?,?,?,?)",
                            (dt.datetime.now().isoformat(timespec="seconds"), r["serial"], r["model"], r["dev"], r["role"],
                             r["healthy"], r["pending"], r["reallocated"], r["uncorrectable"], r["temp"]))
            con.execute("DELETE FROM disk_smart WHERE ts < ?", ((dt.datetime.now() - dt.timedelta(days=400)).isoformat(),))
        _smart_cache["at"] = 0
    except Exception as e:
        log(f"S.M.A.R.T.: čtení selhalo: {e}")


def disk_health() -> list:
    """Stav disků s trendem: pro každý disk poslední hodnoty + od kdy jsou vadné sektory beze změny / jak rostou."""
    now = time.time()
    if now - _smart_cache["at"] < 300 and _smart_cache["rows"]:
        return _smart_cache["rows"]
    result = []
    try:
        with db() as con:
            latest = [dict(r) for r in con.execute(
                "SELECT * FROM disk_smart WHERE ts IN (SELECT MAX(ts) FROM disk_smart GROUP BY role) ORDER BY role")]
            for r in latest:
                bad = (r["pending"] or 0) + (r["reallocated"] or 0) + (r["uncorrectable"] or 0)
                r["bad"] = bad
                r["level"] = "ok"
                r["trend"] = ""
                if not r["healthy"]:
                    r["level"] = "err"
                    r["trend"] = "disk sám hlásí selhání (SMART FAILED)"
                elif (r["reallocated"] or 0) >= 200 and (r["pending"] or 0) == 0 and (r["uncorrectable"] or 0) == 0:
                    r["level"] = "warn"
                    r["trend"] = f"{r['reallocated']} přemapovaných sektorů – disk je opotřebený; nahrává dál, ale naplánuj výměnu"
                elif bad:
                    hist = [dict(h) for h in con.execute(
                        "SELECT ts, pending, reallocated, uncorrectable FROM disk_smart WHERE serial=? ORDER BY ts", (r["serial"],))]
                    same_since = None
                    for h in reversed(hist):
                        if ((h["pending"] or 0), (h["reallocated"] or 0), (h["uncorrectable"] or 0)) == \
                           ((r["pending"] or 0), (r["reallocated"] or 0), (r["uncorrectable"] or 0)):
                            same_since = h["ts"]
                        else:
                            break
                    first_bad = next((h["ts"] for h in hist if (h["pending"] or 0) + (h["reallocated"] or 0) + (h["uncorrectable"] or 0)), r["ts"])
                    stable_h = (dt.datetime.now() - dt.datetime.fromisoformat(same_since)).total_seconds() / 3600 if same_since else 0
                    growing = same_since and same_since != first_bad
                    if growing and stable_h < 48:
                        r["level"] = "err"
                        r["trend"] = f"počet roste (od {first_bad[8:10]}. {int(first_bad[5:7])}. {first_bad[11:16]}) – disk vyměň"
                    elif stable_h >= 72:
                        r["level"] = "warn"
                        r["trend"] = f"beze změny už {int(stable_h // 24)} dní – pravděpodobně jednorázová chyba, hlídám dál"
                        if (r["reallocated"] or 0) >= 200:
                            r["trend"] += f"; {r['reallocated']} přemapovaných sektorů ale znamená opotřebený disk – naplánuj výměnu"
                    else:
                        r["level"] = "warn"
                        r["trend"] = f"sleduji od {first_bad[8:10]}. {int(first_bad[5:7])}. {first_bad[11:16]}, zatím beze změny ({int(stable_h)} h)"
                result.append(r)
    except Exception as e:
        log(f"S.M.A.R.T.: vyhodnocení selhalo: {e}")
    _smart_cache.update(at=now, rows=result)
    return result


def disk_health_warning() -> tuple:
    """(úroveň, text) pro lištu na každé stránce; ('', '') když je vše v pořádku."""
    rows = [r for r in disk_health() if r["level"] == "err"]  # stabilní vadné sektory jen v Systému a v logu, lišta až při růstu
    if not rows:
        return "", ""
    level = "err"
    parts = []
    for r in rows:
        what = ", ".join(x for x in (
            f"{r['pending']} nečitelných sektorů" if r.get("pending") else "",
            f"{r['reallocated']} přemapovaných" if r.get("reallocated") else "",
            f"{r['uncorrectable']} neopravitelných" if r.get("uncorrectable") else "") if x) or "chyba"
        parts.append(f"{r['role']} ({r['model'] or r['dev']}): {what} – {r['trend']}")
    return level, "; ".join(parts)


STATIC_DIR = APP_DIR / "static"
_PICO_CDN = "https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css"
_ALPINE_CDN = "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js"


def static_assets() -> dict:
    """Pico CSS a Alpine.js z disku (offline); když chybí (nepovedlo se stáhnout), z CDN."""
    pico = STATIC_DIR / "vendor" / "pico.min.css"
    alpine = STATIC_DIR / "vendor" / "alpine.min.js"
    return {"pico_css": "/static/vendor/pico.min.css" if pico.is_file() and pico.stat().st_size > 1000 else _PICO_CDN,
            "alpine_js": "/static/vendor/alpine.min.js" if alpine.is_file() and alpine.stat().st_size > 1000 else _ALPINE_CDN}


def flash(request: Request, msg: str, kind: str = ""):
    request.session["flash"] = msg
    request.session["flash_kind"] = kind


def logged_in(request: Request) -> bool:
    stored = load_config()["admin_password_hash"]
    return request.session.get("auth") == hashlib.sha256(stored.encode()).hexdigest()


def api_key_ok(request: Request) -> bool:
    """Ověří API klíč z hlavičky Authorization: Bearer / X-API-Key (nebo ?api_key=) proti uloženým hashům."""
    auth = request.headers.get("authorization", "")
    key = auth[7:].strip() if auth.lower().startswith("bearer ") else request.headers.get("x-api-key", "") or request.query_params.get("api_key", "")
    if not key:
        return False
    h = hashlib.sha256(key.encode()).hexdigest()
    return any(secrets.compare_digest(h, k.get("hash", "")) for k in load_config().get("api_keys") or [])


def csrf_token(request: Request) -> str:
    return request.session.setdefault("csrf", secrets.token_urlsafe(32))


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    path = request.url.path
    if path.startswith("/static/"):
        response = await call_next(request)
        response.headers["Cache-Control"] = "public, max-age=86400"
        return response
    if path.startswith("/api/v1/"):
        if not (api_key_ok(request) or logged_in(request)):
            return JSONResponse({"error": "unauthorized", "hint": "Authorization: Bearer <API key> (Nastavení → Systém → API)"},
                                status_code=401, headers={"WWW-Authenticate": "Bearer"})
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        return response
    if path not in ("/login", "/api/health") and not logged_in(request):
        return RedirectResponse("/login", status_code=303)
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        # body() zajistí opětovné přečtení formuláře samotným endpointem.
        body = await request.body()
        if len(body) > (120 * 1024 * 1024 if path.startswith("/studio/upload/") else 65_536):
            return JSONResponse({"error": "Formulář je příliš velký."}, status_code=413)
        form = await request.form()
        expected = request.session.get("csrf", "")
        supplied = str(form.get("csrf_token", ""))
        if not expected or not secrets.compare_digest(expected, supplied):
            return JSONResponse({"error": "Neplatný formulář. Obnov stránku a zkus to znovu."}, status_code=403)
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    return response


# SessionMiddleware musí být přidán až PO auth middleware (poslední přidaný je nejvíc vnější)
app.add_middleware(SessionMiddleware, secret_key=_cfg0["secret"], max_age=60 * 60 * 24 * 14,
                   same_site="lax", https_only=os.environ.get("ATMOVIO_HTTPS") == "1")


# --------------------------------------------------------------------------- REST API v1 (jen čtení; klíč v Nastavení → Systém) – docs/api.md

def _api_base(request: Request) -> str:
    return str(request.base_url).rstrip("/")


def _api_detection(cfg, e: dict, base: str) -> dict:
    return {
        "id": e["id"], "ts": e["ts"], "camera": e["camera"], "camera_label": cam_label(cfg, e["camera"]),
        "score": e.get("score"), "phenomenon": e.get("phenomenon"), "phenomena": [x for x in (e.get("phenomena") or "").split(",") if x],
        "description": e.get("description"), "notified": bool(e.get("notified")), "error": e.get("error"),
        "exported": bool(e.get("exported")), "image_url": f"{base}/api/v1/detections/{e['id']}/image.jpg" if e.get("image") else None,
        "detail_url": f"{base}/detection/{e['id']}",
    }


def api_status_data(cfg, fs: dict | None = None) -> dict:
    now = dt.datetime.now(ZoneInfo(cfg["tz"]))
    fs = fs or frigate_status(cfg)
    st = storage_status()
    d = disk_info(cfg["recordings_path"]) if st["mode"] in ("recording", "legacy") else {}
    sysi = sys_info()
    upd = update_state()
    return {
        "ok": True, "version": APP_VERSION, "time": now.isoformat(timespec="seconds"),
        "frigate": {"online": fs["online"], "version": fs.get("version", "")},
        "storage": {"mode": st["mode"], "reason": st.get("reason", ""), "disk_pct": d.get("pct"), "disk_free": d.get("free_h"), "disk_total": d.get("total_h"),
                    "retain_days": retain_days(cfg) if d else None},
        "ai": {"enabled": bool(cfg["ai"].get("enabled")), "status": watcher.status, "used_today": watcher.calls_today(cfg, now),
               "daily_limit": int(cfg["ai"].get("daily_limit", 0) or 0), "cameras": list(cfg["ai"]["cameras"]), "daytime": is_daytime(cfg, now),
               "threshold": int(cfg["ai"].get("threshold", 7) or 7)},
        "sun": sun_times(cfg, now),
        "system": {"hostname": sysi.get("hostname"), "temp": sysi.get("temp"), "uptime": sysi.get("uptime"), "load": sysi.get("load"),
                   "ip": sysi.get("ip"), "ip_vpn": sysi.get("ip_vpn"), "mem": sysi.get("mem")},
        "outages": {k: int(v) for k, v in watcher.outage_state().items() if v is not None},
        "update": {"latest": upd.get("latest") or None, "available": upd["available"], "checked": upd.get("checked") or None},
    }


def api_cameras_data(cfg, base: str, fs: dict | None = None) -> list:
    fs = fs or frigate_status(cfg)
    out_state = watcher.outage_state()
    ax = cfg["ai"].get("auto_export") or {}
    cams = []
    for c in frigate_cameras(cfg):
        st = fs["cameras"].get(c) or {}
        info = camera_info(cfg, c)
        fps = float(st.get("fps") or 0)
        cams.append({"name": c, "label": cam_label(cfg, c), "ip": info["ip"], "via": info["via"], "online": bool(fs["online"] and fps > 0),
                     "fps": round(fps, 1), "outage_s": (int(out_state.get(f"cam:{c}")) if out_state.get(f"cam:{c}") is not None else None),
                     "ai": c in cfg["ai"]["cameras"], "auto_video": bool(ax.get("enabled")) and c in (ax.get("cameras") or []),
                     "snapshot_url": f"{base}/api/v1/cameras/{c}/snapshot.jpg"})
    return cams


def api_detections_data(cfg, base: str, camera: str = "", limit: int = 20, notified: int = 1, min_score: int = 0) -> list:
    q = "SELECT e.*, (SELECT COUNT(*) FROM exports x WHERE x.detection_id=e.id) AS exported FROM evaluations e WHERE skipped=0 AND error IS NULL AND image IS NOT NULL"
    args: list = []
    if notified:
        q += " AND notified=1"
    if camera:
        q += " AND camera=?"; args.append(camera)
    if min_score:
        q += " AND score>=?"; args.append(min_score)
    q += " ORDER BY id DESC LIMIT ?"; args.append(max(1, min(200, limit)))
    with db() as con:
        rows = [dict(r) for r in con.execute(q, args)]
    return [_api_detection(cfg, e, base) for e in rows]


def api_videos_data(cfg, base: str) -> list:
    return [{"id": v["id"], "name": v["name"], "camera": v["camera"], "camera_label": cam_label(cfg, v["camera"]), "detection_id": v.get("detection_id"),
             "start_ts": v["start_ts"], "end_ts": v["end_ts"], "created": v["created"], "ready": v["ready"], "in_progress": v["in_progress"],
             "auto": bool(v.get("auto")), "size": v.get("size_h"), "duration": v.get("duration_h"), "range": v.get("range_h"),
             "thumb_url": f"{base}/videos/{v['id']}/thumb.jpg" if v.get("thumb") else None,
             "download_url": f"{base}/api/v1/videos/{v['id']}/download" if v["ready"] else None} for v in list_videos(cfg)]


def api_events_data(limit: int = 20) -> list:
    return recent_events(max(1, min(200, limit)))


@app.get("/api/v1/status")
def api_status(request: Request):
    return api_status_data(load_config())


@app.get("/api/v1/cameras")
def api_cameras(request: Request):
    return {"ok": True, "cameras": api_cameras_data(load_config(), _api_base(request))}


@app.get("/api/v1/cameras/{camera}/snapshot.jpg")
def api_snapshot(camera: str, h: int = 720):
    return live_thumbnail(camera, h)


@app.get("/api/v1/detections")
def api_detections(request: Request, camera: str = "", limit: int = 20, notified: int = 1, min_score: int = 0):
    return {"ok": True, "detections": api_detections_data(load_config(), _api_base(request), camera, limit, notified, min_score)}


@app.get("/api/v1/detections/{rid}")
def api_detection(request: Request, rid: int):
    cfg = load_config()
    with db() as con:
        row = con.execute("SELECT e.*, (SELECT COUNT(*) FROM exports x WHERE x.detection_id=e.id) AS exported FROM evaluations e WHERE id=?", (rid,)).fetchone()
    if not row:
        return JSONResponse({"ok": False, "error": "not found"}, status_code=404)
    return {"ok": True, "detection": _api_detection(cfg, dict(row), _api_base(request))}


@app.get("/api/v1/detections/{rid}/image.jpg")
def api_detection_image(rid: int):
    with db() as con:
        row = con.execute("SELECT image FROM evaluations WHERE id=?", (rid,)).fetchone()
    if not row or not row["image"]:
        return JSONResponse({"ok": False, "error": "not found"}, status_code=404)
    return snapshot(row["image"])


@app.get("/api/v1/videos")
def api_videos(request: Request):
    return {"ok": True, "videos": api_videos_data(load_config(), _api_base(request))}


@app.get("/api/v1/videos/{vid}/download")
def api_video_download(vid: int):
    return video_download(vid)


@app.get("/api/v1/events")
def api_events(limit: int = 20):
    return {"ok": True, "events": api_events_data(limit)}


@app.post("/system/api_key")
def api_key_create(request: Request, name: str = Form("")):
    key = "at_" + secrets.token_urlsafe(30)   # do 3.x "sw_"; staré klíče platí dál (ověřuje se jen hash)
    with edit_config() as cfg:
        keys = cfg.setdefault("api_keys", [])
        keys.append({"name": " ".join(name.split())[:40] or f"klíč {len(keys) + 1}", "hash": hashlib.sha256(key.encode()).hexdigest(),
                     "hint": key[:7] + "…", "created": dt.datetime.now().isoformat(timespec="seconds")})
    request.session["new_api_key"] = key
    flash(request, "API klíč vytvořen – zkopíruj si ho teď, znovu se nezobrazí.")
    return RedirectResponse("/system#api", status_code=303)


@app.post("/system/api_key/delete")
def api_key_delete(request: Request, hint: str = Form(...)):
    with edit_config() as cfg:
        cfg["api_keys"] = [k for k in cfg.get("api_keys") or [] if k.get("hint") != hint]
    flash(request, "API klíč zrušen.")
    return RedirectResponse("/system#api", status_code=303)


@app.get("/api/health")
def health():
    return {"ok": watcher.is_alive(), "watcher": watcher.status, "version": APP_VERSION}


@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    return HTMLResponse(jenv.get_template("login.html").render(error=None, csrf_token=csrf_token(request), favicon=FAVICON, version=APP_VERSION, **static_assets()))


@app.post("/login")
def login(request: Request, password: str = Form("")):
    with _config_lock:
        cfg = load_config()
        verified = check_pw(password, cfg["admin_password_hash"])
        if verified:
            if not cfg["admin_password_hash"].startswith("pbkdf2_sha256$"):
                cfg["admin_password_hash"] = hash_pw(password)
                save_config(cfg)
    if verified:
        request.session.clear()
        request.session["auth"] = hashlib.sha256(cfg["admin_password_hash"].encode()).hexdigest()
        return RedirectResponse("/", status_code=303)
    time.sleep(1)
    return HTMLResponse(jenv.get_template("login.html").render(error="Nesprávné heslo", csrf_token=csrf_token(request), favicon=FAVICON, version=APP_VERSION, **static_assets()), status_code=401)


@app.post("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


# ---- dashboard

def disk_info(path: str) -> dict:
    if path != "/" and not storage_ready():
        return {"path": path, "total_h": "nedostupný", "used_h": "–", "free_h": "–", "pct": 0}
    p = Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    try:
        u = shutil.disk_usage(p)
        pct = int(u.used * 100 / u.total) if u.total else 0
        return {"path": str(p), "total_h": human_bytes(u.total), "used_h": human_bytes(u.used),
                "free_h": human_bytes(u.free), "pct": pct}
    except Exception:
        return {"path": path, "total_h": "?", "used_h": "?", "free_h": "?", "pct": 0}


def sys_info() -> dict:
    info = {}
    _rc, info["hostname"] = run("hostname")
    _rc, ips = run("hostname -I")
    lan, vpn = [], []
    _rc2, addrs = run(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=5)
    for m in re.finditer(r"^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)", addrs or "", re.M):
        iface, ip = m.group(1), m.group(2)
        if iface.startswith(("docker", "br-", "veth", "lo")):
            continue
        (vpn if iface.startswith("wg") else lan).append(ip)
    info["ip"] = " ".join(lan) if lan else ips.strip().split(" ")[0]
    info["ip_vpn"] = " ".join(vpn)
    temp = "?"
    try:
        temp = f"{int(Path('/sys/class/thermal/thermal_zone0/temp').read_text()) / 1000:.1f} °C"
    except Exception:
        pass
    info["temp"] = temp
    try:
        info["load"] = " ".join(f"{x:.2f}" for x in os.getloadavg())
    except Exception:
        info["load"] = "?"
    try:
        up = float(Path("/proc/uptime").read_text().split()[0])
        info["uptime"] = f"{int(up // 86400)} d {int(up % 86400 // 3600)} h {int(up % 3600 // 60)} min"
    except Exception:
        info["uptime"] = "?"
    _rc, mem = run("free -h | awk '/Mem:/{print $3\" / \"$2}'")
    info["mem"] = mem
    d = disk_info("/")
    info["rootfs"] = f"{d['used_h']} z {d['total_h']} ({d['pct']} %)"
    return info


def retain_days(cfg) -> int:
    try:
        record = frigate_read_yaml(cfg).get("record", {})
        return int(record.get("continuous", record.get("retain", {})).get("days", 7))
    except Exception:
        return 7


def vpn_is_up(iface: str) -> bool:
    rc, _out = run(["ip", "link", "show", iface], timeout=5)
    return rc == 0


def recent_events(limit=12) -> list:
    with db() as con:
        return [dict(r) for r in con.execute("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))]


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    cfg = load_config()
    now = dt.datetime.now(ZoneInfo(cfg["tz"]))
    sr, ss = daylight_window(cfg, now.date())
    cameras = frigate_cameras(cfg)
    with db() as con:
        recent = [dict(r) for r in con.execute(
            "SELECT e.*, (SELECT COUNT(*) FROM exports x WHERE x.detection_id=e.id) AS exported FROM evaluations e "
            "WHERE skipped=0 AND error IS NULL AND notified=1 AND image IS NOT NULL ORDER BY id DESC LIMIT 10")]
    outages = {k: human_duration(v) for k, v in watcher.outage_state().items() if v is not None}
    ai_used = watcher.calls_today(cfg, now) if cfg["ai"].get("enabled") else 0
    ai_limit = int(cfg["ai"].get("daily_limit", 0) or 0)
    ai_pct = min(100, int(ai_used * 100 / ai_limit)) if ai_limit else 0
    ai_model = cfg["ai"].get("model") or "auto"
    if cfg["ai"].get("provider") == "gemini" and ai_model == "auto" and cfg["ai"].get("api_key"):
        try:
            ai_model = f"auto → {gemini_pick_model(cfg['ai']['api_key'])}"
        except Exception:
            pass
    last_evals = []
    with db() as con:
        for c in (cfg["ai"].get("cameras") or []):
            r = con.execute("SELECT id, ts, camera, score, phenomenon, description, image, notified FROM evaluations "
                            "WHERE camera=? AND skipped=0 AND error IS NULL AND image IS NOT NULL ORDER BY id DESC LIMIT 1", (c,)).fetchone()
            if r:
                last_evals.append(dict(r))
    last_evals.sort(key=lambda r: r["ts"], reverse=True)
    return render(request, "dashboard.html", "Přehled", cfg=cfg, fs=frigate_status(cfg), cameras=cameras, last_eval={e["camera"]: e for e in last_evals},
                  caminfo={c: camera_info(cfg, c) for c in cameras}, outages=outages, down_count=len(outages),
                  disk=disk_info(cfg["recordings_path"]), retain_days=retain_days(cfg), watcher_status=watcher.status,
                  sun=sun_times(cfg, now), golden=is_golden_hour(cfg, now),
                  email_ok=email_ready(cfg) or web_ready(cfg), recent=recent, events=recent_events(8), now_ts=int(time.time()),
                  ai_used=ai_used, ai_limit=ai_limit, ai_pct=ai_pct, ai_model=ai_model, providers=PROVIDERS, stats7=ai_stats_days(now, 7),
                  pending_auto=pending_auto_exports(cfg),
                  estimate=ai_estimate(cfg, max(1, len(cfg["ai"]["cameras"]))), sysinfo=sys_info(), now_dt=now.strftime("%Y-%m-%dT%H:%M:%S"))


@app.get("/live/{camera}.jpg")
def live_thumbnail(camera: str, h: int = 360):
    """Aktuální snímek kamery – proxy na Frigate (bez hesla, jen pro přihlášené)."""
    if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        return JSONResponse({"error": "bad camera"}, status_code=404)
    cfg = load_config()
    h = max(120, min(1080, int(h or 360)))
    try:
        r = frigate_api(cfg, f"/api/{camera}/latest.jpg?h={h}", timeout=6)
        if r.ok and r.content[:2] == b"\xff\xd8":
            return Response(content=r.content, media_type="image/jpeg", headers={"Cache-Control": "no-store"})
    except Exception:
        pass
    return JSONResponse({"error": "no image"}, status_code=503)


@app.get("/stream/{camera}.mjpeg")
def live_stream(camera: str, h: int = 480, fps: int = 5):
    """Živý obraz (MJPEG) – proxy na Frigate, jen pro přihlášené."""
    if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        return JSONResponse({"error": "bad camera"}, status_code=404)
    cfg = load_config()
    h = max(120, min(1080, int(h or 480)))
    fps = max(1, min(15, int(fps or 5)))
    try:
        r = requests.get(cfg["frigate_url"].rstrip("/") + f"/api/{camera}?fps={fps}&h={h}", stream=True, timeout=(5, 30))
    except Exception:
        return JSONResponse({"error": "frigate offline"}, status_code=503)
    if not r.ok:
        r.close()
        return JSONResponse({"error": "no stream"}, status_code=503)
    ctype = r.headers.get("content-type", "multipart/x-mixed-replace; boundary=frame")

    def gen():
        try:
            for chunk in r.iter_content(chunk_size=8192):
                if chunk:
                    yield chunk
        finally:
            r.close()
    return StreamingResponse(gen(), media_type=ctype, headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


def render_live(request: Request, mode: str = "grid", focus: str = ""):
    cfg = load_config()
    cameras = frigate_cameras(cfg)
    if focus and focus not in cameras:
        flash(request, "Tahle kamera neexistuje.", "err")
        return RedirectResponse("/live", status_code=303)
    outages = {k: human_duration(v) for k, v in watcher.outage_state().items() if v is not None}
    titles = {"grid": ("Kamery", SUBTITLES["/live"]),
              "all": ("Živě · všechny kamery", "Živý přenos ze všech kamer najednou.")}
    title, subtitle = titles[mode]
    return render(request, "live.html", title, cameras=cameras, focus=focus, mode=mode, cfg=cfg,
                  fs=frigate_status(cfg), outages=outages, caminfo={c: camera_info(cfg, c) for c in cameras},
                  info=camera_info(cfg, focus) if focus else {}, now_ts=int(time.time()), subtitle=subtitle)


@app.get("/live", response_class=HTMLResponse)
def live_page(request: Request):
    return render_live(request, "grid")


@app.get("/live/all", response_class=HTMLResponse)
def live_all_page(request: Request):
    return render_live(request, "all")


@app.get("/live/{camera}", response_class=HTMLResponse)
def live_camera_page(request: Request, camera: str):
    if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        return RedirectResponse("/live", status_code=303)
    return RedirectResponse(f"/camera/{camera}", status_code=303)


@app.get("/camera/{camera}", response_class=HTMLResponse)
def camera_page(request: Request, camera: str):
    """Vše o jedné kameře na jednom místě: obraz, stav, AI, nastavení, detekce, videa."""
    if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        return RedirectResponse("/live", status_code=303)
    cfg = load_config()
    cameras = frigate_cameras(cfg)
    if camera not in cameras:
        flash(request, "Tahle kamera neexistuje.", "err")
        return RedirectResponse("/live", status_code=303)
    now = dt.datetime.now(ZoneInfo(cfg["tz"]))
    fs = frigate_status(cfg)
    outages = {k: human_duration(v) for k, v in watcher.outage_state().items() if v is not None}
    settings = camera_settings_all(cfg).get(camera) or {"main": "", "sub": "", "main_raw": "", "sub_raw": ""}
    with db() as con:
        recent = [dict(r) for r in con.execute(
            "SELECT e.*, (SELECT COUNT(*) FROM exports x WHERE x.detection_id=e.id) AS exported FROM evaluations e "
            "WHERE camera=? AND skipped=0 AND error IS NULL AND notified=1 AND image IS NOT NULL ORDER BY id DESC LIMIT 6", (camera,))]
        last_eval = con.execute("SELECT ts, score, phenomenon, error, notified FROM evaluations WHERE camera=? AND skipped=0 ORDER BY id DESC LIMIT 1",
                                (camera,)).fetchone()
        week = con.execute("SELECT COALESCE(SUM(calls),0) AS calls, COALESCE(SUM(notified),0) AS notified FROM ai_stats WHERE camera=? AND day>=?",
                           (camera, (now.date() - dt.timedelta(days=6)).isoformat())).fetchone()
        outage_events = [dict(r) for r in con.execute(
            "SELECT ts, subject FROM events WHERE kind='outage' AND subject LIKE ? ORDER BY id DESC LIMIT 5", (f"%{cam_label(cfg, camera)}%",))]
    videos = [v for v in list_videos(cfg) if v["camera"] == camera][:6]
    rec_state = recording_state(cfg, camera, time.time() - 600, time.time()) if storage_ready() and fs["online"] else "nodisk"
    ax = cfg["ai"].get("auto_export") or {}
    return render(request, "camera.html", cam_label(cfg, camera), camera=camera, cameras=cameras, fs=fs, outages=outages, cfg=cfg,
                  info=camera_info(cfg, camera), settings=settings, recent=recent, last_eval=dict(last_eval) if last_eval else None,
                  week=dict(week) if week else {"calls": 0, "notified": 0}, videos=videos, rec_state=rec_state,
                  ai_on=camera in cfg["ai"]["cameras"], auto_on=bool(ax.get("enabled")) and camera in (ax.get("cameras") or []),
                  ax=ax, pending_auto=[j for j in pending_auto_exports(cfg) if j["camera"] == camera], outage_events=outage_events,
                  now_ts=int(time.time()), subtitle="Stav, hlídání oblohy, detekce a videa této kamery. Nastavení je v menu Nastavení.")


@app.post("/camera/{camera}/ai")
def camera_ai_save(request: Request, camera: str, ai_on: str = Form(""), auto_on: str = Form("")):
    cfg = load_config()
    if camera not in frigate_cameras(cfg):
        flash(request, "Tahle kamera neexistuje.", "err")
        return RedirectResponse("/live", status_code=303)
    with edit_config() as current:
        cams = [c for c in current["ai"]["cameras"] if c != camera]
        if ai_on:
            cams.append(camera)
        current["ai"]["cameras"] = cams
        ax = current["ai"].setdefault("auto_export", dict(DEFAULT_CONFIG["ai"]["auto_export"]))
        axc = [c for c in (ax.get("cameras") or []) if c != camera]
        if auto_on:
            axc.append(camera)
            ax["enabled"] = True
        ax["cameras"] = axc
    flash(request, "Nastavení kamery uloženo." + ("" if cfg["ai"].get("enabled") else " Pozor: AI hlídání je celkově vypnuté – zapni ho v Nastavení → AI hlídání oblohy."),
          "" if cfg["ai"].get("enabled") else "warn")
    return RedirectResponse(f"/camera/{camera}", status_code=303)


# ---- cameras

@app.get("/cameras", response_class=HTMLResponse)
def cameras_page(request: Request):
    return render_cameras_page(request, request.query_params)


@app.post("/cameras/prepare", response_class=HTMLResponse)
def cameras_prepare(request: Request, name: str = Form(""), main: str = Form(""), sub: str = Form(""),
                    user: str = Form(""), password: str = Form(""), replace: str = Form("")):
    # Předvyplnění bez hesel v URL, historii prohlížeče a access logu.
    return render_cameras_page(request, {"name": name, "main": main, "sub": sub, "user": user, "password": password,
                                         "replace": replace})


def camera_settings_all(cfg) -> dict:
    """Adresy streamů všech kamer z Frigate YAML (maskované heslo + surové pro formulář)."""
    data = frigate_read_yaml(cfg)
    cams = {}
    for name, c in (data.get("cameras") or {}).items():
        main = sub = ""
        for inp in (c.get("ffmpeg", {}).get("inputs") or []):
            roles = inp.get("roles", [])
            if "record" in roles:
                main = inp.get("path", "")
            elif "detect" in roles:
                sub = inp.get("path", "")
        # zobraz původní RTSP z go2rtc místo interního restreamu
        streams = data.get("go2rtc", {}).get("streams", {}) or {}
        if name in streams and isinstance(streams[name], list) and streams[name]:
            main = plain_rtsp(streams[name][0])
        if f"{name}_sub" in streams and streams[f"{name}_sub"]:
            sub = plain_rtsp(streams[f"{name}_sub"][0])
        info = camera_info(cfg, name)
        cams[name] = {"main": re.sub(r"//([^:@/]+):([^@/]+)@", r"//\1:***@", str(main)),
                      "sub": re.sub(r"//([^:@/]+):([^@/]+)@", r"//\1:***@", str(sub)) if sub else "",
                      "main_raw": str(main), "sub_raw": str(sub or ""),
                      "ip": info["ip"], "via": info["via"]}
    return cams


def render_cameras_page(request: Request, values):
    cfg = load_config()
    cams = camera_settings_all(cfg)
    q = values
    pre = {"name": " ".join(str(q.get("name", "")).split())[:80], "main": q.get("main", ""), "sub": q.get("sub", ""),
           "user": q.get("user", ""), "password": q.get("password", ""),
           "replace": q.get("replace", "") if q.get("replace", "") in cams else ""}
    return render(request, "cameras.html", "Kamery", cams=cams, pre=pre)


@app.get("/cameras/edit/{name}", response_class=HTMLResponse)
def cameras_edit(request: Request, name: str):
    """Předvyplní formulář úprav kamery na stránce Kamery (jediné místo, kde se kamery nastavují)."""
    cfg = load_config()
    cams = camera_settings_all(cfg)
    if name not in cams:
        flash(request, "Kamera neexistuje.", "err")
        return RedirectResponse("/cameras", status_code=303)
    c = cams[name]
    return render_cameras_page(request, {"name": cam_label(cfg, name), "main": c.get("main", ""), "sub": c.get("sub", "") or "", "replace": name})


@app.get("/discover", response_class=HTMLResponse)
def discover_page(request: Request):
    cfg = load_config()
    d = cfg.get("discover", {})
    return render(request, "discover.html", "Vyhledat kamery", subnets=d.get("subnets") or local_subnet(),
                  user=d.get("user", ""), password=d.get("password", ""), results=None, guesses=RTSP_GUESSES)


@app.post("/discover", response_class=HTMLResponse)
def discover_run(request: Request, subnets: str = Form(""), user: str = Form(""), password: str = Form("")):
    subs = [x.strip() for x in subnets.split(",") if x.strip()]
    with edit_config() as current:
        current["discover"] = {"subnets": ", ".join(subs), "user": user.strip(), "password": password}
    try:
        results = discover_cameras(subs, user.strip(), password)
    except Exception as e:
        flash(request, f"Hledání selhalo: {e}", "err")
        results = []
    return render(request, "discover.html", "Vyhledat kamery", subnets=", ".join(subs), user=user.strip(),
                  password=password, results=results, guesses=RTSP_GUESSES)


def ffprobe_ok(url: str) -> tuple[bool, str]:
    rc, out = run(["ffprobe", "-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v:0",
                   "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", url], timeout=25)
    return rc == 0 and bool(out.strip()), re.sub(r"(rtsps?://)[^/@\s]+@", r"\1***@", out)


def probe_video(url: str, timeout: int = 12) -> dict | None:
    """ffprobe: vrátí {'codec','w','h'} prvního video streamu, None když stream nemá video nebo neodpovídá."""
    rc, out = run(["ffprobe", "-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v:0",
                   "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", url], timeout=timeout + 3)
    line = next((ln for ln in out.splitlines() if ln and not ln.startswith("rtsp")), "")
    parts = line.split(",")
    if rc != 0 or len(parts) < 3 or not parts[0]:
        return None
    # ffprobe umí kodek a rozlišení vyčíst z hlavičky (SDP) i od kamery, která pak žádný obraz neposílá.
    # Proto ještě DEKÓDUJ pár snímků přesně jako Frigate (ten čeká max. 20 s na první dekódovaný snímek,
    # tedy na klíčový snímek s SPS/PPS) – jinak hlásí "No frames received".
    rc, err = run(["ffmpeg", "-v", "error", "-nostdin", "-rtsp_transport", "tcp", "-i", url,
                   "-map", "0:v:0", "-frames:v", "3", "-f", "null", "-"], timeout=18)
    if rc != 0:
        log("Kamera: " + re.sub(r"//[^@/]+@", "//***@", url) + " – žádný dekódovatelný snímek do 18 s"
            + (f": {err[-300:]}" if err else ""))
        return None
    return {"codec": parts[0], "w": parts[1], "h": parts[2]}


def go2rtc_probe(cfg, url: str, timeout: int = 15) -> dict | None | bool:
    """Ověří stream tak, jak ho uvidí Frigate – přes go2rtc (dočasný stream + ffprobe restreamu).
    Vrací dict (video ok), None (go2rtc video nedostal), False (go2rtc nedostupný – nelze rozhodnout)."""
    api = cfg.get("go2rtc_url", "http://127.0.0.1:1984").rstrip("/") + "/api/streams"
    name = f"atmovio_test_{secrets.token_hex(4)}"
    try:
        r = requests.put(api, params={"name": name, "src": url}, timeout=5)
        if r.status_code >= 400:
            return False
    except Exception:
        return False
    try:
        return probe_video(f"{cfg.get('restream_url', 'rtsp://127.0.0.1:8554').rstrip('/')}/{name}", timeout)
    finally:
        try:
            requests.delete(api, params={"name": name}, timeout=5)
        except Exception:
            pass


def stream_variants(url: str) -> list[str]:
    """Kandidáti, když kamera (typicky přes ONVIF) nahlásí nesmyslný port: původní adresa, pak port 554 a 8554."""
    out = [url]
    try:
        p = urlsplit(url)
        for port in (554, 8554):
            if p.port != port and p.hostname:
                host = f"[{p.hostname}]" if ":" in p.hostname else p.hostname
                auth = p.netloc.rsplit("@", 1)[0] + "@" if "@" in p.netloc else ""
                out.append(p._replace(netloc=f"{auth}{host}:{port}").geturl())
    except ValueError:
        pass
    return out


def go2rtc_source(url: str, mode: str) -> str:
    """Zdroj pro go2rtc: přímé RTSP, nebo přes ffmpeg (kamery, se kterými se go2rtc nedomluví – dávají mu jen zvuk)."""
    return f"ffmpeg:{url}#video=copy" if mode == "ffmpeg" else url


def plain_rtsp(source: str) -> str:
    """Z go2rtc zdroje (i ffmpeg:…#video=copy) vrátí čistou rtsp:// adresu."""
    m = re.search(r"rtsps?://[^#\s]+", str(source))
    return m.group(0) if m else str(source)


def find_working_stream(cfg, url: str) -> tuple[str, dict, str] | tuple[None, None, str]:
    """Najde adresu a způsob, kterým z kamery dostane video Frigate (přes go2rtc).
    Vrací (adresa, info o videu, režim): režim 'direct' = go2rtc čte RTSP sám, 'ffmpeg' = go2rtc čte přes ffmpeg."""
    fallback = None
    for candidate in stream_variants(url):
        info = probe_video(candidate)
        if not info:
            continue
        via = go2rtc_probe(cfg, candidate)
        if via is False:
            return candidate, info, "direct"     # go2rtc neběží – spolehni se na ffprobe
        if via:
            return candidate, via, "direct"
        fallback = fallback or (candidate, info)
        log(f"Kamera: {re.sub(r'//[^@/]+@', '//***@', candidate)} dává video přes ffmpeg, ale go2rtc z ní video nedostal")
    if fallback:
        candidate, info = fallback
        via = go2rtc_probe(cfg, go2rtc_source(candidate, "ffmpeg"))
        if via:
            return candidate, via, "ffmpeg"
    return None, None, ""


def valid_rtsp(url: str) -> bool:
    try:
        parsed = urlsplit(url)
        return (parsed.scheme in ("rtsp", "rtsps") and bool(parsed.hostname)
                and (parsed.port is None or 1 <= parsed.port <= 65535)
                and not any(ch.isspace() or ord(ch) < 32 for ch in url))
    except ValueError:
        return False


def _back_url(back: str, default: str = "/cameras") -> str:
    return back if re.fullmatch(r"/camera/[a-zA-Z0-9_]{1,64}", back or "") else default


@app.post("/cameras/add")
@frigate_transaction
def cameras_add(request: Request, name: str = Form(...), main: str = Form(...), sub: str = Form(""),
                test: str = Form(""), atmovio: str = Form(""), user: str = Form(""), password: str = Form(""),
                replace: str = Form(""), back: str = Form("")):
    cfg = load_config()
    back = _back_url(back)
    label = " ".join(name.split())[:80]
    name = slugify(label)
    if replace:
        # Ze stránky kamery přichází adresa s maskovaným heslem (***) – doplnit uložené; nové přihlášení má přednost.
        stored = camera_settings_all(cfg).get(replace) or {}
        for key, raw in (("main", stored.get("main_raw", "")), ("sub", stored.get("sub_raw", ""))):
            val = (main if key == "main" else sub).strip()
            if ":***@" in val and raw:
                val = re.sub(r"//([^:@/]+):\*\*\*@", lambda m: "//" + urlsplit(raw).netloc.rsplit("@", 1)[0] + "@", val, count=1)
                if user.strip():
                    val = re.sub(r"//[^@/]+@", "//", val, count=1)
            if key == "main":
                main = val
            else:
                sub = val
    main = rtsp_with_auth(main, user.strip(), password)
    sub = rtsp_with_auth(sub, user.strip(), password)
    data = frigate_read_yaml(cfg)
    existing = data.get("cameras") or {}
    streams = data.get("go2rtc", {}).get("streams") or {}
    previous = None
    if replace:
        # Úprava existující kamery: původní záznam vyjmi (aby kontrola názvu prošla), ostatní nastavení zachovej.
        if replace not in existing:
            flash(request, "Upravovaná kamera už neexistuje.", "err")
            return RedirectResponse(back, status_code=303)
        previous = existing.pop(replace)
        streams.pop(replace, None)
        streams.pop(f"{replace}_sub", None)
    if (not label or not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", name) or name.endswith("_sub")
            or name in existing or name in streams or f"{name}_sub" in streams):
        flash(request, f"Kamera s názvem „{label}“ (ID {name}) už existuje nebo je název neplatný – zvol jiný název.", "err")
        return RedirectResponse(back, status_code=303)
    if not valid_rtsp(main) or (sub and not valid_rtsp(sub)):
        flash(request, "Zadej platnou rtsp:// nebo rtsps:// adresu. Mezery v hesle zakóduj jako %20.", "err")
        return RedirectResponse(back, status_code=303)
    notes = []
    main_mode = sub_mode = "direct"
    if test:
        cfg_probe = load_config()
        fixed, info, mode = find_working_stream(cfg_probe, main)
        if not fixed:
            _ok, out = ffprobe_ok(main)
            hint = (" Kamera odmítla přihlášení – zkontroluj uživatele a heslo kamery." if "401" in out
                    else " Kamera na této adrese neposílá video (jen zvuk nebo nic) – zkus jiný profil z vyhledávání nebo port 554.")
            flash(request, f"Hlavní stream se nepodařilo použít: {out or 'bez videa'}.{hint} Kamera nebyla přidána.", "err")
            return RedirectResponse(back, status_code=303)
        if fixed != main:
            notes.append(f"hlavní stream přesměrován na port {urlsplit(fixed).port} (adresa od kamery nedávala video)")
        main = fixed
        if info:
            notes.append(f"video {info['codec'].upper()} {info['w']}×{info['h']}")
        if mode == "ffmpeg":
            notes.append("kamera se s go2rtc nedomluví napřímo, stream jde přes ffmpeg (bez zvuku)")
        notes.append("kamera posílá snímky")
        main_mode = mode
        if sub:
            fixed, _info, mode = find_working_stream(cfg_probe, sub)
            if not fixed:
                notes.append("substream nedává video – použit jen hlavní stream")
                sub = ""
            else:
                sub, sub_mode = fixed, mode
    data.setdefault("go2rtc", {}).setdefault("streams", {})
    data["go2rtc"]["streams"][name] = [go2rtc_source(main, main_mode)]
    # Záznam i náhled čte ffmpeg Frigate PŘÍMO z kamery (preset-rtsp-generic) – stejnou cestou, kterou prošlo ověření.
    # go2rtc restream slouží jen živému náhledu v UI; některé kamery přes něj Frigate obraz nedostane.
    inputs = [{"path": main, "input_args": "preset-rtsp-generic", "roles": ["record"] if sub else ["record", "detect"]}]
    if sub:
        data["go2rtc"]["streams"][f"{name}_sub"] = [go2rtc_source(sub, sub_mode)]
        inputs.append({"path": sub, "input_args": "preset-rtsp-generic", "roles": ["detect"]})
    if previous is not None:
        cam = previous
        cam.setdefault("ffmpeg", {})["inputs"] = inputs
        cam["enabled"] = True
    else:
        cam = {"enabled": True, "ffmpeg": {"inputs": inputs}, "detect": {"enabled": False, "fps": 5}}
    if data.get("cameras") is None:
        data["cameras"] = {}
    data["cameras"][name] = cam
    frigate_write_yaml(cfg, data)
    _camera_info_cache.pop(name, None)
    if replace:
        _camera_info_cache.pop(replace, None)
    with edit_config() as current:
        names = current.setdefault("camera_names", {})
        if replace and replace != name:
            names.pop(replace, None)
            current["ai"]["cameras"] = [name if c == replace else c for c in current["ai"]["cameras"]]
        names[name] = label
        if not replace and atmovio and name not in current["ai"]["cameras"]:
            current["ai"]["cameras"].append(name)
    rc, out = frigate_restart()
    verb = "upravena" if replace else "přidána"
    if back != "/cameras":
        back = f"/camera/{name}"
    flash(request, f"Kamera „{label}“ {verb} (ID ve Frigate: {name}), Frigate se restartuje – do minuty se objeví v Přehledu."
          + (" Ověřeno: " + "; ".join(notes) + "." if notes else "") + ("" if rc == 0 else f" (restart: {out})"))
    return RedirectResponse(back, status_code=303)


@app.post("/cameras/delete")
@frigate_transaction
def cameras_delete(request: Request, name: str = Form(...)):
    cfg = load_config()
    data = frigate_read_yaml(cfg)
    (data.get("cameras") or {}).pop(name, None)
    streams = data.get("go2rtc", {}).get("streams", {}) or {}
    streams.pop(name, None)
    streams.pop(f"{name}_sub", None)
    frigate_write_yaml(cfg, data)
    _camera_info_cache.pop(name, None)
    watcher.outages.pop(f"cam:{name}", None)
    with edit_config() as current:
        current["ai"]["cameras"] = [c for c in current["ai"]["cameras"] if c != name]
        if isinstance(current.get("camera_names"), dict):
            current["camera_names"].pop(name, None)
        ax = current["ai"].get("auto_export")
        if isinstance(ax, dict):
            ax["cameras"] = [c for c in (ax.get("cameras") or []) if c != name]
    frigate_restart()
    flash(request, f"Kamera {cam_label(cfg, name)} odebrána.")
    return RedirectResponse("/cameras", status_code=303)


# ---- storage

# --------------------------------------------------------------------------- disky pro záznamy

DATA_MNT = "/mnt/nvr"


def _system_disks() -> set:
    """Disky, na kterých leží systém (/, /boot, /boot/firmware) – těch se správa disků nikdy nedotkne."""
    names = set()
    for mp in ("/", "/boot/firmware", "/boot"):
        _rc, src = run(["findmnt", "-no", "SOURCE", mp], timeout=5)
        src = src.strip().split("[")[0]
        if not src.startswith("/dev/"):
            continue
        _rc, out = run(["lsblk", "-snro", "NAME,TYPE", src], timeout=5)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == "disk":
                names.add(parts[0])
    return names


def list_disks() -> list:
    """Externí disky (kromě systémových): oddíly, souborový systém, připojení, využití a co s nimi jde udělat."""
    _rc, out = run(["lsblk", "-J", "-b", "-o", "NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,MODEL,TRAN,PKNAME"], timeout=10)
    try:
        devices = json.loads(out)["blockdevices"]
    except Exception:
        return []
    system = _system_disks()
    system_mounts = {"/", "/boot", "/boot/firmware", "/usr", "/var", "/home", "/opt", "[SWAP]"}

    def mounts_of(node):
        yield node.get("mountpoint") or ""
        for child in node.get("children") or []:
            yield from mounts_of(child)

    disks = []
    for dev in devices:
        if dev.get("type") != "disk" or dev["name"] in system or dev["name"].startswith(("loop", "zram", "ram")):
            continue
        # Druhá pojistka nezávislá na /dev: disk, na kterém je připojený systém, se nikdy nenabídne.
        if any(mp in system_mounts for mp in mounts_of(dev)):
            continue
        if int(dev.get("size") or 0) < 1024 ** 3:  # drobná zařízení (čtečky, virtuální disky) nejsou disky pro záznamy
            continue
        parts = []
        for child in dev.get("children") or []:
            if child.get("type") != "part":
                continue
            parts.append({"dev": f"/dev/{child['name']}", "fstype": child.get("fstype") or "", "label": child.get("label") or "",
                          "size_h": human_bytes(child.get("size") or 0), "mountpoint": child.get("mountpoint") or ""})
        whole_fs = dev.get("fstype") or ""
        if whole_fs and not parts:
            parts.append({"dev": f"/dev/{dev['name']}", "fstype": whole_fs, "label": dev.get("label") or "",
                          "size_h": human_bytes(dev.get("size") or 0), "mountpoint": dev.get("mountpoint") or ""})
        nvr = next((p for p in parts if p["mountpoint"] == DATA_MNT), None)
        ext4 = [p for p in parts if p["fstype"] == "ext4"]
        mounted_elsewhere = [p for p in parts if p["mountpoint"] and p["mountpoint"] != DATA_MNT]
        if nvr:
            state = "nvr"
        elif ext4:
            state = "ready"
        elif parts:
            state = "foreign"
        else:
            state = "empty"
        usage = None
        if nvr:
            try:
                u = shutil.disk_usage(DATA_MNT)
                usage = {"total_h": human_bytes(u.total), "used_h": human_bytes(u.used), "free_h": human_bytes(u.free),
                         "pct": int(u.used * 100 / u.total) if u.total else 0}
            except Exception:
                pass
        disks.append({"name": dev["name"], "dev": f"/dev/{dev['name']}", "model": (dev.get("model") or "").strip(),
                      "tran": (dev.get("tran") or "").upper(), "size_h": human_bytes(dev.get("size") or 0),
                      "parts": parts, "state": state, "usage": usage,
                      "mounted_elsewhere": bool(mounted_elsewhere), "system": False})
    return disks


def _sh(cmd, timeout=120):
    rc, out = run(cmd, timeout=timeout)
    log(f"Disk: {' '.join(cmd) if isinstance(cmd, list) else cmd} → rc={rc}" + (f" {out[-200:]}" if out else ""))
    if rc != 0:
        raise RuntimeError(f"{cmd[0] if isinstance(cmd, list) else cmd}: {out[-300:] or 'chyba'}")
    return out


def prepare_disk(dev: str, do_format: bool) -> str:
    """Připraví externí disk pro záznamy: (volitelně) naformátuje na ext4, zapíše do fstab a připojí do /mnt/nvr.
    Stejný postup jako v instalátoru. Vrací lidsky čitelný výsledek; při chybě vyhodí RuntimeError."""
    disk = next((d for d in list_disks() if d["dev"] == dev), None)
    if not disk:
        raise RuntimeError("Tento disk není mezi externími disky (systémový disk nelze použít).")
    if disk["state"] == "nvr":
        return "Disk už je připojený jako disk pro záznamy."
    for p in disk["parts"]:
        if p["mountpoint"] and p["mountpoint"] != DATA_MNT:
            _sh(["umount", p["mountpoint"]], timeout=60)
    if do_format:
        _sh(["wipefs", "-a", dev], timeout=60)
        _sh(["parted", "-s", dev, "mklabel", "gpt", "mkpart", "primary", "ext4", "0%", "100%"], timeout=60)
        run(["partprobe", dev], timeout=30)
        time.sleep(3)
        run(["udevadm", "settle"], timeout=30)
        _rc, out = run(["lsblk", "-ln", "-o", "NAME,TYPE", dev], timeout=10)
        part = next((f"/dev/{ln.split()[0]}" for ln in out.splitlines() if len(ln.split()) == 2 and ln.split()[1] == "part"), "")
        if not part:
            raise RuntimeError("Po vytvoření oddílu ho systém nevidí – zkus disk odpojit a zapojit znovu.")
        _sh(["mkfs.ext4", "-F", "-q", "-L", "NVRDATA", "-m", "0", part], timeout=600)
    else:
        ext4 = [p for p in disk["parts"] if p["fstype"] == "ext4"]
        if not ext4:
            raise RuntimeError("Na disku není oddíl ext4 – použij Naformátovat.")
        part = next((p["dev"] for p in ext4 if p["label"] == "NVRDATA"), ext4[0]["dev"])
    _rc, uuid = run(["blkid", "-s", "UUID", "-o", "value", part], timeout=10)
    uuid = uuid.strip()
    if not uuid:
        raise RuntimeError(f"Nelze zjistit UUID oddílu {part}.")
    fstab = Path("/etc/fstab")
    backup = Path(f"/etc/fstab.nvr-{dt.datetime.now().strftime('%Y%m%d%H%M%S')}.bak")
    shutil.copy2(fstab, backup)
    lines = [ln for ln in fstab.read_text().splitlines() if f" {DATA_MNT} " not in f" {ln} ".replace("\t", " ")]
    lines.append(f"UUID={uuid}  {DATA_MNT}  ext4  defaults,noatime,nofail,x-systemd.device-timeout=20  0  2")
    fstab.write_text("\n".join(lines) + "\n")
    Path(DATA_MNT).mkdir(parents=True, exist_ok=True)
    run(["systemctl", "daemon-reload"], timeout=30)
    _sh(["mount", DATA_MNT], timeout=60)
    _rc, chk = run(["findmnt", "-no", "SOURCE,FSTYPE", DATA_MNT], timeout=5)
    if _rc != 0:
        raise RuntimeError("Disk se nepodařilo připojit do /mnt/nvr.")
    # Nikdy neuspávat (parkování hlav) – jako v instalátoru; USB boxy to někdy nepodporují, pak to jen přeskočíme.
    if run(["hdparm", "-S", "0", "-B", "254", dev], timeout=15)[0] != 0:
        run(["hdparm", "-S", "0", dev], timeout=15)
    try:
        conf = Path("/etc/hdparm.conf")
        if uuid not in (conf.read_text() if conf.exists() else ""):
            with conf.open("a") as f:
                f.write(f"\n# NVR – disk pro záznamy: nikdy neuspávat\n/dev/disk/by-uuid/{uuid} {{\n    spindown_time = 0\n    apm = 254\n}}\n")
    except Exception as e:
        log(f"Disk: hdparm.conf se nepodařilo upravit: {e}")
    run(["systemctl", "restart", "smartmontools.service"], timeout=30)  # S.M.A.R.T. hlídání nového disku
    u = shutil.disk_usage(DATA_MNT)
    log(f"Disk: {part} připojen do {DATA_MNT} ({human_bytes(u.total)} celkem, {human_bytes(u.free)} volných)")
    return f"Disk {part} je připravený a připojený ({human_bytes(u.total)} celkem, {human_bytes(u.free)} volných). Nahrávání se zapne samo do minuty."


@app.post("/storage/disk")
def storage_disk(request: Request, dev: str = Form(...), action: str = Form(...), confirm: str = Form("")):
    if not re.fullmatch(r"/dev/[a-z0-9]+", dev) or action not in ("mount", "format"):
        flash(request, "Neplatný požadavek.", "err")
        return RedirectResponse("/storage", status_code=303)
    if action == "format" and confirm.strip().upper() != "SMAZAT":
        flash(request, "Formátování smaže všechna data na disku. Pro potvrzení napiš do pole slovo SMAZAT.", "err")
        return RedirectResponse("/storage", status_code=303)
    try:
        msg = prepare_disk(dev, action == "format")
        flash(request, msg)
    except Exception as e:
        log(f"Disk: příprava {dev} selhala: {e}")
        flash(request, f"Disk se nepodařilo připravit: {e}", "err")
    return RedirectResponse("/storage", status_code=303)


@app.get("/storage", response_class=HTMLResponse)
def storage_page(request: Request):
    cfg = load_config()
    rec = Path(cfg["recordings_path"])
    sizes = {}
    cams = frigate_cameras(cfg)
    if storage_ready() and rec.exists():
        per_cam = {c: 0 for c in cams}
        for day in rec.iterdir():
            if not day.is_dir():
                continue
            for hour in day.iterdir():
                if not hour.is_dir():
                    continue
                for camdir in hour.iterdir():
                    if camdir.is_dir():
                        per_cam[camdir.name] = per_cam.get(camdir.name, 0) + dir_size(camdir)
        sizes = {c: {"size": human_bytes(s), "bytes": s, "active": c in cams} for c, s in sorted(per_cam.items())}
    return render(request, "storage.html", "Záznamy", retain_days=retain_days(cfg), disk=disk_info(cfg["recordings_path"]),
                  sizes=sizes, cameras=sorted(set(cams) | set(sizes)), disks=list_disks(), ready=storage_ready())


@app.post("/storage/retain")
@frigate_transaction
def storage_retain(request: Request, days: int = Form(...)):
    cfg = load_config()
    days = max(1, min(60, days))
    data = frigate_read_yaml(cfg)
    rec = data.setdefault("record", {})
    rec["enabled"] = True
    # Frigate 0.17 nahradilo record.retain sekcí record.continuous – starý klíč by shodil Frigate do nouzového režimu.
    rec.pop("retain", None)
    rec.setdefault("continuous", {})["days"] = days
    for k in ("alerts", "detections"):
        rec.setdefault(k, {}).setdefault("retain", {})["days"] = days
        rec[k]["retain"].pop("mode", None)
    frigate_write_yaml(cfg, data)
    frigate_restart()
    flash(request, f"Retence nastavena na {days} dní, Frigate se restartuje.")
    return RedirectResponse("/storage", status_code=303)


def delete_recordings(cfg, camera, start, end, now=None):
    """Maže pouze MP4 v uzavřených hodinách, bez následování symbolických odkazů."""
    if not storage_ready():
        raise ValueError("HDD není připravený; mazání není dostupné.")
    if camera != "*" and not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera):
        raise ValueError("Neplatný název kamery.")
    if end < start:
        raise ValueError("Konec je před začátkem.")
    rec = Path(cfg["recordings_path"]).resolve()
    tz = ZoneInfo(cfg["tz"])
    current_hour = (now or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    removed = freed = 0
    if rec.exists():
        for day in rec.iterdir():
            if day.is_symlink() or not day.is_dir():
                continue
            try:
                dd = dt.date.fromisoformat(day.name)
            except ValueError:
                continue
            for hour in day.iterdir():
                if hour.is_symlink() or not hour.is_dir() or not re.fullmatch(r"[0-2][0-9]", hour.name) or int(hour.name) > 23:
                    continue
                utc_hour = dt.datetime.combine(dd, dt.time(int(hour.name)), tzinfo=dt.timezone.utc)
                local_hour = utc_hour.astimezone(tz).replace(tzinfo=None)
                if utc_hour >= current_hour or not (start <= local_hour <= end):
                    continue
                targets = [hour / camera] if camera != "*" else [p for p in hour.iterdir() if p.is_dir()]
                for tdir in targets:
                    if tdir.is_symlink() or not tdir.is_dir() or rec not in tdir.resolve().parents:
                        continue
                    for segment in tdir.glob("*.mp4"):
                        if segment.is_symlink() or not segment.is_file():
                            continue
                        try:
                            size = segment.stat().st_size
                            segment.unlink()
                        except FileNotFoundError:
                            continue  # Frigate mezitím provedlo vlastní retenci.
                        freed += size
                        removed += 1
                    try:
                        tdir.rmdir()  # Jen prázdný adresář; jiné soubory zůstanou.
                    except OSError:
                        pass
                try:
                    if not any(hour.iterdir()):
                        hour.rmdir()
                except OSError:
                    pass
            try:
                if not any(day.iterdir()):
                    day.rmdir()
            except OSError:
                pass
    return removed, freed


@app.post("/storage/delete")
def storage_delete(request: Request, camera: str = Form("*"), from_date: str = Form(...), from_hour: int = Form(0),
                   to_date: str = Form(...), to_hour: int = Form(23)):
    cfg = load_config()
    try:
        start = dt.datetime.combine(dt.date.fromisoformat(from_date), dt.time(from_hour))
        end = dt.datetime.combine(dt.date.fromisoformat(to_date), dt.time(to_hour))
        removed, freed = delete_recordings(cfg, camera, start, end)
        flash(request, f"Smazáno {removed} souborů ({human_bytes(freed)}). Aktuální hodina se nemaže. Frigate synchronizuje databázi při restartu nebo denní kontrole.")
    except (ValueError, OSError) as e:
        flash(request, f"Mazání zastaveno: {e}. Některé soubory již mohly být smazány.", "err")
    return RedirectResponse("/storage", status_code=303)


@app.post("/storage/delete-camera")
def storage_delete_camera(request: Request, camera: str = Form(...)):
    """Smaže všechny záznamy jedné kamery (i kamery, která už není nastavená) a prázdné složky po ní."""
    cfg = load_config()
    try:
        removed, freed = delete_recordings(cfg, camera, dt.datetime(2000, 1, 1), dt.datetime(2100, 1, 1))
        rec = Path(cfg["recordings_path"]).resolve()
        for day in rec.iterdir() if rec.exists() else []:
            if day.is_symlink() or not day.is_dir():
                continue
            for hour in day.iterdir():
                d = hour / camera
                if hour.is_dir() and not hour.is_symlink() and d.is_dir() and not d.is_symlink() and not any(d.iterdir()):
                    d.rmdir()
                if hour.is_dir() and not hour.is_symlink() and not any(hour.iterdir()):
                    hour.rmdir()
            if not any(day.iterdir()):
                day.rmdir()
        active = camera in frigate_cameras(cfg)
        flash(request, f"Smazáno {removed} souborů ({human_bytes(freed)}) kamery {cam_label(cfg, camera)}."
              + (" Aktuální hodina zůstala (nahrává se)." if active else "")
              + " Frigate si databázi srovná při restartu nebo denní kontrole.")
    except (ValueError, OSError) as e:
        flash(request, f"Mazání zastaveno: {e}. Některé soubory již mohly být smazány.", "err")
    return RedirectResponse("/storage", status_code=303)


# ---- AI

def sun_times(cfg, now) -> dict:
    sr, ss = daylight_window(cfg, now.date())
    dawn, dusk = watch_window(cfg, now.date())
    return {"sunrise": sr.strftime("%H:%M"), "sunset": ss.strftime("%H:%M"), "dawn": dawn.strftime("%H:%M"), "dusk": dusk.strftime("%H:%M")}


def ai_estimate(cfg, cameras: int) -> int:
    """Hrubý odhad dotazů za den při běžném a rychlém intervalu (bez předfiltru)."""
    ai = cfg["ai"]
    tz = ZoneInfo(cfg["tz"])
    dawn, dusk = watch_window(cfg, dt.datetime.now(tz).date())
    day_min = (dusk - dawn).total_seconds() / 60
    fast_min = 4 * int(ai.get("golden_min", 60)) if ai.get("fast_mode") else 0
    fast_min = min(fast_min, day_min)
    normal = max(1, int(ai["interval_min"]))
    fast = max(1, int(ai.get("fast_interval_min", 3)))
    return int(cameras * ((day_min - fast_min) / normal + fast_min / fast))


@app.get("/ai", response_class=HTMLResponse)
def ai_page(request: Request):
    cfg = load_config()
    test = request.session.pop("ai_test", None)
    check = request.session.pop("ai_check", None)
    now = dt.datetime.now(ZoneInfo(cfg["tz"]))
    sr, ss = daylight_window(cfg, now.date())
    cameras = frigate_cameras(cfg)
    return render(request, "ai.html", "AI hlídání oblohy", cfg=cfg, ai=cfg["ai"], cameras=cameras, test=test, check=check,
                  providers=PROVIDERS, provider_info=PROVIDER_INFO, phenomena=phenomena_catalog(cfg["ai"]), custom_phenomena=cfg["ai"].get("custom_phenomena") or [],
                  cam_rules=cfg["ai"].get("cam_rules") or {}, used_today=watcher.calls_today(cfg, now), stats7=ai_stats_days(now, 7),
                  sun=sun_times(cfg, now), estimate=ai_estimate(cfg, max(1, len(cfg["ai"]["cameras"]))))


@app.post("/ai")
async def ai_save(request: Request):
    form = await request.form()
    try:
        await run_in_threadpool(save_ai_form, form)
        flash(request, "Nastavení AI uloženo.")
    except ValueError as e:
        flash(request, str(e), "err")
    tab = str(form.get("tab") or "")
    return RedirectResponse("/ai" + (f"#{tab}" if re.fullmatch(r"[a-z]+", tab) else ""), status_code=303)


@app.post("/ai/check")
async def ai_check_route(request: Request):
    form = await request.form()
    try:
        await run_in_threadpool(save_ai_form, form)
        ai = load_config()["ai"]
        result = await run_in_threadpool(ai_check, ai)
        request.session["ai_check"] = result
        flash(request, "Nastavení uloženo, klíč ověřen.")
    except ValueError as e:
        flash(request, str(e), "err")
    except Exception as e:
        request.session["ai_check"] = f"Ověření selhalo: {e}"
        flash(request, "Nastavení uloženo, ale ověření klíče selhalo – viz výpis níže.", "err")
    return RedirectResponse("/ai", status_code=303)


def save_ai_form(form):
    cameras = frigate_cameras(load_config())
    with edit_config() as cfg:
        apply_ai_form(form, cfg, cameras)


def apply_ai_form(form, cfg, cameras):
    ai = cfg["ai"]
    old_provider = ai["provider"]
    for key in ("enabled", "day_only", "prefilter", "fast_mode", "dark_skip"):
        ai[key] = bool(form.get(key))
    if form.get("twilight") in ("civil", "nautical", "astronomical", "minutes"):
        ai["twilight"] = form.get("twilight")
    for k, typ, lo, hi in (("interval_min", int, 1, 1440), ("fast_interval_min", int, 1, 60), ("golden_min", int, 0, 180),
                           ("margin_min", int, 0, 240), ("threshold", int, 1, 10), ("cooldown_min", int, 0, 1440),
                           ("episode_gap_min", int, 5, 1440), ("daily_limit", int, 0, 100000), ("dark_level", int, 0, 120),
                           ("keep_days", int, 1, 365), ("prefilter_diff", float, 0, 255)):
        try:
            ai[k] = max(lo, min(hi, typ(str(form.get(k, ai[k])).replace(",", "."))))
        except ValueError:
            pass
    for k in ("provider", "model", "api_key", "ollama_url", "base_url", "prompt_extra"):
        ai[k] = str(form.get(k, ai[k])).strip()
    if ai["provider"] not in PROVIDER_MODELS:
        raise ValueError("Neznámý poskytovatel AI.")
    if not ai["model"] or (old_provider != ai["provider"] and ai["model"] == PROVIDER_MODELS.get(old_provider)):
        ai["model"] = PROVIDER_MODELS.get(ai["provider"], "")
    try:
        cfg["lat"] = float(str(form.get("lat", cfg["lat"])).replace(",", "."))
        cfg["lon"] = float(str(form.get("lon", cfg["lon"])).replace(",", "."))
    except ValueError:
        raise ValueError("Zeměpisné souřadnice musí být čísla.")
    if not (-90 <= cfg["lat"] <= 90 and -180 <= cfg["lon"] <= 180):
        raise ValueError("Zeměpisná šířka musí být −90 až 90 a délka −180 až 180.")
    ai["cameras"] = [c for c in cameras if form.get(f"cam_{c}")]
    ax = dict(ai.get("auto_export") or DEFAULT_CONFIG["ai"]["auto_export"])
    ax["enabled"] = bool(form.get("ax_enabled"))
    for k, key in (("before_min", "ax_before"), ("after_min", "ax_after")):
        try:
            ax[k] = max(0, min(60, int(form.get(key, ax.get(k, 2)))))
        except (TypeError, ValueError):
            pass
    ax["playback"] = "timelapse_25x" if form.get("ax_playback") == "timelapse_25x" else "realtime"
    ax["cameras"] = [c for c in cameras if form.get(f"ax_cam_{c}")]
    ai["auto_export"] = ax
    ids = [p[0] for p in phenomena_catalog(ai)]
    if any(k.startswith("ph_") for k in form.keys()) or form.get("provider"):
        chosen = [p for p in ids if form.get(f"ph_{p}")]
        ai["phenomena"] = chosen or list(ids)
        ai["any_photogenic"] = bool(form.get("any_photo"))
    # vlastní pravidla kamer (práh + jevy); "použít výchozí" = žádné vlastní
    rules = {}
    for c in cameras:
        if form.get(f"mode_{c}") == "custom":
            try:
                thr = max(1, min(10, int(form.get(f"thr_{c}", ai["threshold"]))))
            except (TypeError, ValueError):
                thr = int(ai["threshold"])
            rules[c] = {"custom": True, "threshold": thr, "phenomena": [p for p in ids if form.get(f"cph_{c}_{p}")] or list(ai["phenomena"]),
                        "any": bool(form.get(f"cany_{c}"))}
    ai["cam_rules"] = rules


@app.post("/ai/phenomena/add")
def ai_phenomena_add(request: Request, label: str = Form(...), desc: str = Form("")):
    label = label.strip()[:60]
    desc = desc.strip()[:300]
    if len(label) < 2:
        flash(request, "Název jevu je moc krátký.", "err")
        return RedirectResponse("/ai#kamery", status_code=303)
    pid = "c_" + (slugify(label)[:24] or "jev")
    with edit_config() as cfg:
        ai = cfg["ai"]
        custom = [c for c in (ai.get("custom_phenomena") or []) if c.get("id") != pid]
        custom.append({"id": pid, "label": label, "desc": desc or label})
        ai["custom_phenomena"] = custom
        if pid not in (ai.get("phenomena") or []):
            ai["phenomena"] = list(ai.get("phenomena") or PHENOMENA_IDS) + [pid]
    flash(request, f"Jev „{label}“ přidán – AI ho od teď hledá na snímcích.")
    return RedirectResponse("/ai#kamery", status_code=303)


@app.post("/ai/phenomena/delete")
def ai_phenomena_delete(request: Request, pid: str = Form(...)):
    with edit_config() as cfg:
        ai = cfg["ai"]
        ai["custom_phenomena"] = [c for c in (ai.get("custom_phenomena") or []) if c.get("id") != pid]
        ai["phenomena"] = [p for p in (ai.get("phenomena") or []) if p != pid]
        for r in (ai.get("cam_rules") or {}).values():
            r["phenomena"] = [p for p in (r.get("phenomena") or []) if p != pid]
    flash(request, "Vlastní jev odebrán.")
    return RedirectResponse("/ai#kamery", status_code=303)


@app.post("/ai/reset_prompt")
def ai_reset_prompt(request: Request):
    with edit_config() as cfg:
        cfg["ai"]["prompt_extra"] = ""
    flash(request, "Doplňující pokyny vymazány.")
    return RedirectResponse("/ai", status_code=303)


@app.post("/ai/test")
def ai_test(request: Request, camera: str = Form(...), back: str = Form("")):
    cfg = load_config()
    back = _back_url(back, "/ai")
    if camera not in frigate_cameras(cfg):
        flash(request, "Vyber existující kameru.", "err")
        return RedirectResponse(back, status_code=303)
    now = dt.datetime.now(ZoneInfo(cfg["tz"]))
    r = watcher.check_camera(cfg, camera, now, force=True)
    r.pop("raw", None)
    if r.get("phenomena"):
        r["phenomena"] = [phen_labels(cfg["ai"]).get(p, p) for p in r["phenomena"]]
    request.session["ai_test"] = json.dumps(r, ensure_ascii=False, indent=2)
    return RedirectResponse(back, status_code=303)


@app.get("/history", response_class=HTMLResponse)
def history(request: Request, camera: str = "", min_score: int = 0, show: str = "notified", page: int = 1):
    cfg = load_config()
    per_page = 30
    page = max(1, int(page or 1))
    if show not in ("notified", "all", "errors"):
        show = "notified"
    q = "SELECT e.*, (SELECT COUNT(*) FROM exports x WHERE x.detection_id=e.id) AS exported FROM evaluations e WHERE skipped=0"
    args: list = []
    if camera:
        q += " AND camera=?"
        args.append(camera)
    if min_score:
        q += " AND score>=?"
        args.append(min_score)
    if show == "notified":
        q += " AND notified=1"
    elif show == "errors":
        q += " AND error IS NOT NULL AND error != ''"
    count_q = "SELECT COUNT(*) FROM evaluations e WHERE skipped=0" + q.split("WHERE skipped=0", 1)[1]
    q += " ORDER BY id DESC LIMIT ? OFFSET ?"
    with db() as con:
        total = con.execute(count_q, args).fetchone()[0]
        pages = max(1, (total + per_page - 1) // per_page)
        page = min(page, pages)
        rows = [dict(r) for r in con.execute(q, args + [per_page, (page - 1) * per_page])]
    return render(request, "history.html", "Historie vyhodnocení", rows=rows, cameras=frigate_cameras(cfg),
                  total=total, pages=pages, page=page, per_page=per_page,
                  f_cam=camera, f_min=min_score, f_show=show, keep_days=cfg["ai"].get("keep_days", 14), threshold=int(cfg["ai"].get("threshold", 7)),
                  subtitle="Co AI na obloze viděla – s upozorněním, nebo úplně vše.")


@app.get("/detection/{rid}", response_class=HTMLResponse)
def detection_page(request: Request, rid: int):
    cfg = load_config()
    with db() as con:
        row = con.execute("SELECT * FROM evaluations WHERE id=?", (rid,)).fetchone()
    if not row:
        flash(request, "Detekce už neexistuje.", "err")
        return RedirectResponse("/history", status_code=303)
    e = dict(row)
    try:
        t = dt.datetime.fromisoformat(e["ts"])
    except ValueError:
        t = dt.datetime.now()
    t = t.replace(tzinfo=None)
    phen = [phen_labels(cfg["ai"]).get(x, x) for x in (e.get("phenomena") or "").split(",") if x]
    def qint(key, default):
        try:
            return max(0, min(60, int(request.query_params.get(key, default) or 0)))
        except ValueError:
            return default
    before, after = qint("before", 2), qint("after", 1)
    center = eval_epoch(cfg, e["ts"])
    with db() as con:
        earlier = [dict(r) for r in con.execute(
            "SELECT id, ts, camera, score, phenomenon, image, notified FROM evaluations WHERE id<? AND notified=1 AND image IS NOT NULL ORDER BY id DESC LIMIT 4",
            (rid,))]
        later = [dict(r) for r in con.execute(
            "SELECT id, ts, camera, score, phenomenon, image, notified FROM evaluations WHERE id>? AND notified=1 AND image IS NOT NULL ORDER BY id ASC LIMIT 4",
            (rid,))]
        my_exports = [dict(r) for r in con.execute("SELECT * FROM exports WHERE detection_id=? ORDER BY id DESC", (rid,))]
    neighbours = list(reversed(earlier)) + later
    clip_state = recording_state(cfg, e["camera"], center - before * 60, center + after * 60) if storage_ready() else "nodisk"
    # Hotové vystřižené video z této detekce se přehrává přednostně (plynule, se správným posuvníkem);
    # surový úsek z Frigate jen když si uživatel zadá vlastní rozsah.
    use_export = None
    if my_exports and "before" not in request.query_params and "after" not in request.query_params:
        ready = [v for v in list_videos(cfg) if v.get("detection_id") == rid and v.get("ready")]
        use_export = ready[0] if ready else None
    default_name = f"{cam_label(cfg, e['camera'])} {e['ts'][8:10]}.{e['ts'][5:7]}.{e['ts'][0:4]} {e['ts'][11:16]}" + (f" – {e['phenomenon']}" if e.get("phenomenon") else "")
    return render(request, "detection.html", f"Detekce · {cam_label(cfg, e['camera'])}", e=e, phen=phen, info=camera_info(cfg, e["camera"]),
                  before=before, after=after, clip_start=center - before * 60, clip_end=center + after * 60,
                  neighbours=neighbours, my_exports=my_exports, default_name=default_name, ready=storage_ready(), clip_state=clip_state, retain=retain_days(cfg),
                  pending_auto=pending_auto_exports(cfg, rid), e_center=center, use_export=use_export,
                  subtitle="Snímek a záznam kolem něj. Video si přehraješ rovnou tady, nebo si ho nech vystřihnout ke stažení.")


# --------------------------------------------------------------------------- video: přehrávání a exporty

def eval_epoch(cfg, ts: str) -> float:
    """Čas vyhodnocení (ISO, s pásmem nebo bez) → unixový čas."""
    t = dt.datetime.fromisoformat(ts)
    if t.tzinfo is None:
        t = t.replace(tzinfo=ZoneInfo(cfg["tz"]))
    return t.timestamp()


def recording_state(cfg, camera: str, start: float, end: float) -> str:
    """'ok' = záznam pro daný úsek existuje; 'none' = pro ten čas není; 'offline' = Frigate neodpovídá."""
    try:
        r = frigate_api(cfg, f"/api/{camera}/recordings?after={start:.0f}&before={end:.0f}", timeout=8)
        if not r.ok:
            return "offline" if r.status_code >= 500 else "none"
        return "ok" if r.json() else "none"
    except Exception:
        return "offline"


def frigate_media_path(path: str) -> Path | None:
    """Cesta uvnitř kontejneru (/media/frigate/…) → cesta na HDD."""
    if not path:
        return None
    p = str(path)
    if p.startswith("/media/frigate/"):
        return Path(DATA_MNT) / "frigate" / p[len("/media/frigate/"):]
    if p.startswith("exports/") or p.startswith("clips/"):
        return Path(DATA_MNT) / "frigate" / p
    return None


def frigate_exports(cfg) -> dict:
    """Exporty známé Frigate: id → záznam (video_path, thumb_path, in_progress…)."""
    try:
        r = frigate_api(cfg, "/api/exports", timeout=8)
        if r.ok:
            return {x.get("id"): x for x in r.json() if isinstance(x, dict)}
    except Exception:
        pass
    return {}


def export_thumb_path(cfg, rec: dict, fr: dict | None) -> Path | None:
    """Náhled videa: nejdřív ten od Frigate, jinak si ho Atmovio vyrobí ffmpegem (a uloží na HDD)."""
    if fr and fr.get("thumb_path"):
        p = frigate_media_path(fr["thumb_path"])
        if p and p.is_file():
            return p
    own = Path(cfg["snapshot_dir"]) / "exports" / f"{rec['id']}.jpg"
    if own.is_file():
        return own
    video = frigate_media_path((fr or {}).get("video_path", "")) if fr else None
    if video and video.is_file() and not (fr or {}).get("in_progress"):
        own.parent.mkdir(parents=True, exist_ok=True)
        rc, _out = run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-ss", "1", "-i", str(video), "-frames:v", "1",
                        "-vf", "scale=640:-2", "-q:v", "4", str(own)], timeout=60)
        if rc == 0 and own.is_file():
            return own
    return None


def list_videos(cfg) -> list:
    """Seznam exportů pro stránku Videa (stav, velikost, náhled)."""
    fr_all = frigate_exports(cfg)
    keep = int(cfg.get("export_keep_days", 30) or 30)
    try:
        retain_cutoff = time.time() - retain_days(cfg) * 86400
    except Exception:
        retain_cutoff = 0
    with db() as con:
        rows = [dict(r) for r in con.execute("SELECT * FROM exports ORDER BY id DESC")]
    out = []
    for rec in rows:
        fr = fr_all.get(rec["frigate_id"])
        video = frigate_media_path(fr.get("video_path", "")) if fr else None
        size = video.stat().st_size if video and video.is_file() else 0
        try:
            age_days = (dt.datetime.now() - dt.datetime.fromisoformat(rec["created"])).total_seconds() / 86400
        except ValueError:
            age_days = 0
        tz = ZoneInfo(cfg["tz"])
        t0 = dt.datetime.fromtimestamp(rec["start_ts"], tz)
        t1 = dt.datetime.fromtimestamp(rec["end_ts"], tz)
        in_progress = bool(fr and fr.get("in_progress"))
        stuck = bool(in_progress and age_days * 24 >= 2 or (fr is None and not video and age_days * 24 >= 2))
        rec.update(in_progress=in_progress, stuck=stuck, expired=bool(stuck and rec["start_ts"] < retain_cutoff),
                   ready=bool(video and video.is_file() and not (fr or {}).get("in_progress")),
                   missing=fr is None, size_h=human_size(size) if size else "",
                   duration_min=round((rec["end_ts"] - rec["start_ts"]) / 60, 1),
                   duration_h=human_minutes(rec["end_ts"] - rec["start_ts"]),
                   range_h=f"{t0.day}. {t0.month}. {t0.year} {t0:%H:%M}–{t1:%H:%M}",
                   days_left=max(0, int(keep - age_days)),
                   thumb_path=str(export_thumb_path(cfg, rec, fr) or ""))
        rec["thumb"] = bool(rec["thumb_path"])
        out.append(rec)
    return out


def delete_export(cfg, rec: dict):
    try:
        requests.delete(cfg["frigate_url"].rstrip("/") + f"/api/export/{rec['frigate_id']}", timeout=15)
    except Exception as e:
        log(f"Export {rec['frigate_id']}: smazání ve Frigate selhalo: {e}")
    own = Path(cfg["snapshot_dir"]) / "exports" / f"{rec['id']}.jpg"
    own.unlink(missing_ok=True)
    with db() as con:
        con.execute("DELETE FROM exports WHERE id=?", (rec["id"],))


def cleanup_exports(cfg):
    """Videa starší než export_keep_days se mažou (i ve Frigate). Volá watcher 1× za hodinu."""
    keep = int(cfg.get("export_keep_days", 30) or 30)
    cutoff = (dt.datetime.now() - dt.timedelta(days=keep)).isoformat()
    with db() as con:
        old = [dict(r) for r in con.execute("SELECT * FROM exports WHERE created < ?", (cutoff,))]
    for rec in old:
        delete_export(cfg, rec)
        log(f"Video „{rec['name']}“ smazáno – starší než {keep} dní")
    with db() as con:
        old_s = [dict(r) for r in con.execute("SELECT * FROM studio_videos WHERE created < ? AND status <> 'rendering'", (cutoff,))]
    for row in old_s:
        studio_delete(cfg, row)
        log(f"Studio: video „{row['title'] or row['name']}“ smazáno – starší než {keep} dní")


@app.get("/clip/{camera}.mp4")
def clip_proxy(request: Request, camera: str, start: float, end: float):
    """Přehrání úseku záznamu přímo ve Atmovio – proxy na Frigate (bez hesla, jen pro přihlášené)."""
    if not re.fullmatch(r"[a-zA-Z0-9_]{1,64}", camera) or end <= start or end - start > 3600:
        return JSONResponse({"error": "bad range"}, status_code=400)
    cfg = load_config()
    url = f"{cfg['frigate_url'].rstrip('/')}/api/{camera}/start/{start:.0f}/end/{end:.0f}/clip.mp4"
    headers = {}
    if request.headers.get("range"):
        headers["Range"] = request.headers["range"]
    try:
        r = requests.get(url, headers=headers, stream=True, timeout=(10, 120))
    except Exception:
        return JSONResponse({"error": "frigate"}, status_code=502)
    if r.status_code >= 400:
        return JSONResponse({"error": "no recording"}, status_code=404)
    passthrough = {k: v for k, v in r.headers.items() if k.lower() in ("content-length", "content-range", "accept-ranges", "content-type")}
    passthrough.setdefault("Content-Type", "video/mp4")
    return StreamingResponse(r.iter_content(chunk_size=256 * 1024), status_code=r.status_code, headers=passthrough)


def frigate_start_export(cfg, camera: str, start: float, end: float, name: str, playback: str = "realtime") -> str:
    """Zadá Frigate vystřižení videa; vrací export_id nebo vyhodí výjimku s česky srozumitelnou zprávou."""
    r = requests.post(f"{cfg['frigate_url'].rstrip('/')}/api/export/{camera}/start/{start:.0f}/end/{end:.0f}",
                      json={"playback": "timelapse_25x" if playback == "timelapse_25x" else "realtime", "source": "recordings", "name": name},
                      timeout=20)
    data = r.json() if r.content else {}
    if not r.ok or not data.get("success", True) or not data.get("export_id"):
        raise RuntimeError(data.get("message") or f"HTTP {r.status_code}")
    return str(data["export_id"])


def record_export(cfg, frigate_id: str, detection_id, camera: str, name: str, start: float, end: float, auto: int = 0) -> int:
    with db() as con:
        cur = con.execute("INSERT INTO exports (frigate_id, detection_id, camera, name, start_ts, end_ts, created, auto) VALUES (?,?,?,?,?,?,?,?)",
                          (frigate_id, detection_id, camera, name, start, end, dt.datetime.now().isoformat(timespec="seconds"), auto))
        return int(cur.lastrowid)


def schedule_auto_export(cfg, rid: int, camera: str, now, labels: str):
    """Po odeslaném upozornění naplánuje automatické video ±X minut kolem snímku (vytvoří se, až záznam „po“ doběhne)."""
    ax = cfg["ai"].get("auto_export") or {}
    before = max(0, min(60, int(ax.get("before_min", 2) or 0)))
    after = max(0, min(60, int(ax.get("after_min", 3) or 0)))
    if before + after == 0:
        after = 1
    center = now.timestamp()
    start, end = center - before * 60, center + after * 60
    name = f"{cam_label(cfg, camera)} {now.strftime('%d.%m.%Y %H:%M')} – {labels}"[:80]
    playback = "timelapse_25x" if ax.get("playback") == "timelapse_25x" else "realtime"
    if playback == "timelapse_25x":
        name = (name + " (25×)")[:90]
    with db() as con:
        con.execute("INSERT INTO auto_exports (detection_id, camera, name, start_ts, end_ts, due_ts, playback, created) VALUES (?,?,?,?,?,?,?,?)",
                    (rid, camera, name, start, end, end + 45, playback, dt.datetime.now().isoformat(timespec="seconds")))
    log(f"[{camera}] Automatické video „{name}“ naplánováno (−{before}/+{after} min), vytvoří se v {dt.datetime.fromtimestamp(end + 45, ZoneInfo(cfg['tz'])).strftime('%H:%M')}")


def pending_auto_exports(cfg, detection_id=None) -> list:
    tz = ZoneInfo(cfg["tz"])
    q = "SELECT * FROM auto_exports WHERE status='pending'" + (" AND detection_id=?" if detection_id else "") + " ORDER BY due_ts"
    with db() as con:
        rows = [dict(r) for r in con.execute(q, (detection_id,) if detection_id else ())]
    for r in rows:
        r["due_h"] = dt.datetime.fromtimestamp(r["due_ts"], tz).strftime("%H:%M")
    return rows


def process_auto_exports(cfg):
    """Vytvoří naplánovaná automatická videa, jejichž čas nastal (volá smyčka každých 20 s)."""
    now = time.time()
    with db() as con:
        due = [dict(r) for r in con.execute("SELECT * FROM auto_exports WHERE status='pending' AND due_ts <= ? ORDER BY id", (now,))]
    for job in due:
        state = recording_state(cfg, job["camera"], job["start_ts"], job["end_ts"])
        if state == "offline":
            if now - job["due_ts"] < 900:
                continue  # Frigate zrovna neběží – zkusit později (max 15 min)
            _auto_export_finish(job, "failed", "Frigate neodpovídal 15 minut po detekci")
            continue
        if state == "none":
            _auto_export_finish(job, "failed", "pro tento čas není záznam (kamera nenahrávala)")
            continue
        try:
            fid = frigate_start_export(cfg, job["camera"], job["start_ts"], job["end_ts"], job["name"], job["playback"])
        except Exception as e:
            _auto_export_finish(job, "failed", str(e))
            continue
        record_export(cfg, fid, job["detection_id"], job["camera"], job["name"], job["start_ts"], job["end_ts"], auto=1)
        _auto_export_finish(job, "done", fid)
        log(f"[{job['camera']}] Automatické video „{job['name']}“ zadáno k vytvoření ({fid})")


def resume_killed_exports(cfg, fs: dict):
    """Export, který Frigate rozdělal a pak byl restartován (aktualizace, výpadek proudu), už nikdy nedoběhne.
    Pozná se podle toho, že Frigate běží kratší dobu, než je export starý → zadat znovu (max. 2×)."""
    if not fs.get("online") or not fs.get("uptime"):
        return
    frigate_started = time.time() - float(fs["uptime"])
    with db() as con:
        rows = [dict(r) for r in con.execute("SELECT * FROM exports")]
    if not rows:
        return
    fr_all = frigate_exports(cfg)
    for rec in rows:
        try:
            created = dt.datetime.fromisoformat(rec["created"]).timestamp()
        except ValueError:
            continue
        if created > frigate_started - 5 or time.time() - created < 120:
            continue            # zadáno až po startu Frigate (nebo před chvílí) – nechat dobíhat
        fr = fr_all.get(rec["frigate_id"])
        video = frigate_media_path(fr.get("video_path", "")) if fr else None
        if fr and not fr.get("in_progress") and video and video.is_file():
            continue            # hotové
        if int(rec.get("retries") or 0) >= 2:
            continue            # už jsme to zkoušeli – nechat na uživateli (Vytvořit znovu / Smazat)
        state = recording_state(cfg, rec["camera"], rec["start_ts"], rec["end_ts"])
        if state != "ok":
            continue
        try:
            requests.delete(cfg["frigate_url"].rstrip("/") + f"/api/export/{rec['frigate_id']}", timeout=15)
        except Exception:
            pass
        try:
            new_id = frigate_start_export(cfg, rec["camera"], rec["start_ts"], rec["end_ts"], rec["name"])
        except Exception as e:
            log(f"Video „{rec['name']}“ se po restartu Frigate nepodařilo zadat znovu: {e}")
            continue
        with db() as con:
            con.execute("UPDATE exports SET frigate_id=?, created=?, retries=COALESCE(retries,0)+1 WHERE id=?",
                        (new_id, dt.datetime.now().isoformat(timespec="seconds"), rec["id"]))
        log(f"[{rec['camera']}] Video „{rec['name']}“ zadáno znovu – Frigate byl restartován uprostřed exportu")


def _auto_export_finish(job: dict, status: str, message: str):
    with db() as con:
        con.execute("UPDATE auto_exports SET status=?, message=? WHERE id=?", (status, message, job["id"]))
    if status == "failed":
        log(f"[{job['camera']}] Automatické video „{job['name']}“ se nepodařilo vytvořit: {message}")
        add_event("warn", f"Automatické video nevzniklo: {job['name']}", message)


@app.post("/detection/{rid}/export")
def detection_export(request: Request, rid: int, name: str = Form(""), before: int = Form(2), after: int = Form(1), playback: str = Form("realtime")):
    cfg = load_config()
    if not storage_ready():
        flash(request, "Video nelze vytvořit – disk pro záznamy není připojený.", "err")
        return RedirectResponse(f"/detection/{rid}", status_code=303)
    with db() as con:
        row = con.execute("SELECT * FROM evaluations WHERE id=?", (rid,)).fetchone()
    if not row:
        flash(request, "Detekce už neexistuje.", "err")
        return RedirectResponse("/history", status_code=303)
    e = dict(row)
    before = max(0, min(60, before)); after = max(0, min(60, after))
    if before + after == 0:
        after = 1
    center = eval_epoch(cfg, e["ts"])
    start, end = center - before * 60, center + after * 60
    label = " ".join(name.split())[:80] or f"{cam_label(cfg, e['camera'])} {e['ts'][8:10]}.{e['ts'][5:7]}.{e['ts'][0:4]} {e['ts'][11:16]}" + (f" – {e['phenomenon']}" if e.get("phenomenon") else "")
    timelapse = playback == "timelapse_25x"
    if timelapse and "25×" not in label:
        label = (label + " (25×)")[:90]
    try:
        export_id = frigate_start_export(cfg, e["camera"], start, end, label, "timelapse_25x" if timelapse else "realtime")
    except Exception as ex:
        flash(request, f"Video se nepodařilo vytvořit: {ex}. Pro tento čas možná chybí záznam (kamera nenahrávala).", "err")
        return RedirectResponse(f"/detection/{rid}", status_code=303)
    record_export(cfg, export_id, rid, e["camera"], label, start, end)
    log(f"Video „{label}“ ({before + after} min{', timelapse 25×' if timelapse else ''}) zadáno k vytvoření ({export_id})")
    if timelapse:
        flash(request, f"Zrychlené video „{label}“ se vytváří – Raspberry Pi překóduje {before + after} min záznamu, počítej s několika minutami. Objeví se tady v seznamu.")
    else:
        flash(request, f"Video „{label}“ se vytváří ({before + after} min záznamu). Za chvíli bude ke stažení – tady v seznamu.")
    return RedirectResponse("/videos", status_code=303)


@app.get("/videos", response_class=HTMLResponse)
def videos_page(request: Request):
    cfg = load_config()
    return render(request, "videos.html", "Videa", videos=list_videos(cfg), keep_days=int(cfg.get("export_keep_days", 30) or 30),
                  ready=storage_ready(), studio=studio_rows(cfg), studio_auto=bool(studio_cfg(cfg).get("auto")))


@app.post("/videos/keep")
def videos_keep(request: Request, days: int = Form(...)):
    with edit_config() as cfg:
        cfg["export_keep_days"] = max(1, min(365, days))
    flash(request, f"Videa se budou mazat po {max(1, min(365, days))} dnech.")
    return RedirectResponse("/videos", status_code=303)


@app.get("/videos/{vid}/download")
def video_download(vid: int):
    cfg = load_config()
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    fr = frigate_exports(cfg).get(rec["frigate_id"]) if rec else None
    video = frigate_media_path(fr.get("video_path", "")) if fr else None
    if not video or not video.is_file():
        return JSONResponse({"error": "video není hotové nebo už neexistuje"}, status_code=404)
    fname = re.sub(r"[^\w\-. ]+", "_", rec["name"]).strip() or f"video-{vid}"
    return FileResponse(str(video), media_type="video/mp4", filename=f"{fname}.mp4")


def _export_file(cfg, vid: int):
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    fr = frigate_exports(cfg).get(rec["frigate_id"]) if rec else None
    video = frigate_media_path(fr.get("video_path", "")) if fr else None
    return (dict(rec) if rec else None), (video if video and video.is_file() else None)


@app.get("/videos/{vid}/play.mp4")
def video_play(request: Request, vid: int):
    """Přehrání videa přímo v prohlížeči (podporuje Range, takže jde posouvat)."""
    cfg = load_config()
    _rec, video = _export_file(cfg, vid)
    if not video:
        return JSONResponse({"error": "video není hotové nebo už neexistuje"}, status_code=404)
    size = video.stat().st_size
    rng = request.headers.get("range", "")
    m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip()) if rng else None
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600", "Content-Disposition": "inline"}
    if not m:
        return FileResponse(str(video), media_type="video/mp4", headers=headers)
    a, b = m.group(1), m.group(2)
    start = int(a) if a else max(0, size - int(b or 0))
    end = min(size - 1, int(b)) if (a and b) else size - 1
    if start >= size or start > end:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    length = end - start + 1

    def gen():
        with video.open("rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(512 * 1024, left))
                if not chunk:
                    break
                left -= len(chunk)
                yield chunk
    headers.update({"Content-Range": f"bytes {start}-{end}/{size}", "Content-Length": str(length)})
    return StreamingResponse(gen(), status_code=206, media_type="video/mp4", headers=headers)


@app.get("/videos/{vid}/thumb.jpg")
def video_thumb(vid: int):
    cfg = load_config()
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    if not rec:
        return JSONResponse({"error": "not found"}, status_code=404)
    p = export_thumb_path(cfg, dict(rec), frigate_exports(cfg).get(rec["frigate_id"]))
    if not p:
        return JSONResponse({"error": "no thumb"}, status_code=404)
    return FileResponse(str(p), headers={"Cache-Control": "private, max-age=3600"})


@app.post("/videos/{vid}/retry")
def video_retry(request: Request, vid: int, back: str = Form("")):
    """Zaseklý export (Frigate se restartoval uprostřed) – zadat znovu se stejným rozsahem."""
    cfg = load_config()
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    if not rec:
        return RedirectResponse(back or "/videos", status_code=303)
    rec = dict(rec)
    try:
        requests.delete(cfg["frigate_url"].rstrip("/") + f"/api/export/{rec['frigate_id']}", timeout=15)
    except Exception:
        pass
    try:
        new_id = frigate_start_export(cfg, rec["camera"], rec["start_ts"], rec["end_ts"], rec["name"])
    except Exception as e:
        if "No recordings" in str(e):
            flash(request, f"Video „{rec['name']}“ už nejde vytvořit – záznam z té doby byl smazán (uchovávání {retain_days(cfg)} dní). Smaž ho.", "err")
        else:
            flash(request, f"Video se nepodařilo zadat znovu: {e}", "err")
        return RedirectResponse(back or "/videos", status_code=303)
    with db() as con:
        con.execute("UPDATE exports SET frigate_id=?, created=? WHERE id=?", (new_id, dt.datetime.now().isoformat(timespec="seconds"), vid))
    log(f"Video „{rec['name']}“ zadáno znovu ({new_id}) – původní export se zasekl")
    flash(request, f"Video „{rec['name']}“ se vytváří znovu – hotové bude za pár minut.")
    return RedirectResponse(back or "/videos", status_code=303)


@app.post("/videos/{vid}/delete")
def video_delete(request: Request, vid: int):
    cfg = load_config()
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    if rec:
        delete_export(cfg, dict(rec))
        flash(request, f"Video „{rec['name']}“ smazáno.")
    return RedirectResponse(request.headers.get("referer") or "/videos", status_code=303)


# =============================================================================
#  VIDEO STUDIO – zrychlení, intro, text v obraze, hudba s plynulým náběhem/doběhem.
#  Vstupem je hotové video vystřižené Frigate (tabulka exports); výstup leží na HDD
#  ve složce studio/ a je připravený ke stažení (a od 4.6 k nahrání na YouTube).
# =============================================================================

STUDIO_SPEEDS = tuple(range(10, 250, 10))   # 10×, 20×, … 240×
STUDIO_TEXT_POS = {"bl": "vlevo dole", "br": "vpravo dole", "bc": "dole uprostřed", "tl": "vlevo nahoře", "tr": "vpravo nahoře", "tc": "nahoře uprostřed"}
STUDIO_INTRO_EXT = (".mp4", ".mov", ".m4v", ".png", ".jpg", ".jpeg")
STUDIO_MUSIC_EXT = (".mp3", ".m4a", ".aac", ".wav", ".ogg", ".flac")
STUDIO_FONTS = ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
                "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf")
_studio_lock = threading.Lock()
_studio_thread: threading.Thread | None = None
_studio_progress: dict = {}   # id → 0–100 právě renderovaného videa
_studio_eta: dict = {}        # id → odhad zbývajících sekund


def studio_cfg(cfg) -> dict:
    return deep_merge(DEFAULT_CONFIG["studio"], cfg.get("studio") or {})


def studio_assets_dir() -> Path:
    p = APP_DIR / "studio"
    (p / "music").mkdir(parents=True, exist_ok=True)
    return p


def studio_out_dir(cfg) -> Path:
    p = Path(cfg["snapshot_dir"]).parent / "studio"
    p.mkdir(parents=True, exist_ok=True)
    return p


def studio_font() -> str:
    for f in STUDIO_FONTS:
        if Path(f).is_file():
            return f
    return ""


def studio_intro() -> Path | None:
    """Nahrané intro (video nebo obrázek) – vždy jen jedno."""
    for p in sorted(studio_assets_dir().glob("intro.*")):
        if p.suffix.lower() in STUDIO_INTRO_EXT:
            return p
    return None


def studio_music_files() -> list:
    out = []
    for p in sorted(studio_assets_dir().joinpath("music").iterdir()):
        if p.is_file() and p.suffix.lower() in STUDIO_MUSIC_EXT:
            out.append({"name": p.name, "size_h": human_size(p.stat().st_size), "duration": ffprobe_info(p).get("duration", 0), "meta": music_meta(p.name)})
    return out


def ffprobe_info(path) -> dict:
    """Rozlišení, fps a délka (s) souboru; prázdný dict, když ffprobe selže."""
    rc, out = run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height,r_frame_rate:format=duration",
                   "-of", "json", str(path)], timeout=30)
    if rc != 0:
        return {}
    try:
        data = json.loads(out)
        info = {"duration": float((data.get("format") or {}).get("duration") or 0)}
        for s in data.get("streams") or []:
            if s.get("codec_type") == "video" and "width" not in info:
                info["width"], info["height"] = int(s.get("width") or 0), int(s.get("height") or 0)
                num, _, den = str(s.get("r_frame_rate") or "25/1").partition("/")
                info["fps"] = round(float(num) / float(den or 1), 2) if float(den or 1) else 25.0
            if s.get("codec_type") == "audio":
                info["audio"] = True
        return info
    except (ValueError, TypeError, ZeroDivisionError):
        return {}


def studio_vars(cfg, export: dict, speed: int) -> dict:
    """Proměnné do šablon textu, titulku a popisu: {kamera} {datum} {cas} {jev} {skore} {popis} {rychlost} {delka}."""
    tz = ZoneInfo(cfg["tz"])
    t0 = dt.datetime.fromtimestamp(export["start_ts"], tz)
    v = {"kamera": cam_label(cfg, export["camera"]), "datum": f"{t0.day}. {t0.month}. {t0.year}", "cas": t0.strftime("%H:%M"),
         "jev": "", "skore": "", "popis": "", "rychlost": str(speed), "delka": human_minutes(export["end_ts"] - export["start_ts"])}
    if export.get("detection_id"):
        with db() as con:
            e = con.execute("SELECT ts, score, phenomenon, description FROM evaluations WHERE id=?", (export["detection_id"],)).fetchone()
        if e:
            v.update(jev=e["phenomenon"] or "", skore=str(e["score"] or ""), popis=e["description"] or "")
            if e["ts"]:
                v["cas"] = str(e["ts"])[11:16]
    return v


def studio_fill(tpl: str, v: dict) -> str:
    out = str(tpl or "")
    for k, val in v.items():
        out = out.replace("{" + k + "}", str(val))
    # prázdná značka nesmí nechat dva oddělovače za sebou („Kamera –  · 12. 9.“ → „Kamera · 12. 9.“)
    out = re.sub(r"(\s+[–·|-]){2,}\s+", " · ", out)
    out = "\n".join(line.strip(" –·|-") for line in out.split("\n"))
    return re.sub(r"[ \t]+\n", "\n", out).strip()


def studio_estimate(cfg, row: dict) -> float:
    """Odhad doby vytváření (s) ještě před startem – stejný vzorec jako na stránce nového videa."""
    try:
        with db() as con:
            ex = con.execute("SELECT start_ts, end_ts FROM exports WHERE id=?", (row["export_id"],)).fetchone()
        dur = float(ex["end_ts"] - ex["start_ts"]) if ex else 600.0
    except Exception:
        dur = 600.0
    speed = max(10, int(row.get("speed") or 20))
    decode = dur / 40 if speed >= 120 else dur * 25 / 260
    encode = (dur / speed) * 30 / 35
    return max(5.0, decode + encode + 3)


def _eta_fields(seconds) -> dict:
    """Text „asi 2 min“, sekundy pro odpočet a čas hodin, kdy to bude hotové."""
    if not seconds:
        return {"eta_h": "", "eta_s": 0, "eta_at": ""}
    seconds = float(seconds)
    at = dt.datetime.now() + dt.timedelta(seconds=seconds)
    return {"eta_h": f"asi {int(round(seconds / 60))} min" if seconds >= 90 else f"asi {int(round(seconds / 10) * 10) or 10} s",
            "eta_s": int(seconds), "eta_at": at.strftime("%H:%M") if seconds >= 60 else at.strftime("%H:%M:%S")}


def studio_rows(cfg, export_id=None, sid=None) -> list:
    q, args = "SELECT * FROM studio_videos", ()
    if export_id:
        q, args = q + " WHERE export_id=?", (export_id,)
    elif sid:
        q, args = q + " WHERE id=?", (sid,)
    with db() as con:
        rows = [dict(r) for r in con.execute(q + " ORDER BY id DESC", args)]
    for r in rows:
        f = Path(r["file"]) if r.get("file") else None
        r["ready"] = bool(r["status"] == "ready" and f and f.is_file())
        r["size_h"] = human_size(f.stat().st_size) if r["ready"] else ""
        r["duration_h"] = f"{int(r['duration'] or 0) // 60}:{int(r['duration'] or 0) % 60:02d}" if r.get("duration") else ""
        r["progress"] = _studio_progress.get(r["id"], 0) if r["status"] == "rendering" else (100 if r["ready"] else 0)
        eta = None
        if r["status"] == "rendering":
            eta = _studio_eta.get(r["id"]) or studio_estimate(cfg, r) * max(0.05, 1 - r["progress"] / 100)
        elif r["status"] == "queued":
            eta = studio_estimate(cfg, r)
            with db() as con:   # + videa před ním ve frontě
                ahead = [dict(x) for x in con.execute("SELECT * FROM studio_videos WHERE status IN ('queued','rendering') AND id<?", (r["id"],))]
            for a in ahead:
                eta += _studio_eta.get(a["id"]) or studio_estimate(cfg, a)
        r.update(_eta_fields(eta))
        r["thumb"] = (studio_out_dir(cfg) / f"{r['id']}.jpg").is_file()
        r["yt_progress"] = _yt_progress.get(r["id"], 0)
        yeta = None
        if r["yt_status"] == "uploading":
            yeta = _yt_eta.get(r["id"]) or (f.stat().st_size / (2 * 1024 * 1024) if r["ready"] else None)   # do 1. měření odhad ~2 MB/s
        elif r["yt_status"] == "queued":
            yeta = (f.stat().st_size / (2 * 1024 * 1024) + 5) if r["ready"] else None
        yt = _eta_fields(yeta)
        r.update(yt_eta_h=yt["eta_h"], yt_eta_s=yt["eta_s"], yt_eta_at=yt["eta_at"])
        r["camera_label"] = cam_label(cfg, r["camera"])
    return rows


def studio_enqueue(cfg, export: dict, speed: int, intro: bool, music: str, text: str, title: str, description: str, auto: int = 0) -> int:
    sc = studio_cfg(cfg)
    speed = int(round(speed / 10) * 10) if 10 <= speed <= 240 else int(sc.get("speed", 20) or 20)
    if music and not (studio_assets_dir() / "music" / music).is_file():
        music = ""
    credit = music_credit(music) if music else ""
    if credit and credit not in (description or ""):
        description = (description.rstrip() + "\n\n" + credit).strip()
    with db() as con:
        cur = con.execute("INSERT INTO studio_videos (export_id, camera, name, speed, intro, music, text, title, description, status, created, auto) "
                          "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                          (export["id"], export["camera"], export["name"], speed, 1 if intro else 0, music, text, title[:100], description[:5000],
                           "queued", dt.datetime.now().isoformat(timespec="seconds"), auto))
        sid = int(cur.lastrowid)
    studio_kick()
    return sid


def studio_kick():
    """Spustí renderovací vlákno, pokud neběží (jeden ffmpeg naráz – RPi má 4 jádra)."""
    global _studio_thread
    with _studio_lock:
        if _studio_thread and _studio_thread.is_alive():
            return
        _studio_thread = threading.Thread(target=_studio_worker, name="studio", daemon=True)
        _studio_thread.start()


def _studio_worker():
    while True:
        with db() as con:
            job = con.execute("SELECT * FROM studio_videos WHERE status='queued' ORDER BY id LIMIT 1").fetchone()
        if not job:
            return
        job = dict(job)
        cfg = load_config()
        with db() as con:
            con.execute("UPDATE studio_videos SET status='rendering', message='' WHERE id=?", (job["id"],))
        try:
            studio_render(cfg, job)
        except Exception as e:
            msg = str(e)[:400]
            with db() as con:
                con.execute("UPDATE studio_videos SET status='failed', message=? WHERE id=?", (msg, job["id"],))
            log(f"Studio: video „{job['name']}“ se nepodařilo vytvořit: {msg}")
            add_event("warn", f"Video ze studia nevzniklo: {job['name']}", msg)
        finally:
            _studio_progress.pop(job["id"], None)
            _studio_eta.pop(job["id"], None)


def _drawtext(font: str, textfile: Path, size: int, pos: str) -> str:
    x = {"bl": "24", "tl": "24", "br": "w-tw-24", "tr": "w-tw-24", "bc": "(w-tw)/2", "tc": "(w-tw)/2"}[pos]
    y = "24" if pos in ("tl", "tr", "tc") else "h-th-24"
    return (f"drawtext=fontfile='{font}':textfile='{textfile}':fontsize={size}:fontcolor=white:borderw=2:bordercolor=black@0.7:"
            f"box=1:boxcolor=black@0.35:boxborderw=10:x={x}:y={y}:line_spacing=6")


def studio_render(cfg, job: dict):
    """Sestaví a spustí ffmpeg: [intro] + zrychlený záznam (+ text) (+ hudba s fade in/out)."""
    sc = studio_cfg(cfg)
    if not storage_ready():
        raise RuntimeError("Disk pro záznamy není připravený.")
    with db() as con:
        export = con.execute("SELECT * FROM exports WHERE id=?", (job["export_id"],)).fetchone()
    if not export:
        raise RuntimeError("Zdrojové video už neexistuje (bylo smazané).")
    export = dict(export)
    fr = frigate_exports(cfg).get(export["frigate_id"])
    src = frigate_media_path(fr.get("video_path", "")) if fr else None
    if not src or not src.is_file() or fr.get("in_progress"):
        raise RuntimeError("Zdrojové video ještě není hotové nebo už bylo smazané.")
    info = ffprobe_info(src)
    if not info.get("duration") or not info.get("width"):
        raise RuntimeError("Zdrojové video nejde přečíst (ffprobe).")
    speed = int(job["speed"] or 20)
    fps = 30
    w, h = info["width"], info["height"]
    if w > 1920:
        h = int(round(h * 1920 / w / 2) * 2)
        w = 1920
    w, h = w - w % 2, h - h % 2
    main_sec = max(1.0, info["duration"] / speed)
    out_dir = studio_out_dir(cfg)
    out = out_dir / f"{job['id']}.mp4"
    tmp = out_dir / f"{job['id']}.part.mp4"
    font = studio_font()
    v = studio_vars(cfg, export, speed)
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats", "-threads", "4"]
    if speed >= 120:
        cmd += ["-skip_frame", "nokey"]     # při 120× a víc stačí klíčové snímky – dekóduje se mnohonásobně rychleji
    cmd += ["-i", str(src)]
    inputs = 1
    filters = []
    scale = f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps={fps},format=yuv420p"
    vfi, vfo = float(sc.get("video_fade_in", 1) or 0), float(sc.get("video_fade_out", 2) or 0)
    vfi, vfo = min(vfi, main_sec / 3), min(vfo, main_sec / 3)
    main = f"[0:v]setpts=PTS/{speed},{scale}"
    if vfi > 0:
        main += f",fade=t=in:st=0:d={vfi:.2f}"          # záznam se rozjasní ze tmy
    if vfo > 0:
        main += f",fade=t=out:st={max(0.0, main_sec - vfo):.3f}:d={vfo:.2f}"   # a na konci ztmavne
    notes = []
    if job.get("text") and str(job["text"]).strip():
        if font:
            tf = out_dir / f"{job['id']}.txt"
            tf.write_text(studio_fill(job["text"], v), encoding="utf-8")
            main += "," + _drawtext(font, tf, int(sc.get("text_size", 36) or 36), sc.get("text_pos") if sc.get("text_pos") in STUDIO_TEXT_POS else "bl")
        else:
            notes.append("text do obrazu nepřidán – na RPi chybí font (nainstaluj balíček fonts-dejavu-core)")
    main += "[main]"
    filters.append(main)
    intro_sec = 0.0
    intro_audio, intro_in = False, 0
    intro = studio_intro() if job.get("intro") else None
    if intro:
        if intro.suffix.lower() in (".png", ".jpg", ".jpeg"):
            intro_sec = float(sc.get("intro_seconds", 4) or 4)
            cmd += ["-loop", "1", "-t", f"{intro_sec:.2f}", "-i", str(intro)]
            chain = f"[{inputs}:v]{scale}"
            if font and sc.get("intro_title", True):
                tf2 = out_dir / f"{job['id']}.intro.txt"
                tf2.write_text(studio_fill(sc.get("intro_text", "{kamera}\n{datum}"), v), encoding="utf-8")
                chain += "," + _drawtext(font, tf2, int(sc.get("text_size", 36) or 36) + 10, "bc").replace("y=h-th-24", "y=h-th-h/8")
            chain += f",fade=t=in:st=0:d=0.6,fade=t=out:st={max(0.0, intro_sec - 0.6):.2f}:d=0.6[intro]"
        else:
            ii = ffprobe_info(intro)
            intro_sec = min(float(ii.get("duration") or 0), float(sc.get("intro_max_seconds", 15) or 15)) or 0.0
            if intro_sec <= 0:
                raise RuntimeError("Intro video nejde přečíst.")
            cmd += ["-t", f"{intro_sec:.2f}", "-i", str(intro)]
            chain = f"[{inputs}:v]{scale}[intro]"
            intro_audio, intro_in = bool(ii.get("audio")), inputs
        inputs += 1
        filters.append(chain)
        filters.append("[intro][main]concat=n=2:v=1:a=0[v]")
    else:
        filters.append("[main]null[v]")
    total = intro_sec + main_sec
    music = (studio_assets_dir() / "music" / job["music"]) if job.get("music") else None
    music = music if music and music.is_file() else None
    afmt = "aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo"
    if music or intro_audio:
        # Zvuk: intro si nechá svůj (když ho má), hudba začne až za intrem a plynule zesílí; na konci plynule ztichne.
        parts = []
        if intro_sec > 0:
            if intro_audio:
                filters.append(f"[{intro_in}:a]atrim=0:{intro_sec:.3f},asetpts=PTS-STARTPTS,{afmt},"
                               f"afade=t=out:st={max(0.0, intro_sec - 0.8):.3f}:d=0.8[ia]")
            else:
                filters.append(f"anullsrc=r=44100:cl=stereo,atrim=0:{intro_sec:.3f},{afmt}[ia]")
            parts.append("[ia]")
        if music:
            fi, fo = float(sc.get("fade_in", 2) or 0), float(sc.get("fade_out", 4) or 0)
            fo = max(fo, vfo)                          # hudba nesmí dohrát dřív, než obraz ztmavne
            fo = min(fo, max(0.0, main_sec - fi - 0.5))
            vol = max(0.05, min(2.0, float(sc.get("music_volume", 0.8) or 0.8)))
            cmd += ["-stream_loop", "-1", "-i", str(music)]
            filters.append(f"[{inputs}:a]atrim=0:{main_sec:.3f},asetpts=PTS-STARTPTS,{afmt},afade=t=in:st=0:d={fi:.2f},"
                           f"afade=t=out:st={max(0.0, main_sec - fo):.3f}:d={fo:.2f},volume={vol:.2f}[ma]")
            inputs += 1
        else:
            filters.append(f"anullsrc=r=44100:cl=stereo,atrim=0:{main_sec:.3f},{afmt}[ma]")
        parts.append("[ma]")
        if len(parts) > 1:
            filters.append("".join(parts) + f"concat=n={len(parts)}:v=0:a=1[a]")
        else:
            filters.append("[ma]anull[a]")
        maps = ["-map", "[v]", "-map", "[a]", "-c:a", "aac", "-b:a", "160k"]
    else:
        maps = ["-map", "[v]", "-an"]
    cmd += ["-filter_complex", ";".join(filters)] + maps + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p",
                                                          "-movflags", "+faststart", "-t", f"{total:.3f}", "-f", "mp4", str(tmp)]
    log(f"Studio: vytvářím „{job['name']}“ – {speed}×, {main_sec:.0f} s{' + intro' if intro else ''}{' + hudba' if music else ''}")
    started = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    err_tail = ""
    try:
        for line in p.stdout:
            if line.startswith("out_time_us="):
                try:
                    done = int(line.split("=")[1]) / 1_000_000
                    _studio_progress[job["id"]] = min(99, int(done / total * 100))
                    el = time.time() - started
                    if done > 0.5 and el > 2:
                        _studio_eta[job["id"]] = max(1.0, (total - done) * el / done)
                except ValueError:
                    pass
            if time.time() - started > 3600:
                p.kill()
                raise RuntimeError("Vytváření trvalo přes hodinu – přerušeno.")
        err_tail = (p.stderr.read() or "")[-600:]
        p.wait(timeout=60)
    finally:
        if p.poll() is None:
            p.kill()
    if p.returncode != 0 or not tmp.is_file() or tmp.stat().st_size < 1000:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("ffmpeg selhal: " + (err_tail.strip().splitlines() or ["neznámá chyba"])[-1])
    tmp.replace(out)
    run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-ss", f"{min(intro_sec + 1.0, max(0.0, total - 0.5)):.2f}", "-i", str(out),
         "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "4", str(out_dir / f"{job['id']}.jpg")], timeout=60)
    for extra in (out_dir / f"{job['id']}.txt", out_dir / f"{job['id']}.intro.txt"):
        extra.unlink(missing_ok=True)
    real = ffprobe_info(out).get("duration") or total
    with db() as con:
        con.execute("UPDATE studio_videos SET status='ready', file=?, duration=?, message=?, finished=? WHERE id=?",
                    (str(out), real, "; ".join(notes), dt.datetime.now().isoformat(timespec="seconds"), job["id"]))
    log(f"Studio: video „{job['name']}“ hotové ({real:.0f} s, {human_size(out.stat().st_size)}, {time.time() - started:.0f} s práce)")
    studio_after_render(cfg, job["id"])


def studio_delete(cfg, row: dict):
    out_dir = studio_out_dir(cfg)
    for p in (Path(row["file"]) if row.get("file") else None, out_dir / f"{row['id']}.jpg", out_dir / f"{row['id']}.part.mp4"):
        if p:
            p.unlink(missing_ok=True)
    with db() as con:
        con.execute("DELETE FROM studio_videos WHERE id=?", (row["id"],))


def studio_auto(cfg):
    """Automatika: hotové automatické video po upozornění → rovnou vyrobit verzi ze studia (volá smyčka)."""
    sc = studio_cfg(cfg)
    if not sc.get("auto"):
        return
    with db() as con:
        cands = [dict(r) for r in con.execute(
            "SELECT * FROM exports WHERE auto=1 AND id NOT IN (SELECT export_id FROM studio_videos) ORDER BY id DESC LIMIT 5")]
    if not cands:
        return
    fr_all = frigate_exports(cfg)
    for ex in cands:
        fr = fr_all.get(ex["frigate_id"])
        video = frigate_media_path(fr.get("video_path", "")) if fr else None
        if not (video and video.is_file() and not fr.get("in_progress")):
            continue
        v = studio_vars(cfg, ex, int(sc.get("speed", 20) or 20))
        title = studio_fill(sc.get("title", ""), v)
        if sc.get("ai_title", True) and cfg["ai"].get("enabled"):
            try:
                ideas = studio_title_ideas(cfg, v, 3)
                if ideas:
                    title = ideas[0]
            except Exception as e:
                log(f"Studio: návrh titulku přes AI selhal ({e}) – použita šablona")
        studio_enqueue(cfg, ex, int(sc.get("speed", 20) or 20), bool(sc.get("intro", True) and studio_intro()), sc.get("music_default", ""),
                       sc.get("text", "") if sc.get("text_enabled", True) else "", title,
                       studio_fill(sc.get("description", ""), v), auto=1)
        log(f"[{ex['camera']}] Studio: automatické video „{ex['name']}“ zařazeno ke zrychlení")


def studio_title_ideas(cfg, v: dict, n: int = 5) -> list:
    """Návrhy titulků pro YouTube (česky, poutavé, do 70 znaků) z textu AI, kamery, jevu a data."""
    prompt = (
        "Jsi editor YouTube kanálu s časosběrnými videi oblohy z domácích kamer. Navrhni " + str(n) + " titulků videa v češtině, "
        "které přilákají diváky: konkrétní, obrazné, bez clickbaitu a bez emoji, každý do 70 znaků, různé styly (popisný, emotivní, "
        "s místem, s jevem). Nepoužívej uvozovky. Vrať jen JSON pole řetězců.\n\n"
        f"Místo/kamera: {v.get('kamera', '')}\nDatum: {v.get('datum', '')} {v.get('cas', '')}\nJev: {v.get('jev', '') or 'zajímavá obloha'}\n"
        f"Skóre AI: {v.get('skore', '') or '?'}/10\nPopis od AI: {v.get('popis', '') or '–'}\nDélka záznamu: {v.get('delka', '')}, zrychleno {v.get('rychlost', '')}×"
    )
    raw = ai_text(cfg["ai"], prompt, 500)
    data = extract_json(raw)
    out = []
    if isinstance(data, list):
        out = [str(x).strip().strip('"').strip("'") for x in data if str(x).strip()]
    if not out:
        out = [line.strip("-•* \"'0123456789.").strip() for line in raw.splitlines() if 8 < len(line.strip()) < 100]
    return [t[:100] for t in out][:n]


def _studio_vars_for_row(cfg, row: dict) -> dict:
    with db() as con:
        ex = con.execute("SELECT * FROM exports WHERE id=?", (row["export_id"],)).fetchone()
    if not ex:
        return {"kamera": cam_label(cfg, row["camera"]), "datum": "", "cas": "", "jev": "", "skore": "", "popis": row.get("description") or "",
                "rychlost": str(row.get("speed") or ""), "delka": ""}
    return studio_vars(cfg, dict(ex), int(row.get("speed") or 20))


@app.post("/studio/titles")
def studio_titles(request: Request, sid: int = Form(0), vid: int = Form(0), speed: int = Form(20)):
    cfg = load_config()
    try:
        if sid:
            rows = studio_rows(cfg, sid=sid)
            if not rows:
                raise RuntimeError("Video neexistuje.")
            v = _studio_vars_for_row(cfg, rows[0])
        else:
            ex = _studio_export(cfg, vid)
            if not ex:
                raise RuntimeError("Zdrojové video neexistuje.")
            v = studio_vars(cfg, ex, speed)
        ideas = studio_title_ideas(cfg, v)
        if not ideas:
            raise RuntimeError("AI nevrátila žádný návrh – zkus to znovu.")
        return JSONResponse({"ok": True, "titles": ideas})
    except Exception as e:
        return JSONResponse({"ok": False, "error": f"Návrh titulku selhal: {e}"[:300]}, status_code=400)


def _studio_export(cfg, vid: int):
    with db() as con:
        rec = con.execute("SELECT * FROM exports WHERE id=?", (vid,)).fetchone()
    return dict(rec) if rec else None


def _studio_form_ctx(cfg, export: dict, speed: int):
    sc = studio_cfg(cfg)
    v = studio_vars(cfg, export, speed)
    src_path = frigate_media_path((frigate_exports(cfg).get(export["frigate_id"]) or {}).get("video_path", ""))
    src = ffprobe_info(src_path) if src_path and src_path.is_file() else {}
    src.setdefault("duration", float(export["end_ts"] - export["start_ts"]))
    return dict(sc=sc, speeds=STUDIO_SPEEDS, intro=studio_intro(), music=studio_music_files(), font=bool(studio_font()), vars=v, src=src)


@app.get("/studio/new/{vid}", response_class=HTMLResponse)
def studio_new(request: Request, vid: int, again: int = 0):
    cfg = load_config()
    export = _studio_export(cfg, vid)
    if not export:
        flash(request, "Tohle video už neexistuje.", "err")
        return RedirectResponse("/videos", status_code=303)
    sc = studio_cfg(cfg)
    prev = studio_rows(cfg, sid=again)[0] if again else None
    speed = int(prev["speed"]) if prev else int(sc.get("speed", 20) or 20)
    ctx = _studio_form_ctx(cfg, export, speed)
    v = ctx["vars"]
    values = {"speed": speed, "intro": bool(prev["intro"]) if prev else bool(sc.get("intro", True)),
              "music": prev["music"] if prev else sc.get("music_default", ""),
              "text_on": bool(prev["text"]) if prev else bool(sc.get("text_enabled", True)),
              "text": prev["text"] if prev and prev["text"] else sc.get("text", ""),
              "title": prev["title"] if prev else studio_fill(sc.get("title", ""), v),
              "description": prev["description"] if prev else studio_fill(sc.get("description", ""), v)}
    return render(request, "studio_new.html", "Studio – nové video", export=export, values=values, quick=MUSIC_QUICK,
                  subtitle="Zrychlení, intro, text a hudba k vystřiženému videu. Než se nahraje kamkoli, uvidíš výsledek.", **ctx)


@app.post("/studio/new/{vid}")
def studio_new_post(request: Request, vid: int, speed: int = Form(20), intro: str = Form(""), music: str = Form(""), text_on: str = Form(""),
                    text: str = Form(""), title: str = Form(""), description: str = Form("")):
    cfg = load_config()
    export = _studio_export(cfg, vid)
    if not export:
        flash(request, "Tohle video už neexistuje.", "err")
        return RedirectResponse("/videos", status_code=303)
    sid = studio_enqueue(cfg, export, speed, bool(intro), music.strip(), text.strip() if text_on else "", title.strip() or export["name"],
                         description.strip())
    flash(request, "Video se vytváří – podle délky záznamu to trvá od pár sekund do několika minut. Stránka se sama obnoví.")
    return RedirectResponse(f"/studio/v/{sid}", status_code=303)


@app.get("/studio/v/{sid}", response_class=HTMLResponse)
def studio_video(request: Request, sid: int):
    cfg = load_config()
    rows = studio_rows(cfg, sid=sid)
    if not rows:
        flash(request, "Video ze studia neexistuje.", "err")
        return RedirectResponse("/videos", status_code=303)
    r = rows[0]
    queue_pos = 0
    if r["status"] == "queued":
        with db() as con:
            queue_pos = int(con.execute("SELECT COUNT(*) FROM studio_videos WHERE status IN ('queued','rendering') AND id<?", (sid,)).fetchone()[0])
    return render(request, "studio_video.html", r["title"] or r["name"], v=r, queue_pos=queue_pos, sc=studio_cfg(cfg), yt=yt_cfg(cfg), yt_linked=yt_linked(cfg), yt_privacy=YT_PRIVACY,
                  subtitle="Náhled hotového videa, úprava titulku a popisu, stažení.")


@app.post("/studio/v/{sid}/meta")
def studio_meta(request: Request, sid: int, title: str = Form(""), description: str = Form("")):
    with db() as con:
        con.execute("UPDATE studio_videos SET title=?, description=? WHERE id=?", (title.strip()[:100], description.strip()[:5000], sid))
    flash(request, "Titulek a popis uloženy.")
    return RedirectResponse(f"/studio/v/{sid}", status_code=303)


@app.post("/studio/v/{sid}/delete")
def studio_delete_post(request: Request, sid: int):
    cfg = load_config()
    rows = studio_rows(cfg, sid=sid)
    if rows:
        studio_delete(cfg, rows[0])
        flash(request, "Video ze studia smazáno.")
    return RedirectResponse("/videos#studio", status_code=303)


def _studio_file(cfg, sid: int) -> tuple[dict | None, Path | None]:
    rows = studio_rows(cfg, sid=sid)
    if not rows or not rows[0]["ready"]:
        return (rows[0] if rows else None), None
    return rows[0], Path(rows[0]["file"])


@app.get("/studio/v/{sid}/play.mp4")
def studio_play(request: Request, sid: int):
    r, f = _studio_file(load_config(), sid)
    if not f:
        return JSONResponse({"error": "video není hotové"}, status_code=404)
    return _range_file(request, f)


@app.get("/studio/v/{sid}/download")
def studio_download(sid: int):
    r, f = _studio_file(load_config(), sid)
    if not f:
        return JSONResponse({"error": "video není hotové"}, status_code=404)
    fname = re.sub(r"[^\w\-. ]+", "_", r["title"] or r["name"]).strip() or f"studio-{sid}"
    return FileResponse(str(f), media_type="video/mp4", filename=f"{fname}.mp4")


@app.get("/studio/v/{sid}/thumb.jpg")
def studio_thumb(sid: int):
    p = studio_out_dir(load_config()) / f"{sid}.jpg"
    if not p.is_file():
        return JSONResponse({"error": "no thumb"}, status_code=404)
    return FileResponse(str(p), headers={"Cache-Control": "private, max-age=3600"})


@app.get("/studio/asset/intro")
def studio_asset_intro(request: Request):
    p = studio_intro()
    if not p:
        return JSONResponse({"error": "no intro"}, status_code=404)
    if p.suffix.lower() in (".png", ".jpg", ".jpeg"):
        return FileResponse(str(p))
    return _range_file(request, p)


@app.get("/studio/asset/music/{name}")
def studio_asset_music(request: Request, name: str):
    p = studio_assets_dir() / "music" / Path(name).name
    if not p.is_file():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(str(p))


def _range_file(request: Request, video: Path):
    """Soubor s podporou Range (přehrávání v prohlížeči s posouváním)."""
    size = video.stat().st_size
    ctype = "video/mp4" if video.suffix.lower() in (".mp4", ".m4v", ".mov") else "application/octet-stream"
    rng = request.headers.get("range", "")
    m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip()) if rng else None
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600", "Content-Disposition": "inline"}
    if not m:
        return FileResponse(str(video), media_type=ctype, headers=headers)
    a, b = m.group(1), m.group(2)
    start = int(a) if a else max(0, size - int(b or 0))
    end = min(size - 1, int(b)) if (a and b) else size - 1
    if start >= size or start > end:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    length = end - start + 1

    def gen():
        with video.open("rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(512 * 1024, left))
                if not chunk:
                    break
                left -= len(chunk)
                yield chunk
    headers.update({"Content-Range": f"bytes {start}-{end}/{size}", "Content-Length": str(length)})
    return StreamingResponse(gen(), status_code=206, media_type=ctype, headers=headers)


@app.get("/studio/settings", response_class=HTMLResponse)
def studio_settings(request: Request):
    cfg = load_config()
    intro = studio_intro()
    ii = ffprobe_info(intro) if intro and intro.suffix.lower() not in (".png", ".jpg", ".jpeg") else {}
    return render(request, "studio_settings.html", "Video studio", sc=studio_cfg(cfg), speeds=STUDIO_SPEEDS, positions=STUDIO_TEXT_POS, ov=openverse_cfg(cfg),
                  yt=yt_cfg(cfg), yt_privacy=YT_PRIVACY, link_active=bool(_yt_link.get("status") == "waiting"),
                  intro=intro, intro_is_image=bool(intro and intro.suffix.lower() in (".png", ".jpg", ".jpeg")), intro_info=ii,
                  music=studio_music_files(), font=bool(studio_font()),
                  auto_export_on=bool((cfg["ai"].get("auto_export") or {}).get("enabled")),
                  subtitle="Jak se vyrábí zrychlená videa: rychlost, intro, text v obraze, hudba, titulek a popis. Ruční i automatický režim.")


@app.post("/studio/settings")
def studio_settings_post(request: Request, speed: int = Form(20), intro: str = Form(""), intro_seconds: float = Form(4), intro_title: str = Form(""),
                         intro_text: str = Form(""), text_enabled: str = Form(""), text: str = Form(""), text_pos: str = Form("bl"), text_size: int = Form(36),
                         music_default: str = Form(""), music_volume: float = Form(0.8), fade_in: float = Form(2), fade_out: float = Form(4),
                         video_fade_in: float = Form(1), video_fade_out: float = Form(2),
                         title: str = Form(""), description: str = Form(""), auto: str = Form(""), ai_title: str = Form("")):
    with edit_config() as cfg:
        cfg["studio"] = deep_merge(studio_cfg(cfg), {
            "speed": int(round(speed / 10) * 10) if 10 <= speed <= 240 else 20, "intro": bool(intro), "intro_seconds": max(1.0, min(15.0, intro_seconds)),
            "intro_title": bool(intro_title), "intro_text": intro_text.strip()[:200], "text_enabled": bool(text_enabled), "text": text.strip()[:200],
            "text_pos": text_pos if text_pos in STUDIO_TEXT_POS else "bl", "text_size": max(16, min(96, text_size)),
            "music_default": music_default if (studio_assets_dir() / "music" / Path(music_default).name).is_file() else "",
            "music_volume": max(0.05, min(2.0, music_volume)), "fade_in": max(0.0, min(15.0, fade_in)), "fade_out": max(0.0, min(15.0, fade_out)),
            "video_fade_in": max(0.0, min(10.0, video_fade_in)), "video_fade_out": max(0.0, min(10.0, video_fade_out)),
            "title": title.strip()[:120], "description": description.strip()[:2000], "auto": bool(auto), "ai_title": bool(ai_title)})
    flash(request, "Nastavení studia uloženo.")
    return RedirectResponse("/studio/settings", status_code=303)


async def _save_upload(up, dest: Path, max_bytes: int) -> int:
    size = 0
    tmp = dest.with_suffix(dest.suffix + ".part")
    with tmp.open("wb") as f:
        while True:
            chunk = await up.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                f.close()
                tmp.unlink(missing_ok=True)
                raise ValueError(f"Soubor je větší než {human_size(max_bytes)}.")
            f.write(chunk)
    tmp.replace(dest)
    return size


@app.post("/studio/upload/intro")
async def studio_upload_intro(request: Request, file: UploadFile):
    ext = Path(file.filename or "").suffix.lower()
    if ext not in STUDIO_INTRO_EXT:
        flash(request, "Intro musí být MP4/MOV video nebo PNG/JPG obrázek.", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    old = studio_intro()
    dest = studio_assets_dir() / f"intro{ext}"
    try:
        await _save_upload(file, dest, 100 * 1024 * 1024)
        if ext in (".png", ".jpg", ".jpeg"):
            Image.open(dest).verify()
        elif not ffprobe_info(dest).get("width"):
            raise ValueError("Video nejde přečíst – zkus ho uložit jako MP4 (H.264).")
    except Exception as e:
        dest.unlink(missing_ok=True)
        flash(request, f"Intro se nepodařilo nahrát: {e}", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    if old and old != dest:
        old.unlink(missing_ok=True)
    flash(request, "Intro nahráno. Bude se přidávat před každé video (vypnout jde u videa i tady).")
    return RedirectResponse("/studio/settings", status_code=303)


@app.post("/studio/upload/intro/delete")
def studio_intro_delete(request: Request):
    p = studio_intro()
    if p:
        p.unlink(missing_ok=True)
    flash(request, "Intro odstraněno.")
    return RedirectResponse("/studio/settings", status_code=303)


@app.post("/studio/upload/music")
async def studio_upload_music(request: Request, file: UploadFile):
    name = Path(file.filename or "").name
    ext = Path(name).suffix.lower()
    if ext not in STUDIO_MUSIC_EXT:
        flash(request, "Hudba musí být MP3, M4A, AAC, WAV, OGG nebo FLAC.", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    safe = re.sub(r"[^\w\-. ]+", "_", unicodedata.normalize("NFKD", Path(name).stem).encode("ascii", "ignore").decode()).strip("_ .") or "hudba"
    dest = studio_assets_dir() / "music" / f"{safe[:60]}{ext}"
    n = 1
    while dest.exists():
        n += 1
        dest = dest.with_name(f"{safe[:60]}-{n}{ext}")
    try:
        await _save_upload(file, dest, 40 * 1024 * 1024)
        if not ffprobe_info(dest).get("audio"):
            raise ValueError("soubor neobsahuje zvukovou stopu")
    except Exception as e:
        dest.unlink(missing_ok=True)
        flash(request, f"Hudbu se nepodařilo nahrát: {e}", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    with edit_config() as cfg:
        if not studio_cfg(cfg).get("music_default"):
            cfg.setdefault("studio", {})["music_default"] = dest.name
    flash(request, f"Hudba „{dest.name}“ nahrána. Použij jen hudbu, na kterou máš práva – YouTube cizí skladby ztlumí nebo video zablokuje.")
    return RedirectResponse("/studio/settings", status_code=303)


@app.post("/studio/upload/music/delete")
def studio_music_delete(request: Request, name: str = Form(...)):
    p = studio_assets_dir() / "music" / Path(name).name
    if p.is_file():
        p.unlink()
    music_meta_path(p.name).unlink(missing_ok=True)
    with edit_config() as cfg:
        if studio_cfg(cfg).get("music_default") == Path(name).name:
            cfg.setdefault("studio", {})["music_default"] = ""
    flash(request, "Hudba odstraněna.")
    return RedirectResponse("/studio/settings", status_code=303)


# ---------- Hledání hudby (Openverse – Creative Commons, CC0 / CC BY) ----------
OPENVERSE_API = "https://api.openverse.org/v1"
MUSIC_QUICK = [("klidná", "calm ambient"), ("klavír", "piano"), ("kytara", "acoustic guitar"), ("západ slunce", "sunset chill"),
               ("epická", "epic cinematic"), ("elektronika", "electronic ambient"), ("příroda", "nature ambient"), ("lo-fi", "lofi chill")]
_ov_token: dict = {"token": "", "until": 0.0}


def openverse_cfg(cfg) -> dict:
    return dict((cfg.get("studio") or {}).get("openverse") or {})


def openverse_headers(cfg) -> dict:
    """Bearer token, když je Atmovio u Openverse zaregistrované (vyšší limit); jinak anonymně."""
    h = {"User-Agent": f"Atmovio/{APP_VERSION} (https://atmovio.com)", "Accept": "application/json"}
    ov = openverse_cfg(cfg)
    if ov.get("client_id") and ov.get("client_secret"):
        if _ov_token["token"] and time.time() < _ov_token["until"]:
            h["Authorization"] = "Bearer " + _ov_token["token"]
            return h
        try:
            r = requests.post(f"{OPENVERSE_API}/auth_tokens/token/", data={"client_id": ov["client_id"], "client_secret": ov["client_secret"],
                              "grant_type": "client_credentials"}, timeout=15, headers={"User-Agent": h["User-Agent"]})
            if r.ok and r.json().get("access_token"):
                _ov_token.update(token=r.json()["access_token"], until=time.time() + int(r.json().get("expires_in", 36000)) - 60)
                h["Authorization"] = "Bearer " + _ov_token["token"]
        except Exception as e:
            log(f"Openverse: token se nepodařilo získat ({e}) – hledám anonymně")
    return h


def music_search(cfg, q: str, length: str = "") -> dict:
    """Vrátí {'items': [...], 'error': ''}; jen hudba pod CC0 / CC BY (bez rizika na YouTube)."""
    params = {"q": q[:100], "license": "cc0,by", "category": "music", "page_size": 20, "mature": "false"}
    if length in ("short", "medium", "long"):
        params["length"] = length
    try:
        r = requests.get(f"{OPENVERSE_API}/audio/", params=params, headers=openverse_headers(cfg), timeout=20)
    except Exception as e:
        return {"items": [], "error": f"Openverse neodpovídá ({e}). Zkontroluj, že RPi má přístup na internet."}
    if r.status_code == 429:
        return {"items": [], "error": "Vyčerpaný limit anonymního hledání (Openverse). Zaregistruj Atmovio v Nastavení → Video studio – je to zdarma a limit je pak prakticky neomezený."}
    if not r.ok:
        return {"items": [], "error": f"Openverse vrátil chybu HTTP {r.status_code}."}
    items = []
    for x in (r.json().get("results") or []):
        if not x.get("url"):
            continue
        dur = int((x.get("duration") or 0) / 1000)
        items.append({"id": x.get("id"), "title": (x.get("title") or "bez názvu")[:120], "creator": (x.get("creator") or "")[:80],
                      "url": x["url"], "duration": dur, "duration_h": f"{dur // 60}:{dur % 60:02d}" if dur else "",
                      "license": (x.get("license") or "").upper() + (" " + x["license_version"] if x.get("license_version") else ""),
                      "attribution": x.get("attribution") or "", "page": x.get("foreign_landing_url") or "", "genres": ", ".join(x.get("genres") or [])[:60],
                      "filetype": (x.get("filetype") or "").lower(), "size": int(x.get("filesize") or 0)})
    return {"items": items, "error": "" if items else "Nic nenalezeno – zkus jiné slovo (anglicky funguje nejlépe: calm, piano, sunset…)."}


def music_meta_path(name: str) -> Path:
    return studio_assets_dir() / "music" / (Path(name).name + ".json")


def music_meta(name: str) -> dict:
    p = music_meta_path(name)
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else {}
    except (OSError, ValueError):
        return {}


def music_credit(name: str) -> str:
    """Řádek s autorem do popisu videa (u CC BY je povinný; u CC0 slušnost)."""
    m = music_meta(name)
    if not m:
        return ""
    return f"Hudba: {m.get('title') or name} – {m.get('creator') or 'neznámý autor'} ({m.get('license') or 'CC'}), Openverse" + (f", {m['page']}" if m.get("page") else "")


def music_download(cfg, item: dict) -> str:
    """Stáhne skladbu z Openverse do knihovny hudby; vrátí název souboru."""
    url = str(item.get("url") or "")
    if not re.match(r"^https://", url):
        raise ValueError("neplatná adresa souboru")
    base = unicodedata.normalize("NFKD", f"{item.get('creator') or ''} - {item.get('title') or 'skladba'}").encode("ascii", "ignore").decode()
    base = re.sub(r"[^\w\-. ]+", "_", base).strip("_ .-")[:70] or "hudba"
    ext = "." + (item.get("filetype") or "").lower().lstrip(".")
    if ext not in STUDIO_MUSIC_EXT:
        ext = Path(urlsplit(url).path).suffix.lower()
    if ext not in STUDIO_MUSIC_EXT:
        ext = ".mp3"
    dest = studio_assets_dir() / "music" / f"{base}{ext}"
    if dest.is_file():
        return dest.name
    tmp = dest.with_suffix(dest.suffix + ".part")
    size = 0
    with requests.get(url, stream=True, timeout=(15, 120), headers={"User-Agent": f"Atmovio/{APP_VERSION}"}) as r:
        if not r.ok:
            raise ValueError(f"stažení selhalo (HTTP {r.status_code})")
        with tmp.open("wb") as f:
            for chunk in r.iter_content(256 * 1024):
                size += len(chunk)
                if size > 40 * 1024 * 1024:
                    f.close(); tmp.unlink(missing_ok=True)
                    raise ValueError("soubor je větší než 40 MB")
                f.write(chunk)
    if not ffprobe_info(tmp).get("audio"):
        tmp.unlink(missing_ok=True)
        raise ValueError("stažený soubor není přehratelná hudba")
    tmp.replace(dest)
    music_meta_path(dest.name).write_text(json.dumps({"title": item.get("title"), "creator": item.get("creator"), "license": item.get("license"),
                                                      "attribution": item.get("attribution"), "page": item.get("page"), "source": "openverse",
                                                      "id": item.get("id")}, ensure_ascii=False), encoding="utf-8")
    log(f"Studio: hudba „{dest.name}“ stažena z Openverse ({item.get('license')})")
    return dest.name


@app.get("/studio/music/search")
def studio_music_search(request: Request, q: str = "", length: str = ""):
    q = q.strip()
    if len(q) < 2:
        return JSONResponse({"items": [], "error": "Zadej aspoň dvě písmena."})
    return JSONResponse(music_search(load_config(), q, length))


@app.post("/studio/music/fetch")
def studio_music_fetch(request: Request, id: str = Form(""), url: str = Form(...), title: str = Form(""), creator: str = Form(""),
                       license: str = Form(""), attribution: str = Form(""), page: str = Form(""), filetype: str = Form("")):
    try:
        name = music_download(load_config(), {"id": id, "url": url, "title": title, "creator": creator, "license": license,
                                              "attribution": attribution, "page": page, "filetype": filetype})
    except Exception as e:
        return JSONResponse({"ok": False, "error": f"Hudbu se nepodařilo stáhnout: {e}"}, status_code=400)
    return JSONResponse({"ok": True, "name": name, "credit": music_credit(name)})


@app.post("/studio/openverse/register")
def studio_openverse_register(request: Request, email: str = Form(...)):
    email = email.strip()
    if "@" not in email:
        flash(request, "Zadej platný e-mail.", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    try:
        r = requests.post(f"{OPENVERSE_API}/auth_tokens/register/", json={"name": f"Atmovio {secrets.token_hex(3)}",
                          "description": "Atmovio – hudba k časosběrným videím z kamer oblohy (atmovio.com)", "email": email},
                          timeout=20, headers={"User-Agent": f"Atmovio/{APP_VERSION}"})
        data = r.json() if r.content else {}
        if not r.ok or not data.get("client_id"):
            raise ValueError(data.get("detail") or data.get("email") or f"HTTP {r.status_code}")
    except Exception as e:
        flash(request, f"Registrace u Openverse se nepodařila: {e}", "err")
        return RedirectResponse("/studio/settings", status_code=303)
    with edit_config() as cfg:
        cfg.setdefault("studio", {})["openverse"] = {"client_id": data["client_id"], "client_secret": data.get("client_secret", ""),
                                                     "email": email, "registered": dt.datetime.now().isoformat(timespec="seconds")}
    _ov_token.update(token="", until=0)
    flash(request, f"Hotovo. Openverse poslal na {email} e-mail s potvrzovacím odkazem – klikni na něj a hledání hudby má od té chvíle vysoký limit.")
    return RedirectResponse("/studio/settings", status_code=303)


@app.post("/studio/openverse/forget")
def studio_openverse_forget(request: Request):
    with edit_config() as cfg:
        cfg.setdefault("studio", {}).pop("openverse", None)
    _ov_token.update(token="", until=0)
    flash(request, "Registrace Openverse odstraněna – hledání běží anonymně (malý limit).")
    return RedirectResponse("/studio/settings", status_code=303)


# =============================================================================
#  YOUTUBE – propojení účtu (OAuth „zařízení s omezeným vstupem“: kód + google.com/device),
#  playlisty, nahrání hotového videa ze studia. Vše přes YouTube Data API v3.
# =============================================================================
YT_SCOPE = "https://www.googleapis.com/auth/youtube"
YT_API = "https://www.googleapis.com/youtube/v3"
YT_PRIVACY = {"unlisted": "Nezveřejněné (jen kdo má odkaz)", "public": "Veřejné", "private": "Soukromé"}
_yt_link: dict = {}            # probíhající propojení: device_code, user_code, url, expires, interval, status, error
_yt_token: dict = {"token": "", "until": 0.0}
_yt_progress: dict = {}        # studio id → % nahrání
_yt_eta: dict = {}             # studio id → odhad zbývajících sekund nahrávání
_yt_thread: threading.Thread | None = None
_yt_lock = threading.Lock()


def yt_cfg(cfg) -> dict:
    return dict((cfg.get("studio") or {}).get("youtube") or {})


def yt_linked(cfg) -> bool:
    y = yt_cfg(cfg)
    return bool(y.get("client_id") and y.get("client_secret") and y.get("refresh_token"))


def yt_access_token(cfg) -> str:
    """Krátkodobý token z refresh tokenu (cache ~55 min)."""
    y = yt_cfg(cfg)
    if not yt_linked(cfg):
        raise RuntimeError("YouTube není propojený – Nastavení → Video studio → YouTube.")
    if _yt_token["token"] and time.time() < _yt_token["until"]:
        return _yt_token["token"]
    r = requests.post("https://oauth2.googleapis.com/token", data={"client_id": y["client_id"], "client_secret": y["client_secret"],
                      "refresh_token": y["refresh_token"], "grant_type": "refresh_token"}, timeout=20)
    data = r.json() if r.content else {}
    if not r.ok or not data.get("access_token"):
        err = data.get("error_description") or data.get("error") or f"HTTP {r.status_code}"
        if data.get("error") == "invalid_grant":
            err = ("Google propojení zneplatnil (u aplikace v režimu „testování“ platí jen 7 dní – v Google Cloud Console "
                   "na obrazovce souhlasu klikni na „Publikovat aplikaci“). Propoj YouTube znovu.")
        raise RuntimeError(err)
    _yt_token.update(token=data["access_token"], until=time.time() + int(data.get("expires_in", 3600)) - 120)
    return _yt_token["token"]


def yt_call(cfg, method: str, path: str, **kw) -> dict:
    kw.setdefault("timeout", 30)
    headers = kw.pop("headers", {})
    headers["Authorization"] = "Bearer " + yt_access_token(cfg)
    r = requests.request(method, YT_API + path if path.startswith("/") else path, headers=headers, **kw)
    data = r.json() if r.content and "json" in r.headers.get("content-type", "") else {}
    if not r.ok:
        e = (data.get("error") or {}) if isinstance(data, dict) else {}
        reason = ((e.get("errors") or [{}])[0].get("reason") or "") if isinstance(e, dict) else ""
        msg = e.get("message") if isinstance(e, dict) else ""
        if reason in ("quotaExceeded", "dailyLimitExceeded"):
            raise RuntimeError("Vyčerpaná denní kvóta YouTube API (obnoví se o půlnoci pacifického času, tj. ~9:00 našeho).")
        if reason == "youtubeSignupRequired":
            raise RuntimeError("Tento Google účet nemá YouTube kanál – vytvoř ho na youtube.com a propoj znovu.")
        raise RuntimeError(f"YouTube API: {msg or reason or ('HTTP ' + str(r.status_code))}")
    return data


def yt_channel(cfg) -> dict:
    d = yt_call(cfg, "GET", "/channels", params={"part": "snippet", "mine": "true"})
    items = d.get("items") or []
    if not items:
        raise RuntimeError("Tento Google účet nemá YouTube kanál – vytvoř ho na youtube.com a propoj znovu.")
    c = items[0]
    return {"id": c["id"], "title": c["snippet"]["title"], "thumb": ((c["snippet"].get("thumbnails") or {}).get("default") or {}).get("url", "")}


def yt_playlists(cfg) -> list:
    out, token = [], ""
    for _ in range(5):
        d = yt_call(cfg, "GET", "/playlists", params={"part": "snippet,status", "mine": "true", "maxResults": 50, "pageToken": token})
        out += [{"id": p["id"], "title": p["snippet"]["title"], "privacy": (p.get("status") or {}).get("privacyStatus", "")} for p in d.get("items") or []]
        token = d.get("nextPageToken") or ""
        if not token:
            break
    return out


def yt_create_playlist(cfg, title: str, privacy: str = "public") -> dict:
    d = yt_call(cfg, "POST", "/playlists", params={"part": "snippet,status"},
                json={"snippet": {"title": title[:150]}, "status": {"privacyStatus": privacy if privacy in YT_PRIVACY else "public"}})
    return {"id": d["id"], "title": d["snippet"]["title"]}


def yt_start_link(cfg) -> dict:
    """Krok 1 propojení: Google vydá kód, uživatel ho zadá na google.com/device a povolí přístup."""
    y = yt_cfg(cfg)
    if not (y.get("client_id") and y.get("client_secret")):
        raise RuntimeError("Nejdřív ulož Client ID a Client secret z Google Cloud Console.")
    r = requests.post("https://oauth2.googleapis.com/device/code", data={"client_id": y["client_id"], "scope": YT_SCOPE}, timeout=20)
    data = r.json() if r.content else {}
    if not r.ok or not data.get("device_code"):
        err = data.get("error_description") or data.get("error") or f"HTTP {r.status_code}"
        if data.get("error") == "invalid_client":
            err = "Google nezná toto Client ID – zkontroluj, že je zkopírované celé a že je klient typu „Televize a zařízení s omezeným vstupem“."
        raise RuntimeError(err)
    _yt_link.clear()
    _yt_link.update(device_code=data["device_code"], user_code=data["user_code"], url=data.get("verification_url") or "https://www.google.com/device",
                    expires=time.time() + int(data.get("expires_in", 1800)), interval=max(5, int(data.get("interval", 5))), status="waiting", error="")
    threading.Thread(target=_yt_link_poll, args=(y["client_id"], y["client_secret"]), daemon=True).start()
    return dict(_yt_link)


def _yt_link_poll(client_id: str, client_secret: str):
    dc = _yt_link.get("device_code")
    while _yt_link.get("device_code") == dc and time.time() < _yt_link.get("expires", 0):
        time.sleep(_yt_link.get("interval", 5))
        try:
            r = requests.post("https://oauth2.googleapis.com/token", data={"client_id": client_id, "client_secret": client_secret,
                              "device_code": dc, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"}, timeout=20)
            data = r.json() if r.content else {}
        except Exception as e:
            _yt_link.update(error=f"Google neodpovídá: {e}")
            continue
        err = data.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            _yt_link["interval"] = _yt_link.get("interval", 5) + 5
            continue
        if err:
            _yt_link.update(status="failed", error={"access_denied": "Přístup jsi v Googlu zamítl.", "expired_token": "Kód vypršel – zkus to znovu."}.get(err, data.get("error_description") or err))
            return
        if not data.get("refresh_token"):
            _yt_link.update(status="failed", error="Google nevrátil trvalý token – zkus propojení znovu (a při souhlasu povol vše, co Google nabídne).")
            return
        with edit_config() as cfg:
            y = dict(yt_cfg(cfg))
            y.update(refresh_token=data["refresh_token"], linked=dt.datetime.now().isoformat(timespec="seconds"))
            cfg.setdefault("studio", {})["youtube"] = y
        _yt_token.update(token=data.get("access_token", ""), until=time.time() + int(data.get("expires_in", 3600)) - 120)
        try:
            cfg = load_config()
            ch = yt_channel(cfg)
            pls = yt_playlists(cfg)
            with edit_config() as cfg:
                y = dict(yt_cfg(cfg))
                y.update(channel_id=ch["id"], channel_title=ch["title"], channel_thumb=ch.get("thumb", ""), playlists=pls)
                cfg.setdefault("studio", {})["youtube"] = y
            _yt_link.update(status="done", error="", channel=ch["title"])
            log(f"YouTube: propojen kanál „{ch['title']}“ ({len(pls)} playlistů)")
        except Exception as e:
            _yt_link.update(status="done", error=f"Propojeno, ale kanál se nepodařilo načíst: {e}")
        return
    if _yt_link.get("device_code") == dc and _yt_link.get("status") == "waiting":
        _yt_link.update(status="failed", error="Kód vypršel – klikni znovu na Propojit YouTube.")


def yt_refresh_playlists(cfg) -> list:
    pls = yt_playlists(cfg)
    with edit_config() as c:
        y = dict(yt_cfg(c)); y["playlists"] = pls; c.setdefault("studio", {})["youtube"] = y
    return pls


# ---------- nahrávání ----------
def yt_enqueue(cfg, sid: int, privacy: str, playlist_id: str, playlist_new: str = ""):
    with db() as con:
        row = con.execute("SELECT * FROM studio_videos WHERE id=?", (sid,)).fetchone()
    if not row or row["status"] != "ready":
        raise RuntimeError("Video ještě není hotové.")
    if row["yt_status"] in ("queued", "uploading"):
        raise RuntimeError("Nahrávání už probíhá.")
    meta = {"privacy": privacy if privacy in YT_PRIVACY else "unlisted", "playlist_id": playlist_id or "", "playlist_new": playlist_new.strip()[:150]}
    with db() as con:
        con.execute("UPDATE studio_videos SET yt_status='queued', yt_url=NULL, yt_meta=?, yt_error='' WHERE id=?", (json.dumps(meta, ensure_ascii=False), sid))
    yt_kick()


def yt_kick():
    global _yt_thread
    with _yt_lock:
        if _yt_thread and _yt_thread.is_alive():
            return
        _yt_thread = threading.Thread(target=_yt_worker, name="youtube", daemon=True)
        _yt_thread.start()


def _yt_worker():
    while True:
        with db() as con:
            job = con.execute("SELECT * FROM studio_videos WHERE yt_status='queued' ORDER BY id LIMIT 1").fetchone()
        if not job:
            return
        job = dict(job)
        cfg = load_config()
        with db() as con:
            con.execute("UPDATE studio_videos SET yt_status='uploading' WHERE id=?", (job["id"],))
        try:
            url = yt_upload(cfg, job)
            with db() as con:
                con.execute("UPDATE studio_videos SET yt_status='done', yt_url=?, yt_error='' WHERE id=?", (url, job["id"]))
        except Exception as e:
            msg = str(e)[:400]
            with db() as con:
                con.execute("UPDATE studio_videos SET yt_status='failed', yt_error=? WHERE id=?", (msg, job["id"]))
            log(f"YouTube: nahrání „{job['title'] or job['name']}“ selhalo: {msg}")
            add_event("warn", f"Nahrání na YouTube selhalo: {job['title'] or job['name']}", msg)
        finally:
            _yt_progress.pop(job["id"], None)
            _yt_eta.pop(job["id"], None)


def yt_upload(cfg, job: dict) -> str:
    """Obnovitelné nahrání (resumable upload) po 8 MB; vrátí adresu videa."""
    f = Path(job["file"] or "")
    if not f.is_file():
        raise RuntimeError("Soubor videa už neexistuje.")
    try:
        meta = json.loads(job.get("yt_meta") or "{}")
    except ValueError:
        meta = {}
    y = yt_cfg(cfg)
    privacy = meta.get("privacy") or y.get("privacy") or "unlisted"
    playlist_id = meta.get("playlist_id") or ""
    if meta.get("playlist_new"):
        pl = yt_create_playlist(cfg, meta["playlist_new"], "public" if privacy == "public" else "unlisted")
        playlist_id = pl["id"]
        try:
            yt_refresh_playlists(cfg)
        except Exception:
            pass
    tags = [t.strip() for t in str(y.get("tags") or "").split(",") if t.strip()][:30]
    title = (job["title"] or job["name"]).strip()[:100]
    description = (job["description"] or "").strip()
    if not description:
        # prázdný popis (staré video z 4.6.0) – sestavit ze šablony, textu AI a autora hudby
        try:
            v = _studio_vars_for_row(cfg, job)
            description = studio_fill(studio_cfg(cfg).get("description", ""), v)
            credit = music_credit(job["music"]) if job.get("music") else ""
            if credit:
                description = (description + "\n\n" + credit).strip()
            with db() as con:
                con.execute("UPDATE studio_videos SET description=? WHERE id=?", (description[:5000], job["id"]))
        except Exception as e:
            log(f"YouTube: popis se nepodařilo doplnit ({e})")
    description = description.replace("<", "‹").replace(">", "›")[:4900]   # YouTube nepovolí < > v popisu
    log(f"YouTube: nahrávám „{title}“ – popis {len(description)} znaků, {YT_PRIVACY.get(privacy, privacy)}" + (f", playlist {playlist_id}" if playlist_id else ""))
    body = {"snippet": {"title": title.replace("<", "‹").replace(">", "›"), "description": description, "tags": tags,
                        "categoryId": "22", "defaultLanguage": "cs"},
            "status": {"privacyStatus": privacy, "selfDeclaredMadeForKids": False}}
    size = f.stat().st_size
    token = yt_access_token(cfg)
    r = requests.post("https://www.googleapis.com/upload/youtube/v3/videos", params={"uploadType": "resumable", "part": "snippet,status"},
                      headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=UTF-8",
                               "X-Upload-Content-Length": str(size), "X-Upload-Content-Type": "video/mp4"},
                      json=body, timeout=30)
    if not r.ok:
        data = r.json() if r.content and "json" in r.headers.get("content-type", "") else {}
        e = (data.get("error") or {}) if isinstance(data, dict) else {}
        reason = ((e.get("errors") or [{}])[0].get("reason") or "") if isinstance(e, dict) else ""
        if reason in ("quotaExceeded", "dailyLimitExceeded"):
            raise RuntimeError("Vyčerpaná denní kvóta YouTube API (asi 6 videí denně; obnoví se ~9:00 našeho času).")
        if r.status_code in (401, 403):
            raise RuntimeError(f"YouTube odmítl nahrání ({e.get('message') or reason or r.status_code}). Zkontroluj, že je v Google Cloud zapnuté YouTube Data API v3 a že jsi při propojení povolil správu YouTube účtu.")
        raise RuntimeError(f"YouTube API: {e.get('message') or reason or ('HTTP ' + str(r.status_code))}")
    session = r.headers.get("Location")
    if not session:
        raise RuntimeError("YouTube nevrátil adresu pro nahrání.")
    chunk = 8 * 1024 * 1024
    sent = 0
    video_id = ""
    up_started = time.time()
    with f.open("rb") as fh:
        while sent < size:
            data = fh.read(chunk)
            end = sent + len(data) - 1
            for attempt in range(4):
                try:
                    pr = requests.put(session, data=data, timeout=(20, 300),
                                      headers={"Authorization": "Bearer " + yt_access_token(cfg), "Content-Length": str(len(data)),
                                               "Content-Range": f"bytes {sent}-{end}/{size}"})
                except Exception as e:
                    if attempt == 3:
                        raise RuntimeError(f"Spojení s YouTube se přerušilo: {e}")
                    time.sleep(3 * (attempt + 1))
                    continue
                if pr.status_code in (200, 201):
                    video_id = (pr.json() or {}).get("id", "")
                    sent = size
                    break
                if pr.status_code == 308:
                    rng = pr.headers.get("Range", "")
                    sent = int(rng.split("-")[-1]) + 1 if rng else end + 1
                    break
                if pr.status_code in (500, 502, 503, 504) and attempt < 3:
                    time.sleep(3 * (attempt + 1))
                    continue
                raise RuntimeError(f"YouTube nahrání selhalo (HTTP {pr.status_code}): {pr.text[:200]}")
            _yt_progress[job["id"]] = min(99, int(sent * 100 / size))
            el = time.time() - up_started
            if sent > 0 and el > 1:
                _yt_eta[job["id"]] = max(1.0, (size - sent) * el / sent)
            if sent < size and sent != end + 1:
                fh.seek(sent)
    if not video_id:
        raise RuntimeError("YouTube nevrátil ID videa.")
    url = f"https://youtu.be/{video_id}"
    if playlist_id:
        try:
            yt_call(cfg, "POST", "/playlistItems", params={"part": "snippet"},
                    json={"snippet": {"playlistId": playlist_id, "resourceId": {"kind": "youtube#video", "videoId": video_id}}})
        except Exception as e:
            log(f"YouTube: video {video_id} nahráno, ale zařazení do playlistu selhalo: {e}")
            add_event("warn", "Video je na YouTube, ale ne v playlistu", str(e))
    log(f"YouTube: „{job['title'] or job['name']}“ nahráno – {url} ({YT_PRIVACY.get(privacy, privacy)})")
    add_event("info", f"Video nahráno na YouTube: {job['title'] or job['name']}", url)
    return url


def studio_after_render(cfg, sid: int):
    """Po dorenderování automatického videa: nahrát na YouTube, je-li automatika zapnutá."""
    y = yt_cfg(cfg)
    if not (y.get("auto") and yt_linked(cfg)):
        return
    with db() as con:
        row = con.execute("SELECT auto FROM studio_videos WHERE id=?", (sid,)).fetchone()
    if row and row["auto"]:
        try:
            yt_enqueue(cfg, sid, y.get("privacy") or "unlisted", y.get("playlist_id") or "")
            log(f"YouTube: automatické video #{sid} zařazeno k nahrání")
        except Exception as e:
            log(f"YouTube: automatické nahrání se nepodařilo zařadit: {e}")


# ---------- routy ----------
@app.post("/studio/youtube/client")
def studio_yt_client(request: Request, client_id: str = Form(""), client_secret: str = Form("")):
    with edit_config() as cfg:
        y = dict(yt_cfg(cfg))
        cid, sec = client_id.strip(), client_secret.strip()
        if cid != y.get("client_id") or (sec and sec != y.get("client_secret")):
            y.pop("refresh_token", None); y.pop("channel_title", None); y.pop("playlists", None)
        y["client_id"] = cid
        if sec:
            y["client_secret"] = sec
        cfg.setdefault("studio", {})["youtube"] = y
    _yt_token.update(token="", until=0)
    flash(request, "Uloženo. Teď klikni na „Propojit YouTube“.")
    return RedirectResponse("/studio/settings#youtube", status_code=303)


@app.post("/studio/youtube/link")
def studio_yt_link(request: Request):
    try:
        yt_start_link(load_config())
    except Exception as e:
        flash(request, f"Propojení se nepodařilo spustit: {e}", "err")
    return RedirectResponse("/studio/settings#youtube", status_code=303)


@app.get("/studio/youtube/status")
def studio_yt_status():
    d = {k: v for k, v in _yt_link.items() if k != "device_code"}
    d["remaining"] = max(0, int(_yt_link.get("expires", 0) - time.time())) if _yt_link else 0
    return JSONResponse(d)


@app.post("/studio/youtube/unlink")
def studio_yt_unlink(request: Request):
    with edit_config() as cfg:
        y = dict(yt_cfg(cfg))
        for k in ("refresh_token", "channel_id", "channel_title", "channel_thumb", "playlists", "linked"):
            y.pop(k, None)
        cfg.setdefault("studio", {})["youtube"] = y
    _yt_token.update(token="", until=0)
    _yt_link.clear()
    flash(request, "YouTube odpojen (Client ID zůstává uložené).")
    return RedirectResponse("/studio/settings#youtube", status_code=303)


@app.post("/studio/youtube/playlists")
def studio_yt_playlists(request: Request):
    try:
        pls = yt_refresh_playlists(load_config())
        flash(request, f"Načteno {len(pls)} playlistů.")
    except Exception as e:
        flash(request, f"Playlisty se nepodařilo načíst: {e}", "err")
    return RedirectResponse("/studio/settings#youtube", status_code=303)


@app.post("/studio/youtube/defaults")
def studio_yt_defaults(request: Request, privacy: str = Form("unlisted"), playlist_id: str = Form(""), tags: str = Form(""), auto: str = Form("")):
    with edit_config() as cfg:
        y = dict(yt_cfg(cfg))
        y.update(privacy=privacy if privacy in YT_PRIVACY else "unlisted", playlist_id=playlist_id.strip(), tags=tags.strip()[:400], auto=bool(auto))
        cfg.setdefault("studio", {})["youtube"] = y
    flash(request, "Nastavení YouTube uloženo.")
    return RedirectResponse("/studio/settings#youtube", status_code=303)


@app.post("/studio/v/{sid}/youtube")
def studio_yt_upload_post(request: Request, sid: int, privacy: str = Form("unlisted"), playlist_id: str = Form(""), playlist_new: str = Form("")):
    cfg = load_config()
    if not yt_linked(cfg):
        flash(request, "YouTube není propojený – nastav ho v Nastavení → Video studio.", "err")
        return RedirectResponse(f"/studio/v/{sid}", status_code=303)
    with db() as con:
        # prázdný titulek (např. po chybě 4.6.0) – doplnit z názvu zdroje, YouTube ho vyžaduje
        con.execute("UPDATE studio_videos SET title=name WHERE id=? AND (title IS NULL OR title='')", (sid,))
    try:
        yt_enqueue(cfg, sid, privacy, playlist_id, playlist_new)
        flash(request, "Nahrávám na YouTube – podle velikosti videa to trvá od pár sekund do minut. Stránka se obnovuje sama.")
    except Exception as e:
        flash(request, str(e), "err")
    return RedirectResponse(f"/studio/v/{sid}", status_code=303)


@app.post("/studio/v/{sid}/cleanup")
def studio_cleanup(request: Request, sid: int, source: str = Form(""), detection: str = Form("")):
    """Po nahrání na YouTube: uklidit z RPi – video ze studia, volitelně i zdrojový klip a detekci AI (snímek, historie)."""
    cfg = load_config()
    rows = studio_rows(cfg, sid=sid)
    if not rows:
        return RedirectResponse("/videos#studio", status_code=303)
    r = rows[0]
    if r.get("yt_status") != "done":
        flash(request, "Uklidit jde až po úspěšném nahrání na YouTube.", "err")
        return RedirectResponse(f"/studio/v/{sid}", status_code=303)
    done = ["video ze studia"]
    with db() as con:
        ex = con.execute("SELECT * FROM exports WHERE id=?", (r["export_id"],)).fetchone()
    det_id = ex["detection_id"] if ex else None
    studio_delete(cfg, r)
    if source and ex:
        with db() as con:
            others = con.execute("SELECT COUNT(*) FROM studio_videos WHERE export_id=?", (r["export_id"],)).fetchone()[0]
        if others:
            flash(request, "Zdrojový klip zůstal – používá ho ještě jiné video ze studia.", "err")
        else:
            delete_export(cfg, dict(ex))
            done.append("vystřižený klip")
    if detection and det_id:
        with db() as con:
            con.execute("DELETE FROM auto_exports WHERE detection_id=?", (det_id,))
        n = _delete_evaluations(cfg, "id=?", (det_id,))
        if n:
            done.append("detekce AI se snímkem")
    log(f"Studio: po nahrání na YouTube uklizeno – {', '.join(done)} ({r['yt_url']})")
    flash(request, f"Uklizeno z RPi: {', '.join(done)}. Video zůstává na YouTube: {r['yt_url']}")
    return RedirectResponse("/videos#studio", status_code=303)


@app.post("/studio/v/{sid}/youtube/reset")
def studio_yt_reset(request: Request, sid: int):
    with db() as con:
        con.execute("UPDATE studio_videos SET yt_status=NULL, yt_error='' WHERE id=? AND yt_status IN ('failed','queued','uploading')", (sid,))
    return RedirectResponse(f"/studio/v/{sid}", status_code=303)


def _delete_evaluations(cfg, where: str, args: tuple) -> int:
    """Smaže záznamy vyhodnocení včetně jejich snímků; vrací počet."""
    base = Path(cfg["snapshot_dir"]).resolve()
    with db() as con:
        rows = [dict(r) for r in con.execute(f"SELECT id, image FROM evaluations WHERE {where}", args)]
        con.execute(f"DELETE FROM evaluations WHERE {where}", args)
    for row in rows:
        if row.get("image"):
            try:
                f = (base / row["image"]).resolve()
                if base in f.parents and f.is_file():
                    f.unlink()
            except Exception:
                pass
    return len(rows)


@app.post("/history/delete")
def history_delete(request: Request, what: str = Form(...), camera: str = Form("")):
    cfg = load_config()
    if what == "errors":
        n = _delete_evaluations(cfg, "error IS NOT NULL AND error != ''", ())
        flash(request, f"Smazáno {n} chybných vyhodnocení.")
    elif what == "skipped":
        n = _delete_evaluations(cfg, "skipped=1", ())
        flash(request, f"Smazáno {n} přeskočených snímků.")
    elif what == "all":
        n = _delete_evaluations(cfg, "camera=?", (camera,)) if camera else _delete_evaluations(cfg, "1=1", ())
        flash(request, f"Smazáno {n} záznamů historie.")
    else:
        flash(request, "Neplatný požadavek.", "err")
    return RedirectResponse("/history", status_code=303)


@app.post("/detection/{rid}/delete")
def detection_delete(request: Request, rid: int):
    cfg = load_config()
    with db() as con:
        row = con.execute("SELECT image FROM evaluations WHERE id=?", (rid,)).fetchone()
        con.execute("DELETE FROM evaluations WHERE id=?", (rid,))
    if row and row["image"]:
        try:
            base = Path(cfg["snapshot_dir"]).resolve()
            f = (base / row["image"]).resolve()
            if base in f.parents and f.is_file():
                f.unlink()
        except Exception:
            pass
    flash(request, "Detekce smazána.")
    return RedirectResponse("/history", status_code=303)


@app.get("/snapshot/{path:path}")
def snapshot(path: str):
    if not storage_ready():
        return JSONResponse({"error": "HDD nedostupný"}, status_code=503)
    cfg = load_config()
    base = Path(cfg["snapshot_dir"]).resolve()
    f = (base / path).resolve()
    if base not in f.parents or not f.is_file():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(f, media_type="image/jpeg")


# ---- e-mail a upozornění

@app.get("/email", response_class=HTMLResponse)
def email_page(request: Request):
    cfg = load_config()
    return render(request, "email.html", "Upozornění", em=cfg["email"], al=cfg["alerts"], events=recent_events(20),
                  web=cfg["web"], web_ok=web_ready(cfg), web_error=watcher.web_error)


def _web_from_form(form, cfg):
    w = cfg["web"]
    w["enabled"] = bool(form.get("enabled"))
    w["thumbs"] = bool(form.get("thumbs"))
    for k in ("url", "token", "nvr_name"):
        w[k] = str(form.get(k, w[k])).strip()
    if w["enabled"] and not re.match(r"^https?://[^\s]+$", w["url"]):
        raise ValueError("Zadej platnou adresu přijímače (https://…/webhook.php).")
    return w


def save_web_form(form):
    with edit_config() as cfg:
        return _web_from_form(form, cfg)


@app.post("/web")
async def web_save(request: Request):
    try:
        await run_in_threadpool(save_web_form, await request.form())
        flash(request, "Propojení s webem uloženo.")
    except ValueError as e:
        flash(request, str(e), "err")
    return RedirectResponse("/email", status_code=303)


@app.post("/web/test")
async def web_test(request: Request):
    try:
        await run_in_threadpool(save_web_form, await request.form())
        cfg = load_config()
        if not cfg["web"]["token"]:
            raise ValueError("Chybí token.")
        resp = await run_in_threadpool(web_post, cfg, {"type": "ping"})
        await run_in_threadpool(web_event, cfg, "test", "Test spojení Atmovio",
                                f"Spojení RPi → web funguje. Server: {resp.get('nvr', '')}, čas serveru {resp.get('server_time', '')}.")
        watcher.web_error = ""
        watcher._last_watchdog = 0
        flash(request, f"Spojení funguje – web zná tento záznamník jako „{resp.get('nvr', '')}“. Na web odešlo testovací upozornění.")
    except Exception as e:
        watcher.web_error = str(e)
        flash(request, f"Spojení selhalo: {e}", "err")
    return RedirectResponse("/email", status_code=303)


def _email_from_form(form, cfg):
    em = cfg["email"]
    for k in ("host", "user", "password", "from", "to", "security"):
        value = str(form.get(k, em[k]))
        em[k] = value if k == "password" else value.strip()
    try:
        em["port"] = int(form.get("port", em["port"]))
    except ValueError:
        pass
    em["attach"] = bool(form.get("attach"))
    if not 1 <= em["port"] <= 65535 or em["security"] not in ("ssl", "starttls", "none"):
        raise ValueError("Neplatný SMTP port nebo zabezpečení.")
    return em


def save_email_form(form):
    with edit_config() as cfg:
        return _email_from_form(form, cfg)


@app.post("/email")
async def email_save(request: Request):
    try:
        await run_in_threadpool(save_email_form, await request.form())
        flash(request, "Nastavení e-mailu uloženo.")
    except ValueError as e:
        flash(request, str(e), "err")
    return RedirectResponse("/email", status_code=303)


@app.post("/email/test")
async def email_test(request: Request):
    try:
        em = await run_in_threadpool(save_email_form, await request.form())
        await run_in_threadpool(send_email, em, "[Atmovio] Testovací e-mail", "Pokud čteš tento e-mail, odesílání z Raspberry Pi funguje.\n")
        flash(request, f"Testovací e-mail odeslán na {em['to']}.")
    except Exception as e:
        flash(request, f"Odeslání selhalo: {e}", "err")
    return RedirectResponse("/email", status_code=303)


@app.post("/alerts")
async def alerts_save(request: Request):
    form = await request.form()
    with edit_config() as cfg:
        al = cfg["alerts"]
        for key in ("camera_outage", "frigate", "storage", "recovery"):
            al[key] = bool(form.get(key))
        for key, lo, hi in (("outage_min", 1, 1440), ("repeat_h", 1, 168)):
            try:
                al[key] = max(lo, min(hi, int(form.get(key, al[key]))))
            except ValueError:
                pass
    flash(request, "Hlídání výpadků uloženo.")
    return RedirectResponse("/email", status_code=303)


# ---- VPN

def wg_conf_path(iface: str) -> Path:
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,15}", iface):
        raise ValueError("Neplatný název WireGuard rozhraní.")
    return Path(f"/etc/wireguard/{iface}.conf")


WG_DROP_KEYS = {"DNS", "PostUp", "PostDown", "PreUp", "PreDown", "Table", "SaveConfig", "FwMark"}


def local_networks() -> list[ipaddress.IPv4Network]:
    """Sítě, ve kterých RPi žije (LAN, docker…) – ty nikdy nesmí jít tunelem."""
    nets: list[ipaddress.IPv4Network] = []
    _rc, out = run(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=5)
    for m in re.finditer(r"\binet\s+(\d+\.\d+\.\d+\.\d+/\d+)", out or ""):
        try:
            nets.append(ipaddress.ip_interface(m.group(1)).network)
        except ValueError:
            pass
    return nets


def default_gateway() -> str:
    _rc, out = run(["ip", "-4", "route", "show", "default"], timeout=5)
    m = re.search(r"default via (\d+\.\d+\.\d+\.\d+)", out or "")
    return m.group(1) if m else ""


def wg_guess_networks(addresses: list[str], remote_ip: str = "") -> list[str]:
    """Z Address tunelu (a IP vzdálené kamery) odhadne sítě, které mají jít tunelem místo 0.0.0.0/0."""
    nets: list[ipaddress.IPv4Network] = []

    def add(net):
        if net.version == 4 and not any(net.subnet_of(n) for n in nets):
            nets.append(net)

    for a in addresses:
        try:
            iface = ipaddress.ip_interface(a.strip())
        except ValueError:
            continue
        if iface.version != 4:
            continue
        # Router často exportuje /32 – pak vezmeme celou /24 síť tunelu.
        add(iface.network if iface.network.prefixlen < 30 else ipaddress.ip_network(f"{iface.ip}/24", strict=False))
    if remote_ip:
        try:
            rip = ipaddress.ip_address(remote_ip.strip())
            if rip.version == 4 and not any(rip in n for n in nets):
                add(ipaddress.ip_network(f"{rip}/24", strict=False))
        except ValueError:
            pass
    return [str(n) for n in nets]


def normalize_wg_config(conf: str, previous: str = "", remote_ip: str = "") -> tuple[str, list[str]]:
    """Přijme konfiguraci klienta tak, jak ji vygeneroval router, a upraví ji pro RPi.

    Nepodporované řádky (DNS, skripty, směrovací tabulky) vynechá a AllowedIPs 0.0.0.0/0 nahradí
    konkrétními sítěmi – tunelem pak jde jen provoz ke vzdálené kameře, všechno ostatní zůstává doma.
    Vrací (text konfigurace, seznam poznámek pro uživatele). Při skutečné chybě vyhodí ValueError.
    """
    allowed = {
        "Interface": {"PrivateKey", "Address", "ListenPort", "MTU"},
        "Peer": {"PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"},
    }
    section = None
    seen: set[str] = set()
    output: list[str] = []
    notes: list[str] = []
    addresses: list[str] = []
    peer_keys: set[str] = set()
    allowed_ips_lines: list[int] = []
    for raw in conf.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line in ("[Interface]", "[Peer]"):
            section = line[1:-1]
            seen.add(section)
            output.append(line)
            continue
        key, sep, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if sep and key in WG_DROP_KEYS:
            why = "na RPi není potřeba" if key == "DNS" else "skripty a změny směrování se z webu nespouští"
            notes.append(f"Řádek „{key} = {value[:40]}“ jsem vynechal ({why}).")
            continue
        if not sep or section is None or key not in allowed[section]:
            raise ValueError(f"Řádku „{line[:60]}“ nerozumím. Vlož konfiguraci klienta WireGuard přesně tak, jak ji vygeneroval router (sekce [Interface] a [Peer]).")
        if key == "PrivateKey" and value.startswith("<uloženo"):
            old = re.search(r"(?m)^\s*PrivateKey\s*=\s*(\S+)\s*$", previous)
            if not old:
                raise ValueError("Vlož privátní klíč tunelu (PrivateKey) – dřívější klíč není uložen.")
            value = old.group(1)
        if key == "Address":
            addresses.extend(value.split(","))
        if section == "Peer":
            peer_keys.add(key)
        if key == "AllowedIPs":
            allowed_ips_lines.append(len(output))
        output.append(f"{key} = {value}")

    if seen != {"Interface", "Peer"}:
        raise ValueError("Konfigurace musí obsahovat sekce [Interface] a [Peer] – zkopíruj ji z routeru celou.")
    if "Endpoint" not in peer_keys:
        raise ValueError("V části [Peer] chybí Endpoint (veřejná adresa routeru a port) – bez něj se tunel nespojí.")
    if "PublicKey" not in peer_keys:
        raise ValueError("V části [Peer] chybí PublicKey routeru.")
    if not allowed_ips_lines:
        raise ValueError("V části [Peer] chybí AllowedIPs (vzdálená síť, např. 10.10.10.0/24).")

    # AllowedIPs: vyhoď výchozí trasy (/0) a nahraď je konkrétními sítěmi.
    docker = ipaddress.ip_network("172.16.0.0/12")
    own = []
    for addr in addresses:
        try:
            own.append(ipaddress.ip_interface(addr.strip()).ip)
        except ValueError:
            pass
    # sítě dockeru neřešíme; adresa samotného tunelu (10.10.10.5/32, když už běží) není domácí síť
    home = [n for n in local_networks() if not n.subnet_of(docker) and not any(ip in n for ip in own)]
    for idx in allowed_ips_lines:
        keep: list[str] = []
        replaced = False
        for network in output[idx].partition("=")[2].split(","):
            network = network.strip()
            if not network:
                continue
            try:
                net = ipaddress.ip_network(network, strict=False)
            except ValueError:
                raise ValueError(f"AllowedIPs obsahuje neplatnou síť „{network}“.")
            if net.prefixlen == 0:
                replaced = True
                continue
            if net.version == 4 and any(net.overlaps(h) for h in home):
                raise ValueError(f"AllowedIPs obsahuje síť {net}, ve které je i toto RPi (domácí síť {', '.join(map(str, home))}). "
                                 "Tunel by odřízl RPi od domácí sítě. Vzdálená síť na chatě musí mít jiný rozsah než domácí – změň ji v routeru na chatě (např. 192.168.50.0/24).")
            keep.append(str(net))
        if replaced:
            guess = [g for g in wg_guess_networks(addresses, (remote_ip or "").split(",")[0].strip())
                     if g not in keep and not any(ipaddress.ip_network(g).overlaps(h) for h in home)]
            if not keep and not guess:
                raise ValueError("AllowedIPs = 0.0.0.0/0 by poslalo veškerý provoz RPi tunelem. Napiš tam jen vzdálenou síť, např. 10.10.10.0/24.")
            keep.extend(guess)
            notes.append("AllowedIPs 0.0.0.0/0 (veškerý internet přes VPN) jsem nahradil sítí " + ", ".join(keep)
                         + " – tunelem půjde jen provoz ke vzdálené kameře, ostatní (web, e-mail, AI) zůstane doma. "
                         "Pokud je kamera v jiné síti, doplň ji do AllowedIPs ručně.")
        # Tunelem má jít jen provoz ke kameře na chatě, ne celá síť VPN: ve stejné síti bývají i telefony
        # připojené přes VPN domů a RPi by jim odpovídalo tunelem místo přes router (192.168.0.x by z VPN nešla).
        rips = []
        for item in (remote_ip or "").split(","):
            try:
                rips.append(ipaddress.ip_address(item.strip()))
            except ValueError:
                pass
        if rips:
            narrowed = []
            for network in keep:
                net = ipaddress.ip_network(network, strict=False)
                inside = [ip for ip in rips if ip in net]
                if inside and net.prefixlen < net.max_prefixlen:
                    hosts = [f"{ip}/{net.max_prefixlen}" for ip in inside]
                    narrowed.extend(h for h in hosts if h not in narrowed)
                    notes.append(f"AllowedIPs {net} jsem zúžil jen na kamery ({', '.join(str(ip) for ip in inside)}) – ostatní zařízení "
                                 "z VPN (třeba telefon) pak vidí RPi i na domácí adrese. Další kameru na chatě stačí přidat ve Atmovio a VPN znovu uložit.")
                else:
                    narrowed.append(network)
            keep = narrowed
        output[idx] = "AllowedIPs = " + ", ".join(keep)
    return "\n".join(output) + "\n", notes


def validate_wg_config(conf: str, previous="", remote_ip="") -> str:
    return normalize_wg_config(conf, previous, remote_ip)[0]


@app.get("/vpn", response_class=HTMLResponse)
def vpn_page(request: Request):
    cfg = load_config()
    v = cfg["vpn"]
    iface = v["iface"]
    p = wg_conf_path(iface)
    conf = ""
    if p.exists():
        conf = re.sub(r"(PrivateKey\s*=\s*)\S+", r"\1<uloženo – při změně vlož znovu>", p.read_text())
    _rc, wg = run(["wg", "show", iface], timeout=5)
    rc_en, _o = run(["systemctl", "is-enabled", f"wg-quick@{iface}"], timeout=5)
    cameras = frigate_cameras(cfg)
    return render(request, "vpn.html", "Síť a VPN", v=v, conf=conf, wg=wg if vpn_is_up(iface) else "",
                  up=vpn_is_up(iface), enabled=rc_en == 0, ping=request.session.pop("ping", None),
                  s=sys_info(), caminfo={c: camera_info(cfg, c) for c in cameras})


@app.post("/vpn/save")
def vpn_save(request: Request, conf: str = Form(...)):
    cfg = load_config()
    iface = cfg["vpn"]["iface"]
    p = wg_conf_path(iface)
    previous = p.read_text() if p.exists() else None
    # Tunelem mají jít jen adresy kamer: ověřovací IP + IP všech nastavených kamer.
    remote_ips = [cfg["vpn"].get("test_ip", "")] + [camera_info(cfg, c).get("ip", "") for c in frigate_cameras(cfg)]
    try:
        conf, notes = normalize_wg_config(conf, previous or "", ",".join(ip for ip in remote_ips if ip))
    except ValueError as e:
        log(f"VPN: konfigurace odmítnuta – {e}")
        flash(request, str(e), "err")
        return RedirectResponse("/vpn", status_code=303)
    for n in notes:
        log(f"VPN: {n}")
    was_up = vpn_is_up(iface)
    rc, out = run(["systemctl", "stop", f"wg-quick@{iface}"], timeout=30)
    if rc:
        flash(request, f"Původní tunel se nepodařilo zastavit: {out}", "err")
        return RedirectResponse("/vpn", status_code=303)
    atomic_write(p, conf)
    rc, out = run(["systemctl", "start", f"wg-quick@{iface}"], timeout=60)
    _camera_info_cache.clear()
    if rc == 0:
        broken = vpn_breaks_lan(iface)
        if broken:
            run(["systemctl", "stop", f"wg-quick@{iface}"], timeout=30)
            rc, out = 1, broken
    if rc == 0:
        rc, out = run(["systemctl", "enable", f"wg-quick@{iface}"], timeout=30)
        log(f"VPN: tunel {iface} spuštěn" + ("" if rc == 0 else f", enable selhal: {out}"))
        watcher.vpn_problem = ""
        msg = "Tunel uložen a aktivován." if rc == 0 else f"Tunel běží, ale start po restartu se nepodařilo zapnout: {out}"
        if notes:
            msg += " " + " ".join(notes)
        flash(request, msg, "" if rc == 0 else "err")
    else:
        if previous is None:
            p.unlink(missing_ok=True)
        else:
            atomic_write(p, previous)
        restored = "Původní konfigurace obnovena."
        if was_up:
            restore_rc, restore_out = run(["systemctl", "start", f"wg-quick@{iface}"], timeout=60)
            if restore_rc:
                restored += f" Původní tunel se nepodařilo spustit: {restore_out}"
        _rc, journal = run(["journalctl", "-u", f"wg-quick@{iface}", "-n", "15", "--no-pager", "-o", "cat"], timeout=10)
        log(f"VPN: start tunelu selhal: {out}\n{journal}")
        flash(request, f"Tunel se nepodařilo spustit: {wg_error_hint(out + ' ' + journal)} {restored} Podrobnosti najdeš v Logy → VPN.", "err")
    return RedirectResponse("/vpn", status_code=303)


def vpn_breaks_lan(iface: str) -> str:
    """Po startu tunelu ověří, že domácí síť a internet nejdou tunelem. Vrací popis problému nebo ''."""
    gw = default_gateway()
    checks = [gw] if gw else []
    checks.append("1.1.1.1")
    for target in checks:
        rc, route = run(["ip", "route", "get", target], timeout=5)
        m = re.search(r"\bdev\s+(\S+)", route or "")
        if rc == 0 and m and m.group(1) == iface:
            what = "domácí síť (brána routeru)" if target == gw else "internet"
            return f"Tunel by odřízl {what} – cesta k {target} vedla přes {iface}. Tunel jsem hned zastavil. Zkontroluj AllowedIPs: musí obsahovat jen síť na chatě, ne domácí síť ani 0.0.0.0/0."
    return ""


def wg_error_hint(out: str) -> str:
    """Přeloží nejčastější chyby wg-quick do lidské řeči."""
    o = out.lower()
    if "resolvconf" in o:
        return "konfigurace obsahuje DNS, které RPi neumí nastavit."
    if "key is not the correct length" in o or "invalid key" in o or "parse error" in o.replace("_", " "):
        return "klíč nebo některý řádek má špatný formát (zkontroluj, že se při kopírování nic neuřízlo)."
    if "name or service not known" in o or "temporary failure in name resolution" in o or "endpoint" in o and "resolve" in o:
        return "adresu routeru v Endpoint se nepodařilo přeložit (RPi nemá internet, nebo je adresa špatně)."
    if "address already in use" in o or "already exists" in o:
        return "rozhraní už existuje – zkus Stop a znovu Uložit."
    if "rtnetlink" in o and "file exists" in o:
        return "síť v AllowedIPs se překrývá se sítí, kterou už RPi zná (např. domácí LAN)."
    return out.strip()[:400] or "neznámá chyba."



@app.post("/vpn/ctl")
def vpn_ctl(request: Request, action: str = Form(...)):
    cfg = load_config()
    iface = cfg["vpn"]["iface"]
    unit = f"wg-quick@{iface}"
    if action == "up":
        rc, out = run(["systemctl", "enable", "--now", unit], timeout=60)
    elif action == "down":
        rc, out = run(["systemctl", "disable", "--now", unit], timeout=60)
    elif action == "restart":
        rc, out = run(["systemctl", "restart", unit], timeout=60)
    elif action == "remove":
        run(["systemctl", "disable", "--now", unit], timeout=60)
        try:
            wg_conf_path(iface).unlink()
        except FileNotFoundError:
            pass
        rc, out = 0, ""
    else:
        rc, out = 1, "neznámá akce"
    _camera_info_cache.clear()
    flash(request, "Hotovo." if rc == 0 else f"Chyba: {out}", "" if rc == 0 else "err")
    return RedirectResponse("/vpn", status_code=303)


@app.post("/vpn/ping")
def vpn_ping(request: Request, test_ip: str = Form("")):
    try:
        test_ip = str(ipaddress.ip_address(test_ip.strip()))
    except ValueError:
        flash(request, "Zadej platnou IP adresu kamery.", "err")
        return RedirectResponse("/vpn", status_code=303)
    with edit_config() as current:
        current["vpn"]["test_ip"] = test_ip
    if test_ip:
        _rc, out = run(["ping", "-c", "3", "-W", "2", test_ip], timeout=15)
        _rc2, route = run(["ip", "route", "get", test_ip], timeout=5)
        request.session["ping"] = f"$ ip route get {test_ip}\n{route}\n\n$ ping -c 3 {test_ip}\n{out}"
    return RedirectResponse("/vpn", status_code=303)


# ---- logs

LOG_SOURCES = [
    ("atmovio", "Atmovio", "Hlídání oblohy (AI), kamery, upozornění, e-maily, změny nastavení – vše, co dělá Atmovio."),
    ("storage", "Disk a nahrávání", "Správce HDD: připojení disku, přepínání živý režim / nahrávání."),
    ("vpn", "VPN", "Tunel WireGuard: start, stop a důvody, proč se nespojil."),
    ("frigate", "Frigate", "Přehrávač a nahrávání záznamů (kontejner Frigate): chyby kamer, streamů a disku."),
    ("system", "Systém", "Varování a chyby celého Raspberry Pi (jádro, služby, Docker)."),
]


def log_since(src: str) -> str:
    """Čas, od kterého se log zobrazuje (po stisku Vymazat). Prázdné = vše."""
    return str(load_config().get("log_since", {}).get(src, ""))


def _journal(args: list[str], n: int, since: str) -> str:
    cmd = ["journalctl", *args, "-n", str(n), "--no-pager", "-o", "short-iso"]
    if since:
        cmd += ["--since", since]
    _rc, out = run(cmd, timeout=20)
    return "" if "-- No entries --" in out else out


def read_log_source(src: str, n: int = 300) -> str:
    n = max(20, min(int(n), 5000))
    since = log_since(src)
    if src == "atmovio":
        try:
            lines = LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            lines = []
        journal = _journal(["-u", "atmovio", "-p", "warning"], 40, since)
        text = "\n".join(lines[-n:])
        if journal:
            text += "\n\n# Služba atmovio (varování ze systemd):\n" + journal
        return text
    if src == "storage":
        return _journal(["-u", "nvr-storage"], n, since)
    if src == "vpn":
        iface = load_config()["vpn"]["iface"]
        out = _journal(["-u", f"wg-quick@{iface}"], n, since)
        _rc2, wg = run(["wg", "show", iface], timeout=5)
        return (f"# Aktuální stav tunelu {iface}:\n{wg or 'tunel neběží'}\n\n# Historie:\n" + out)
    if src == "frigate":
        cmd = ["docker", "logs", "--tail", str(n)] + (["--since", since.replace(" ", "T")] if since else []) + [FRIGATE_CONTAINER]
        _rc, out = run(cmd, timeout=20)
        # Frigate hlásí chybnou konfiguraci jen jednou při startu – zvýrazni ji nahoře, ať se v logu neztratí.
        problem = frigate_safe_mode()
        if problem:
            out = f"# POZOR: Frigate běží v NOUZOVÉM režimu a nenahrává. Chyba konfigurace: {problem}\n\n" + out
        return out
    if src == "system":
        return _journal(["-p", "warning"], n, since)
    return ""


# Srozumitelný log: každý řádek dostane úroveň a lidské vysvětlení.
#   err  = vyžaduje zásah    warn = stojí za pozornost    note = přechodné, vyřešilo se samo    ok = běžný provoz
_LOG_RULES = [
    (r"Spojení s webem obnoveno", "ok", "spojení s webem zase funguje"),
    (r"Heartbeat na web selh", "note", "hosting webu chvíli neodpověděl – data se doposlala, spojení se obnovilo samo"),
    (r"AI: poskytovatel .*zkouším znovu", "note", "poskytovatel AI chvíli neodpovídal – stejný snímek se posílá znovu"),
    (r"AI: .*(timed out|timeout|503|502|529|429|Service Unavailable|overloaded|Read timed)", "note", "poskytovatel AI byl přetížený i po 3 pokusech – kamera se zkontroluje znovu za 2 minuty"),
    (r"AI: .*(401|403|API key|api key|invalid|PERMISSION_DENIED|Unauthorized)", "err", "AI odmítá klíč – zkontroluj ho v Nastavení → AI → Kdo hodnotí"),
    (r"AI: .*(quota|RESOURCE_EXHAUSTED|limit)", "warn", "vyčerpaný denní limit poskytovatele AI – do půlnoci se nehlídá, nebo zvol placený tarif / jiného poskytovatele"),
    (r"Aktualizace .*(selhala|rollback|obnoven)", "err", "aktualizace se nepovedla a původní verze byla obnovena – pošli tento log na GitHub"),
    (r"S\.M\.A\.R\.T\..*(SELHÁNÍ|roste|ZMĚNA)", "err", "disk hlásí zhoršení – zálohuj a naplánuj výměnu"),
    (r"S\.M\.A\.R\.T\.", "warn", "disk hlásí vadné sektory – sleduje se, jestli počet roste"),
    (r"Kamera .* (neposílá|výpadek|nedostupn)", "warn", "kamera nedává obraz – zkontroluj napájení a síť"),
    (r"(opět|znovu) (běží|posílá|dostupn)|obnoveno", "ok", "výpadek skončil"),
    (r"Nahrávání neběží|Frigate odmítl|storage guard|Disk pro záznamy (zmizel|není)", "err", "nahrávání stojí – podívej se na Záznamy / Systém"),
    (r"Video .* (nepodařilo|selhal)", "warn", "video se nepodařilo vytvořit – zkus to z detailu detekce znovu"),
    (r"Nepodařilo se získat snímek", "note", "kamera nebo Frigate zrovna nedaly snímek – AI kontrola se přeskočila; když se to opakuje, zkontroluj kameru"),
    (r"Traceback|Exception|nepodařilo|selhal|chyba|error", "err", "chyba – když se opakuje, pošli tento řádek na GitHub"),
    (r"smyčka spuštěna", "ok", "služba (znovu) naběhla – po aktualizaci nebo restartu"),
    (r"K dispozici je nová verze|Aktualizace .* spuštěna|Log .* vymazán", "ok", ""),
    (r"Automatické video|zadáno k vytvoření|naplánováno", "ok", ""),
]


def classify_log_line(line: str) -> tuple[str, str]:
    for pat, level, why in _LOG_RULES:
        if re.search(pat, line, re.I):
            return level, why
    return "ok", ""


def log_rows(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        level, why = classify_log_line(line)
        m = re.match(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})\s*(.*)$", line)
        rows.append({"ts": m.group(1).replace("T", " ") if m else "", "text": m.group(2) if m else line, "level": level, "why": why})
    return rows


def log_summary(text: str) -> list[tuple[str, str]]:
    counts = {"err": 0, "warn": 0, "note": 0}
    for line in text.splitlines():
        level, _ = classify_log_line(line)
        if level in counts:
            counts[level] += 1
    out = []
    if counts["err"]:
        out.append((f"{counts['err']}× chyba – vyžaduje zásah", "err"))
    if counts["warn"]:
        out.append((f"{counts['warn']}× stojí za pozornost", "warn"))
    if counts["note"]:
        out.append((f"{counts['note']}× přechodné – vyřešilo se samo", "info"))
    if not out:
        out.append(("vše v pořádku", "ok"))
    return out


@app.get("/logs", response_class=HTMLResponse)
def logs_page(request: Request, src: str = "atmovio", n: int = 300, q: str = "", raw: str = ""):
    keys = [k for k, _n, _d in LOG_SOURCES]
    if src not in keys:
        src = "atmovio"
    n = n if n in (100, 300, 1000) else 300
    text = read_log_source(src, n)
    q = q.strip()[:80]
    if src == "frigate" and not raw:
        # Provozní řádky webserveru (každou minutu dotaz Atmovioe a kontrola živosti) nejsou chyby – schovej je.
        text = "\n".join(line for line in text.splitlines()
                         if not re.search(r'request_time=|" 400 0 "-"|s6-rc: info:', line))
    if q:
        text = "\n".join(line for line in text.splitlines() if q.lower() in line.lower())
    desc = dict((k, d) for k, _n, d in LOG_SOURCES)[src]
    rows = log_rows(text) if src == "atmovio" else []
    # Nahlášení na GitHub: předvyplněné issue s chybovými řádky (bez osobních údajů – jen log a verze)
    issue_url = ""
    bad = [r for r in rows if r["level"] in ("err", "warn")]
    if bad:
        lines = "\n".join(f"{r['ts']} {r['text']}" for r in bad[-25:])
        body = (f"**Atmovio {APP_VERSION}** · Raspberry Pi OS\n\n"
                f"Co jsem čekal / co se stalo:\n(doplň prosím)\n\n```\n{lines[:5000]}\n```\n")
        issue_url = ("https://github.com/" + GITHUB_REPO + "/issues/new?labels=bug&title="
                     + quote(f"[{APP_VERSION}] " + bad[-1]["text"][:70]) + "&body=" + quote(body))
    return render(request, "logs.html", "Logy", sources=LOG_SOURCES, src=src, n=n, q=q, desc=desc, text=text,
                  rows=rows if not raw else [], issue_url=issue_url,
                  summary=log_summary(text), since=log_since(src), raw=raw)


@app.post("/logs/clear")
def logs_clear(request: Request, src: str = Form("atmovio")):
    keys = [k for k, _n, _d in LOG_SOURCES]
    if src not in keys:
        src = "atmovio"
    if src == "atmovio":
        try:
            for h in _logger.handlers:
                h.acquire()
                try:
                    h.stream.close()
                    h.stream = h._open()
                finally:
                    h.release()
            LOG_FILE.write_text("", encoding="utf-8")
            for i in range(1, 4):
                Path(f"{LOG_FILE}.{i}").unlink(missing_ok=True)
        except Exception as e:
            flash(request, f"Log se nepodařilo vymazat: {e}", "err")
            return RedirectResponse("/logs?src=atmovio", status_code=303)
        log("Log Atmovio vymazán uživatelem")
    cfg = load_config()
    cfg.setdefault("log_since", {})[src] = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    save_config(cfg)
    flash(request, "Log vymazán – zobrazují se jen nové záznamy." if src != "atmovio" else "Log Atmovio vymazán.")
    return RedirectResponse(f"/logs?src={src}", status_code=303)


@app.get("/logs/download")
def logs_download(request: Request, src: str = "atmovio"):
    keys = [k for k, _n, _d in LOG_SOURCES]
    if src not in keys:
        src = "atmovio"
    text = read_log_source(src, 5000)
    name = f"atmovio-log-{src}-{dt.datetime.now().strftime('%Y%m%d-%H%M')}.txt"
    return Response(text, media_type="text/plain; charset=utf-8", headers={"Content-Disposition": f"attachment; filename={name}"})


# ---- system

@app.get("/system", response_class=HTMLResponse)
def system_page(request: Request):
    _rc, docker = run("docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'", timeout=15)
    cfg = load_config()
    return render(request, "system.html", "Systém", s=sys_info(), docker=docker, version=APP_VERSION, web_ok=web_ready(cfg),
                  frigate_pw=request.session.pop("frigate_pw", None), disks_health=disk_health(),
                  new_api_key=request.session.pop("new_api_key", None), api_keys=cfg.get("api_keys") or [])


@app.post("/system/ctl")
def system_ctl(request: Request, action: str = Form(...)):
    cfg = load_config()
    if action == "reboot":
        subprocess.Popen(["bash", "-c", "sleep 2; systemctl reboot"])
        flash(request, "Raspberry Pi se restartuje…")
    elif action == "fix_frigate":
        fixes = frigate_fix_config(cfg)
        rc, out = frigate_restart()
        watcher.frigate_problem = ""
        flash(request, ("Opraveno: " + "; ".join(fixes) + ". " if fixes else "V konfiguraci jsem nenašel nic k opravě. ")
              + ("Frigate se restartuje – za minutu zkontroluj Přehled." if rc == 0 else out), "" if rc == 0 else "err")
    elif action == "restart_frigate":
        rc, out = frigate_restart()
        flash(request, "Frigate restartován." if rc == 0 else out, "" if rc == 0 else "err")
    elif action == "restart_portainer":
        rc, out = run(["docker", "restart", "portainer"], timeout=60)
        flash(request, "Portainer restartován." if rc == 0 else out, "" if rc == 0 else "err")
    elif action == "update":
        # Frigate spouští správce až po ověření HDD.
        rc, out = run("cd /opt/nvr && docker compose pull && docker compose up -d portainer", timeout=900)
        if rc == 0:
            rc, out = frigate_restart()
        flash(request, "Kontejnery aktualizovány." if rc == 0 else out[-800:], "" if rc == 0 else "err")
    elif action == "frigate_pw":
        if not storage_ready():
            flash(request, "Heslo Frigate měň až po obnovení HDD; živý režim používá kopii přístupů.", "err")
            return RedirectResponse("/system", status_code=303)
        pw = frigate_reset_admin_password(cfg)
        if pw:
            request.session["frigate_pw"] = pw
            flash(request, "Nové heslo Frigate vygenerováno.")
        else:
            flash(request, "Heslo se nepodařilo vyčíst z logu – zkus 'docker logs frigate | grep -i password'.", "err")
    return RedirectResponse("/system", status_code=303)


@app.get("/system/update", response_class=HTMLResponse)
def update_page(request: Request):
    cfg = load_config()
    return render(request, "update.html", "Aktualizace Atmovio", st=update_state(), running=update_running(),
                  log_text=update_log_tail(), auto_check=bool((cfg.get("update") or {}).get("auto_check", True)))


@app.get("/system/update/status")
def update_status():
    return {"running": update_running(), "version": APP_VERSION, "log": update_log_tail(), "state": update_state()}


@app.post("/system/update/check")
def update_check(request: Request):
    st = check_for_update()
    if st.get("error"):
        flash(request, "Kontrola se nepovedla: " + st["error"], "err")
    elif st["available"]:
        flash(request, f"K dispozici je verze {st['latest']}.")
    elif st.get("latest"):
        flash(request, f"Máš nejnovější verzi ({APP_VERSION}).")
    else:
        flash(request, "Na GitHubu zatím není žádné vydání.")
    return RedirectResponse("/system/update", status_code=303)


@app.post("/system/update/start")
def update_start(request: Request):
    err = start_update()
    if err:
        flash(request, err, "err")
    else:
        flash(request, "Aktualizace spuštěna – průběh je níže.")
    return RedirectResponse("/system/update", status_code=303)


@app.post("/system/update/auto")
def update_auto(request: Request, auto_check: str = Form("")):
    with edit_config() as cfg:
        cfg.setdefault("update", {})["auto_check"] = bool(auto_check)
    flash(request, "Automatická kontrola zapnuta." if auto_check else "Automatická kontrola vypnuta.")
    return RedirectResponse("/system/update", status_code=303)


@app.post("/system/password")
def system_password(request: Request, pw1: str = Form(...), pw2: str = Form(...)):
    if pw1 != pw2 or len(pw1) < 12:
        flash(request, "Hesla se neshodují nebo mají méně než 12 znaků.", "err")
    else:
        with edit_config() as cfg:
            cfg["admin_password_hash"] = hash_pw(pw1)
        request.session.clear()
        request.session["auth"] = hashlib.sha256(cfg["admin_password_hash"].encode()).hexdigest()
        if frigate_set_admin_password(cfg, pw1):
            note = "" if storage_ready() else " (Frigate běží bez HDD; po připojení disku s dřívější databází může platit heslo z něj.)"
            flash(request, "Heslo změněno – platí pro Atmovio i Frigate (admin)." + note)
        else:
            flash(request, "Heslo Atmovio změněno, ale Frigate ho nepřevzal (neběží?). Nové mu vygeneruješ tlačítkem výše.", "err")
    return RedirectResponse("/system", status_code=303)


def on_startup():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    if not _logger.handlers:
        _logger.setLevel(logging.INFO)
        _logger.addHandler(RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=3, encoding="utf-8"))
    db_init()
    cfg = load_config()
    ai_stats_seed(int(cfg["ai"].get("threshold", 7) or 7))
    if storage_ready():
        Path(cfg["snapshot_dir"]).mkdir(parents=True, exist_ok=True)
    try:
        if frigate_fix_config(cfg):
            frigate_restart()
    except Exception as e:
        log(f"Frigate: oprava konfigurace při startu selhala: {e}")
    if not watcher.is_alive():
        watcher.start()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("ATMOVIO_PORT", "80")))
ATMOVIO_APP_EOF
cat > "$SKY_DIR/storage_guard.py" <<'ATMOVIO_STORAGE_EOF'
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
    if not entry or entry.split(' - ', 1)[1].split()[0] != 'ext4':
        return False
    if not MOUNT.is_mount() or MOUNT.stat().st_dev == Path('/').stat().st_dev:
        return False
    # Ověřit právě prostor záznamů, ne pouze jiný adresář na témže disku.
    directories = ('frigate', 'frigate/recordings', 'atmovio', 'atmovio/snapshots')
    if any((MOUNT / name).is_symlink() for name in directories):
        return False
    for name in directories:
        directory = MOUNT / name
        directory.mkdir(exist_ok=True)
        if directory.stat().st_dev != MOUNT.stat().st_dev:
            return False
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

    def sample(self):
        """None = měření běží; False = chyba/timeout; True = fsync prošel."""
        if self.process is None:
            self.process = subprocess.Popen([sys.executable, __file__, '--probe'],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.started = time.monotonic()
            return None
        rc = self.process.poll()
        if rc is not None:
            self.process = None
            return rc == 0
        if time.monotonic() - self.started > 4:
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


def publish(mode, reason):
    """Zapíše stav jen při změně nebo nejpozději po 10 s (Atmovio bere stav za čerstvý 15 s)."""
    now = time.time()
    if _last_publish['key'] == (mode, reason) and now - _last_publish['at'] < 10:
        return
    _last_publish.update(key=(mode, reason), at=now)
    atomic(STATUS, json.dumps({'mode': mode, 'reason': reason, 'checked_at': now, 'guard_pid': os.getpid()}, ensure_ascii=False))


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

    def reconcile(self, healthy, mount_id=None):
        if mount_id != self.mount_id:
            self.successes = 0
            self.mount_id = mount_id
        if healthy is True:
            self.successes += 1
        elif healthy is False:
            self.successes = 0
        # Návrat až po třech úspěšných zápisech; pád okamžitě.
        desired = 'recording' if self.successes >= 3 else 'live'
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
            publish(self.mode, 'HDD je zapisovatelný.' if self.mode == 'recording' else 'HDD chybí, neodpovídá nebo neprošel kontrolou zápisu. Živý náhled bez záznamu.')
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
            publish(desired, 'HDD je zapisovatelný.' if desired == 'recording' else 'Pouze živý náhled. Nahrávání a ukládání snímků jsou vypnuté.')
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
        except (OSError, ValueError):
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
                guard.reconcile(probe.sample(), mount_id)
            except Exception as exc:
                publish('error', str(exc))
            time.sleep(2)


if __name__ == '__main__':
    raise SystemExit(main())
ATMOVIO_STORAGE_EOF

cat > "$SKY_DIR/requirements.txt" <<'ATMOVIO_REQUIREMENTS_EOF'
# Přímé závislosti ověřené lokálními testy; Python 3.11+.
fastapi==0.141.1
uvicorn==0.52.4
jinja2==3.1.6
python-multipart==0.0.32
itsdangerous==2.2.0
requests==2.34.2
pillow==12.3.0
ruamel.yaml==0.18.17
astral==3.2
ATMOVIO_REQUIREMENTS_EOF

# --- statické soubory (CSS/JS) a knihovny Pico CSS + Alpine.js (offline kopie)
write_static() {  # $1 = cílový adresář
  mkdir -p "$1/vendor"
  cat > "$1/atmovio.css" <<'ATMOVIO_CSS_EOF'
/* Atmovio – vzhled administrace nad Pico CSS 2. Tmavý režim výchozí, světlý přes data-theme="light" (přepínač v hlavičce). */

:root {
  --pico-font-size: 94%;
  --pico-font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Inter, "Helvetica Neue", Arial, sans-serif;
  --pico-line-height: 1.5;
  --pico-spacing: .8rem;
  --pico-form-element-spacing-vertical: .55rem;
  --pico-form-element-spacing-horizontal: .8rem;
  --pico-border-radius: .65rem;
  --pico-block-spacing-vertical: 1rem;
  --pico-block-spacing-horizontal: 1.1rem;

  /* hlavička je tmavá v obou režimech */
  --at-head: #0b1220;
  --at-head-2: #101a30;
  --at-head-tx: #b6c2d6;
  --at-head-line: rgba(255, 255, 255, .08);
  --at-radius: 14px;
  --at-w: 1400px;

  /* barevné ikony dlaždic */
  --c-blue: #3b82f6;   --c-blue-bg: rgba(59, 130, 246, .16);
  --c-sky: #38bdf8;    --c-sky-bg: rgba(56, 189, 248, .16);
  --c-green: #22c55e;  --c-green-bg: rgba(34, 197, 94, .16);
  --c-amber: #f59e0b;  --c-amber-bg: rgba(245, 158, 11, .18);
  --c-red: #ef4444;    --c-red-bg: rgba(239, 68, 68, .16);
  --c-violet: #a78bfa; --c-violet-bg: rgba(167, 139, 250, .16);
  --c-teal: #2dd4bf;   --c-teal-bg: rgba(45, 212, 191, .16);
}

/* ---------- tmavý (výchozí) ---------- */
:root, :root[data-theme="dark"] {
  color-scheme: dark;
  --pico-background-color: #0b1220;
  --pico-card-background-color: #111a2e;
  --pico-card-border-color: #1f2b45;
  --pico-card-sectioning-background-color: #172239;
  --pico-primary: #38bdf8;
  --pico-primary-hover: #7dd3fc;
  --pico-primary-background: #0ea5e9;
  --pico-primary-hover-background: #38bdf8;
  --pico-primary-inverse: #04121c;
  --pico-primary-focus: rgba(56, 189, 248, .3);
  --pico-color: #e2e8f0;
  --pico-muted-color: #94a3b8;
  --pico-muted-border-color: #24304a;
  --pico-form-element-background-color: #0f172a;
  --pico-form-element-border-color: #2b3a58;
  --pico-form-element-color: #e2e8f0;
  --pico-form-element-placeholder-color: #64748b;
  --pico-form-element-active-border-color: #38bdf8;
  --pico-form-element-focus-color: rgba(56, 189, 248, .3);
  --at-surface: #111a2e; --at-surface-2: #172239; --at-line: #1f2b45; --at-text: #e2e8f0; --at-muted: #94a3b8;
  --sw-ok: #4ade80; --sw-ok-bg: #12352a;
  --sw-warn: #fbbf24; --sw-warn-bg: #3a2a0f;
  --sw-err: #f87171; --sw-err-bg: #3f1515;
  --sw-info: #7dd3fc; --sw-info-bg: #0c2a3d;
  --sw-muted: #94a3b8; --sw-text: #e2e8f0;
  --sw-shadow: 0 1px 2px rgba(0, 0, 0, .35), 0 10px 30px rgba(0, 0, 0, .25);
  --sw-img-bg: #0b1220;
  --at-hero: linear-gradient(120deg, #0f2a5a 0%, #12305f 35%, #0b1a3a 70%, #0b1220 100%);
}
/* ---------- světlý ---------- */
:root[data-theme="light"] {
  color-scheme: light;
  --pico-background-color: #f3f5f9;
  --pico-card-background-color: #ffffff;
  --pico-card-border-color: #e3e8ef;
  --pico-card-sectioning-background-color: #f1f5f9;
  --pico-primary: #0284c7;
  --pico-primary-hover: #0369a1;
  --pico-primary-background: #0284c7;
  --pico-primary-hover-background: #0369a1;
  --pico-primary-inverse: #ffffff;
  --pico-primary-focus: rgba(2, 132, 199, .25);
  --pico-color: #0f172a;
  --pico-muted-color: #64748b;
  --pico-muted-border-color: #e3e8ef;
  --pico-form-element-background-color: #ffffff;
  --pico-form-element-border-color: #cbd5e1;
  --pico-form-element-color: #0f172a;
  --pico-form-element-placeholder-color: #94a3b8;
  --pico-form-element-active-border-color: #0284c7;
  --pico-form-element-focus-color: rgba(2, 132, 199, .25);
  --at-surface: #ffffff; --at-surface-2: #f1f5f9; --at-line: #e3e8ef; --at-text: #0f172a; --at-muted: #64748b;
  --sw-ok: #15803d; --sw-ok-bg: #dcfce7;
  --sw-warn: #b45309; --sw-warn-bg: #fef3c7;
  --sw-err: #b91c1c; --sw-err-bg: #fee2e2;
  --sw-info: #0369a1; --sw-info-bg: #e0f2fe;
  --sw-muted: #64748b; --sw-text: #0f172a;
  --sw-shadow: 0 1px 2px rgba(15, 23, 42, .05), 0 8px 24px rgba(15, 23, 42, .06);
  --sw-img-bg: #0b1220;
  --at-hero: linear-gradient(120deg, #0b2a6f 0%, #1e63d6 55%, #38bdf8 100%);
  --c-blue: #2563eb;   --c-blue-bg: #dbeafe;
  --c-sky: #0284c7;    --c-sky-bg: #e0f2fe;
  --c-green: #16a34a;  --c-green-bg: #dcfce7;
  --c-amber: #d97706;  --c-amber-bg: #fef3c7;
  --c-red: #dc2626;    --c-red-bg: #fee2e2;
  --c-violet: #7c3aed; --c-violet-bg: #ede9fe;
  --c-teal: #0d9488;   --c-teal-bg: #ccfbf1;
}

/* ---------- základ ---------- */
html { -webkit-text-size-adjust: 100%; scroll-padding-top: 80px; }
body { margin: 0; background: var(--pico-background-color); color: var(--pico-color); }
[x-cloak] { display: none !important; }
h1 { font-size: 1.6rem; margin: 0 0 .15rem; font-weight: 800; letter-spacing: -.015em; }
h2 { font-size: 1.08rem; margin: 0 0 .75rem; font-weight: 750; }
h3 { font-size: .95rem; margin: 0 0 .5rem; font-weight: 700; }
p { margin: 0 0 .75rem; }
.sub { color: var(--pico-muted-color); margin: 0; font-size: .92rem; }
.hint { font-size: .85rem; color: var(--pico-muted-color); line-height: 1.45; }
.hint b { color: var(--pico-color); }
.mut { color: var(--pico-muted-color); }
code { font-size: .85em; }
a { color: var(--pico-primary); }
svg.i { width: 1.15em; height: 1.15em; flex: none; vertical-align: -.2em; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }

/* ---------- rozvržení ---------- */
.app { min-height: 100vh; display: flex; flex-direction: column; }
main.page { padding: 1.3rem 1.6rem 3rem; max-width: var(--at-w); width: 100%; margin: 0 auto; box-sizing: border-box; flex: 1; }
.page-head { display: flex; align-items: flex-end; justify-content: space-between; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.1rem; }
.page-head .actions { display: flex; gap: .5rem; flex-wrap: wrap; }
.page-head .actions .btn { margin: 0; }

/* ---------- hlavička s vodorovným menu ---------- */
header.top { position: sticky; top: 0; z-index: 50; background: var(--at-head); color: #fff; border-bottom: 1px solid var(--at-head-line); box-shadow: 0 6px 24px rgba(0, 0, 0, .25); }
header.top .inner { max-width: var(--at-w); margin: 0 auto; padding: 0 1.6rem; height: 64px; display: flex; align-items: center; gap: .6rem; }
.brand { display: flex; align-items: center; gap: .6rem; color: #fff; text-decoration: none; font-weight: 800; font-size: 1.25rem; letter-spacing: -.01em; flex: none; margin-right: .8rem; }
.brand:hover { text-decoration: none; color: #fff; }
.brand small { display: block; font-weight: 600; font-size: .62rem; color: var(--at-head-tx); letter-spacing: .12em; text-transform: uppercase; line-height: 1.1; }
.brand .logo { width: 38px; height: 38px; flex: none; }
nav.menu { display: flex; align-items: center; justify-content: flex-start; gap: .15rem; flex: 1; min-width: 0; margin: 0; padding: 0; }
nav.menu > a, nav.menu .dd > button { margin: 0; }
nav.menu > a, nav.menu .dd > button { display: inline-flex; align-items: center; gap: .35rem; color: var(--at-head-tx); text-decoration: none; padding: .5rem .8rem; border-radius: .6rem; font-weight: 600; font-size: .93rem; white-space: nowrap; background: none; border: 0; margin: 0; width: auto; cursor: pointer; line-height: 1.3; box-shadow: none; position: relative; }
nav.menu > a:hover, nav.menu .dd > button:hover, nav.menu .dd.open > button { color: #fff; background: rgba(255, 255, 255, .07); }
nav.menu > a.active, nav.menu .dd > button.active { color: #fff; background: rgba(56, 189, 248, .14); }
nav.menu > a.active::after, nav.menu .dd > button.active::after { content: ""; position: absolute; left: .8rem; right: .8rem; bottom: -.45rem; height: 3px; border-radius: 3px; background: var(--c-sky); }
nav.menu .dd { position: relative; }
nav.menu .dd .caret { font-size: .7rem; opacity: .7; transition: transform .15s; }
nav.menu .dd.open .caret { transform: rotate(180deg); }
.dd-panel { display: block; position: absolute; top: calc(100% + .55rem); left: 0; min-width: 260px; background: var(--pico-card-background-color); color: var(--pico-color); border: 1px solid var(--pico-card-border-color); border-radius: .9rem; box-shadow: 0 20px 50px rgba(0, 0, 0, .35); padding: .45rem; z-index: 60; }
.dd-panel.end { left: auto; right: 0; }
.dd-panel a, .dd-panel button.item { display: flex; align-items: center; gap: .6rem; padding: .55rem .7rem; border-radius: .6rem; color: var(--at-text); text-decoration: none; font-size: .92rem; font-weight: 500; background: none; border: 0; width: 100%; margin: 0; text-align: left; cursor: pointer; box-shadow: none; line-height: 1.3; }
.dd-panel a:hover, .dd-panel button.item:hover { background: var(--pico-card-sectioning-background-color); color: var(--at-text); text-decoration: none; }
.dd-panel a.active { background: var(--sw-info-bg); color: var(--sw-info); font-weight: 700; }
.dd-panel .ic { width: 22px; text-align: center; font-size: 1rem; flex: none; }
.dd-panel .label { font-size: .68rem; text-transform: uppercase; letter-spacing: .08em; color: var(--pico-muted-color); padding: .5rem .7rem .2rem; font-weight: 700; }
.dd-panel hr { margin: .35rem 0; border: 0; border-top: 1px solid var(--pico-card-border-color); }
.dd-panel .ver { padding: .3rem .7rem .2rem; font-size: .75rem; color: var(--pico-muted-color); }
header.top .right { display: flex; align-items: center; gap: .45rem; flex: none; margin-left: auto; }
header.top .right .btn { margin: 0; }
header.top .right .btn.ghost { background: rgba(255, 255, 255, .06); color: #fff; border-color: rgba(255, 255, 255, .14); }
header.top .right .btn.ghost:hover { background: rgba(255, 255, 255, .12); border-color: rgba(255, 255, 255, .3); color: #fff; }
.ico-btn, button.ico-btn:not(.block) { flex: none; width: 40px; height: 40px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; background: rgba(255, 255, 255, .07); border: 1px solid rgba(255, 255, 255, .1); color: #fff; cursor: pointer; padding: 0; margin: 0; box-shadow: none; position: relative; }
.ico-btn:hover { background: rgba(255, 255, 255, .14); color: #fff; }
.ico-btn svg { width: 19px; height: 19px; }
.ico-btn .n { position: absolute; top: 5px; right: 6px; width: 9px; height: 9px; border-radius: 50%; background: var(--c-red); border: 2px solid var(--at-head); }
.ico-btn.user { background: var(--pico-primary-background); color: var(--pico-primary-inverse); font-weight: 800; font-size: .85rem; border-color: transparent; }
button.menu-btn:not(.block) { display: none; }
/* stavové tečky v hlavičce */
.head-status { display: flex; gap: .35rem; margin-right: .4rem; }
.head-status a { display: inline-flex; align-items: center; gap: .35rem; color: var(--at-head-tx); text-decoration: none; font-size: .78rem; font-weight: 600; padding: .28rem .6rem; border-radius: 999px; background: rgba(255, 255, 255, .05); border: 1px solid rgba(255, 255, 255, .08); white-space: nowrap; }
.head-status a:hover { color: #fff; }
.dot { width: 9px; height: 9px; border-radius: 50%; flex: none; display: inline-block; }
.dot.ok { background: var(--sw-ok); box-shadow: 0 0 0 3px rgba(74, 222, 128, .18); }
.dot.warn { background: var(--sw-warn); box-shadow: 0 0 0 3px rgba(251, 191, 36, .18); }
.dot.err { background: var(--sw-err); box-shadow: 0 0 0 3px rgba(248, 113, 113, .18); }
.dot.mut { background: var(--sw-muted); }

/* ---------- hero pruh přehledu ---------- */
.hero { position: relative; overflow: hidden; border-radius: var(--at-radius); background: var(--at-hero); color: #fff; padding: 1.4rem 1.6rem; margin-bottom: 1rem; display: flex; align-items: center; gap: 1.2rem; flex-wrap: wrap; box-shadow: var(--sw-shadow); min-height: 118px; }
.hero::before { content: ""; position: absolute; inset: 0; background: radial-gradient(700px 200px at 80% 120%, rgba(251, 191, 36, .35), transparent 60%), radial-gradient(500px 220px at 15% -40%, rgba(125, 211, 252, .35), transparent 60%); pointer-events: none; }
.hero > * { position: relative; }
.hero h1 { color: #fff; font-size: 1.9rem; margin: 0; }
.hero .sub { color: rgba(255, 255, 255, .78); font-size: .95rem; }
.hero .tag { font-family: "Segoe Script", "Bradley Hand", "Comic Sans MS", cursive; color: #bfe4ff; font-size: 1rem; margin-top: .35rem; opacity: .9; }
.hero .grow { flex: 1; min-width: 220px; }
.hero .pill { background: rgba(2, 6, 23, .45); border: 1px solid rgba(255, 255, 255, .12); border-radius: 12px; padding: .6rem .9rem; display: flex; align-items: center; gap: .7rem; backdrop-filter: blur(6px); }
.hero .pill .big { font-size: 1.25rem; line-height: 1.1; }
.hero .pill .k { font-size: .72rem; color: rgba(255, 255, 255, .7); text-transform: uppercase; letter-spacing: .06em; }
.hero .sun { display: grid; grid-template-columns: repeat(4, auto); gap: .2rem .9rem; font-size: .82rem; }
.hero .sun span { display: flex; flex-direction: column; align-items: center; color: #fff; font-weight: 700; }
.hero .sun small { color: rgba(255, 255, 255, .65); font-weight: 500; font-size: .68rem; text-transform: uppercase; letter-spacing: .05em; }

/* ---------- KPI dlaždice s barevnou ikonou ---------- */
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: .8rem; margin-bottom: 1rem; }
.tile { display: flex; align-items: center; gap: .9rem; text-decoration: none; color: inherit; background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); border-radius: var(--at-radius); padding: .95rem 1rem; box-shadow: var(--sw-shadow); position: relative; min-width: 0; }
.tile:hover { text-decoration: none; color: inherit; border-color: var(--pico-primary); }
.tile .ico { width: 52px; height: 52px; border-radius: 50%; display: grid; place-items: center; flex: none; font-size: 1.4rem; background: var(--c-sky-bg); color: var(--c-sky); }
.tile .ico svg { width: 26px; height: 26px; }
.tile .ico.blue { background: var(--c-blue-bg); color: var(--c-blue); } .tile .ico.green { background: var(--c-green-bg); color: var(--c-green); }
.tile .ico.amber { background: var(--c-amber-bg); color: var(--c-amber); } .tile .ico.red { background: var(--c-red-bg); color: var(--c-red); }
.tile .ico.violet { background: var(--c-violet-bg); color: var(--c-violet); } .tile .ico.teal { background: var(--c-teal-bg); color: var(--c-teal); }
.tile .tx { flex: 1; min-width: 0; }
.tile .k { font-size: .8rem; color: var(--pico-muted-color); font-weight: 600; }
.tile .v { font-size: 1.45rem; font-weight: 800; margin: .05rem 0 0; letter-spacing: -.01em; line-height: 1.15; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tile .d { font-size: .8rem; color: var(--pico-muted-color); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tile .bar { margin-top: .45rem; height: 5px; }
.tile .arrow { color: var(--pico-muted-color); font-size: 1.2rem; flex: none; }
.tile.err .v { color: var(--sw-err); } .tile.warn .v { color: var(--sw-warn); } .tile.ok .v { color: inherit; }
.tile.err { border-color: rgba(239, 68, 68, .45); } .tile.warn { border-color: rgba(245, 158, 11, .45); }

/* ---------- karty ---------- */
.card { background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); border-radius: var(--at-radius); padding: 1.1rem 1.2rem; margin-bottom: 1rem; box-shadow: var(--sw-shadow); min-width: 0; }
.card.tight { padding: .8rem .95rem; }
.card.accent { border-color: var(--pico-primary); }
.card.warn { border-color: var(--sw-warn); }
.section-head { display: flex; justify-content: space-between; align-items: center; gap: .75rem; flex-wrap: wrap; margin-bottom: .7rem; }
.section-head h2 { margin: 0; display: flex; align-items: center; gap: .5rem; }
.section-head .btn { margin: 0; }
.section-head .count { color: var(--pico-muted-color); font-weight: 500; font-size: .95rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; }
.grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 1rem; }
.grid-4 { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1rem; }
.grid-3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1rem; }
.grid-wide { display: grid; grid-template-columns: repeat(auto-fit, minmax(480px, 1fr)); gap: 1.2rem; }
@media (max-width: 1250px) { .grid-4 { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 1000px) { .grid-3 { grid-template-columns: 1fr; } }
@media (max-width: 640px) { .grid-4, .grid-wide { grid-template-columns: 1fr; } }
.grid > .card, .grid-2 > .card, .grid-3 > .card, .grid-4 > .card { margin: 0; }
.row { display: flex; gap: .9rem; flex-wrap: wrap; }
.row > * { flex: 1; min-width: 160px; }
.row > .btn, .row > button, .row > form { flex: 0 0 auto; min-width: 0; }

/* ---------- odznaky, stavy ---------- */
.badge { display: inline-flex; align-items: center; gap: .3rem; padding: .1rem .6rem; border-radius: 999px; font-size: .75rem; font-weight: 700; white-space: nowrap; line-height: 1.5; vertical-align: middle; }
.badge.ok { background: var(--sw-ok-bg); color: var(--sw-ok); }
.badge.warn { background: var(--sw-warn-bg); color: var(--sw-warn); }
.badge.err { background: var(--sw-err-bg); color: var(--sw-err); }
.badge.info { background: var(--sw-info-bg); color: var(--sw-info); }
.badge.mut { background: var(--pico-muted-border-color); color: var(--pico-muted-color); }
a.badge { text-decoration: none; cursor: pointer; }
a.badge:hover { filter: brightness(1.1); text-decoration: underline; }

/* ---------- tlačítka ---------- */
.btn, a.btn { display: inline-flex; align-items: center; justify-content: center; gap: .4rem; background: var(--pico-primary-background); color: var(--pico-primary-inverse); border: 1px solid var(--pico-primary-background); padding: .55rem 1rem; border-radius: .65rem; font: inherit; font-weight: 700; font-size: .92rem; cursor: pointer; text-decoration: none; margin: .4rem .5rem 0 0; width: auto; line-height: 1.3; box-shadow: none; white-space: nowrap; }
.btn:hover, a.btn:hover { background: var(--pico-primary-hover-background); border-color: var(--pico-primary-hover-background); color: var(--pico-primary-inverse); text-decoration: none; }
.btn.sec { background: var(--pico-card-background-color); color: var(--sw-text); border-color: var(--pico-muted-border-color); }
.btn.sec:hover { border-color: var(--pico-primary); color: var(--pico-primary); background: var(--pico-card-background-color); }
.btn.danger { background: var(--sw-err-bg); color: var(--sw-err); border-color: var(--sw-err); }
.btn.danger:hover { background: var(--sw-err); color: #fff; }
.btn.small { padding: .32rem .7rem; font-size: .82rem; margin: .25rem .4rem 0 0; }
.btn.block { width: 100%; }
button[disabled], .btn[disabled] { opacity: .6; cursor: wait; }
form { margin: 0; }
button:not(.block) { width: auto; }
button:not(.btn) { margin-bottom: 0; }
[role="group"] .btn { margin: 0; }

/* ---------- formuláře ---------- */
label { display: block; font-size: .82rem; color: var(--pico-muted-color); margin: .7rem 0 .3rem; font-weight: 650; }
input:not([type="checkbox"]):not([type="radio"]), select, textarea { margin-bottom: 0; border-radius: .6rem; }
textarea { min-height: 110px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85rem; }
.check { display: flex; align-items: center; gap: .65rem; margin: .6rem 0; font-size: .95rem; color: var(--pico-color); font-weight: 500; cursor: pointer; }
.check input[type="checkbox"] { appearance: none; -webkit-appearance: none; width: 42px; height: 24px; border-radius: 999px; background: var(--pico-muted-border-color); position: relative; flex: none; transition: .15s; margin: 0; cursor: pointer; border: 0; }
.check input[type="checkbox"]::after { content: ""; position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; transition: .15s; box-shadow: 0 1px 2px rgba(0, 0, 0, .3); }
.check input[type="checkbox"]:checked { background: var(--pico-primary-background); }
.check input[type="checkbox"]:checked::after { left: 21px; }
.check input[type="checkbox"]:focus-visible { outline: 2px solid var(--pico-primary-focus); }
.chips { display: flex; flex-wrap: wrap; gap: .45rem; margin: .3rem 0; }
.chip { display: inline-flex; align-items: center; gap: .4rem; padding: .4rem .75rem; border-radius: 999px; border: 1px solid var(--pico-muted-border-color); background: var(--pico-card-background-color); cursor: pointer; font-size: .88rem; user-select: none; margin: 0; color: var(--pico-color); font-weight: 500; }
.chip input { width: 15px; height: 15px; margin: 0; accent-color: var(--pico-primary); }
.chip:has(input:checked) { background: var(--sw-info-bg); border-color: var(--pico-primary); }
/* segmentový přepínač (Vše / Živé / Offline) */
.seg { display: inline-flex; gap: .2rem; padding: .2rem; border-radius: 999px; background: var(--pico-card-sectioning-background-color); border: 1px solid var(--pico-card-border-color); }
.seg a, .seg span, .seg label { padding: .28rem .75rem; border-radius: 999px; font-size: .82rem; font-weight: 600; color: var(--pico-muted-color); text-decoration: none; display: inline-flex; gap: .35rem; align-items: center; }
.seg .on { background: var(--pico-primary-background); color: var(--pico-primary-inverse); }
.seg b { font-weight: 800; }

/* ---------- tabulky ---------- */
.tw { overflow-x: auto; -webkit-overflow-scrolling: touch; }
table { width: 100%; font-size: .9rem; margin: 0; }
th, td { padding: .55rem .5rem; vertical-align: top; border-bottom: 1px solid var(--pico-card-border-color); }
th { color: var(--pico-muted-color); font-weight: 650; font-size: .74rem; text-transform: uppercase; letter-spacing: .05em; }
tbody tr:last-child td { border-bottom: 0; }
.stats7 { overflow-x: auto; }
.stats7 table { font-size: .88rem; }
.stats7 td, .stats7 th { text-align: right; white-space: nowrap; padding: .4rem .5rem; }
.stats7 td:first-child, .stats7 th:first-child { text-align: left; }
.stats7 tr.today td { background: var(--sw-info-bg); }
.stats7 tr.today td:first-child { font-weight: 750; }
.stats7 tr.sum td { border-top: 2px solid var(--pico-muted-border-color); font-weight: 650; }
.kv td:first-child { color: var(--pico-muted-color); width: 40%; }
.cams.big { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; }
.cams.big .cam .img { aspect-ratio: 16 / 9; }
.cams.big .cam .name { font-size: 1.05rem; }
@media (max-width: 760px) { .cams.big { grid-template-columns: 1fr; } }
.live-big { background: #000; aspect-ratio: 16 / 9; display: flex; align-items: center; justify-content: center; color: #94a3b8; border-radius: 12px; overflow: hidden; }
.live-big img { width: 100%; height: 100%; object-fit: contain; display: block; }

/* ---------- hlášky, toasty ---------- */
.flash { padding: .75rem 1rem; border-radius: .8rem; margin-bottom: .9rem; background: var(--sw-ok-bg); color: var(--sw-ok); font-weight: 600; white-space: pre-line; display: flex; gap: .6rem; align-items: flex-start; border: 1px solid transparent; }
.flash.err { background: var(--sw-err-bg); color: var(--sw-err); }
.flash.warn { background: var(--sw-warn-bg); color: var(--sw-warn); }
.flash a { color: inherit; text-decoration: underline; }
.flash .x { margin-left: auto; background: none; border: 0; color: inherit; font-size: 1.1rem; line-height: 1; padding: 0 .2rem; cursor: pointer; opacity: .7; width: auto; }
.toasts { position: fixed; right: 1rem; top: 76px; z-index: 900; display: flex; flex-direction: column; gap: .5rem; max-width: min(460px, calc(100vw - 2rem)); }
.toast { background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); border-left: 4px solid var(--sw-ok); border-radius: .7rem; padding: .7rem .9rem; box-shadow: var(--sw-shadow); font-size: .9rem; display: flex; gap: .6rem; align-items: flex-start; white-space: pre-line; }
.toast.err { border-left-color: var(--sw-err); } .toast.warn { border-left-color: var(--sw-warn); }
.toast .x { margin-left: auto; background: none; border: 0; color: var(--pico-muted-color); font-size: 1.1rem; line-height: 1; padding: 0 .2rem; cursor: pointer; width: auto; }

/* ---------- busy overlay ---------- */
#busy { position: fixed; inset: 0; background: rgba(2, 6, 23, .5); z-index: 1000; display: flex; align-items: center; justify-content: center; padding: 20px; }
#busy[hidden] { display: none; }
.busy-box { background: var(--pico-card-background-color); color: var(--pico-color); border-radius: .9rem; padding: 1rem 1.3rem; box-shadow: var(--sw-shadow); display: flex; gap: .9rem; align-items: center; max-width: 440px; }
.spin { width: 26px; height: 26px; border: 3px solid var(--pico-muted-border-color); border-top-color: var(--pico-primary); border-radius: 50%; animation: spin .9s linear infinite; flex: none; }
@keyframes spin { to { transform: rotate(360deg); } }

/* ---------- lightbox ---------- */
.lightbox { position: fixed; inset: 0; z-index: 1100; background: rgba(2, 6, 23, .9); display: flex; align-items: center; justify-content: center; padding: 1.5rem; cursor: zoom-out; }
.lightbox figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: .5rem; max-width: 100%; max-height: 100%; cursor: default; }
.lightbox img { max-width: min(96vw, 1700px); max-height: 84vh; border-radius: .6rem; box-shadow: 0 20px 60px rgba(0, 0, 0, .6); }
.lightbox figcaption { color: #e2e8f0; font-size: .95rem; text-align: center; }
.lightbox .close { position: fixed; top: .75rem; right: 1rem; width: 44px; height: 44px; border: 0; border-radius: 50%; background: rgba(255, 255, 255, .14); color: #fff; font-size: 1.7rem; line-height: 1; cursor: pointer; padding: 0; margin: 0; }
.lightbox .close:hover { background: rgba(255, 255, 255, .28); }
.lightbox .nav-btn { position: fixed; top: 50%; transform: translateY(-50%); width: 46px; height: 46px; border-radius: 50%; border: 0; background: rgba(255, 255, 255, .14); color: #fff; font-size: 1.5rem; cursor: pointer; padding: 0; margin: 0; }
.lightbox .nav-btn.prev { left: 1rem; } .lightbox .nav-btn.next { right: 1rem; }
.lightbox .nav-btn:hover { background: rgba(255, 255, 255, .28); }
body.lb-open { overflow: hidden; }
.lightbox.player video { width: min(96vw, 1400px); max-height: 84vh; border-radius: .6rem; background: #000; box-shadow: 0 20px 60px rgba(0, 0, 0, .6); }
.lightbox.player .speeds { display: flex; align-items: center; gap: .3rem; flex-wrap: wrap; justify-content: center; }
.lightbox.player .speeds .lbl { color: #94a3b8; font-size: .8rem; margin-right: .2rem; }
.lightbox.player .speeds button { margin: 0; width: auto; padding: .2rem .6rem; border-radius: 999px; border: 1px solid rgba(255, 255, 255, .25); background: rgba(255, 255, 255, .1); color: #fff; font-size: .8rem; font-weight: 700; line-height: 1.5; cursor: pointer; }
.lightbox.player .speeds button:hover { background: rgba(255, 255, 255, .22); }
.lightbox.player .speeds button.on { background: var(--pico-primary); border-color: var(--pico-primary); }
.lightbox.player .speeds .pos { color: #e2e8f0; font-size: .85rem; font-variant-numeric: tabular-nums; margin-left: .4rem; }
.gallery.videos { grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; }
.shot .line { display: flex; align-items: center; gap: .45rem; flex-wrap: wrap; }
.shot.video .thumb { position: relative; display: block; aspect-ratio: 16 / 9; background: var(--sw-img-bg); overflow: hidden; }
.shot.video .thumb img { aspect-ratio: auto; width: 100%; height: 100%; object-fit: cover; }
.shot.video .thumb .play { position: absolute; inset: 0; margin: auto; width: 58px; height: 58px; border-radius: 50%; background: rgba(2, 6, 23, .6); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 1.5rem; padding-left: .25rem; transition: transform .15s, background .15s; }
.shot.video .thumb:hover .play { transform: scale(1.08); background: var(--pico-primary); }
.shot.video .thumb .dur { position: absolute; right: .5rem; bottom: .5rem; background: rgba(2, 6, 23, .7); color: #fff; font-size: .75rem; font-weight: 700; padding: .1rem .45rem; border-radius: .35rem; }
.shot.video .thumb.wait { display: grid; place-items: center; color: #94a3b8; font-size: .9rem; }
.shot.video .title { font-weight: 750; font-size: 1rem; line-height: 1.3; margin-bottom: .35rem; }
.facts { display: grid; grid-template-columns: max-content 1fr; gap: .15rem .7rem; margin: 0 0 .5rem; font-size: .85rem; }
.facts dt { color: var(--pico-muted-color); font-weight: 600; margin: 0; }
.facts dd { margin: 0; }
.shot .acts { display: flex; gap: .4rem; flex-wrap: wrap; align-items: center; margin-top: auto; }
.shot .acts .btn.small { margin: 0; align-self: auto; }
.shot .acts form { margin: 0; }
a[data-lightbox] { cursor: zoom-in; }

/* ---------- kamery ---------- */
.cams { display: grid; grid-template-columns: repeat(auto-fill, minmax(255px, 1fr)); gap: .9rem; }
.cam { background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); border-radius: var(--at-radius); overflow: hidden; box-shadow: var(--sw-shadow); display: flex; flex-direction: column; }
.cam .img { aspect-ratio: 16 / 9; background: var(--sw-img-bg) linear-gradient(135deg, #0b1220, #1e293b); display: flex; align-items: center; justify-content: center; color: #64748b; font-size: .85rem; position: relative; text-decoration: none; }
.cam .img img { width: 100%; height: 100%; object-fit: cover; display: block; }
.cam .img .live { position: absolute; left: .55rem; top: .55rem; background: rgba(2, 6, 23, .7); color: #fff; font-size: .68rem; font-weight: 800; letter-spacing: .04em; padding: .18rem .5rem; border-radius: .4rem; display: inline-flex; align-items: center; gap: .35rem; }
.cam .img .live .dot { width: 7px; height: 7px; box-shadow: none; }
.cam .img .fps { position: absolute; right: .55rem; top: .55rem; background: rgba(2, 6, 23, .7); color: #4ade80; font-size: .7rem; font-weight: 800; padding: .18rem .5rem; border-radius: .4rem; }
.cam .body { padding: .7rem .85rem .8rem; display: flex; flex-direction: column; gap: .3rem; flex: 1; }
.cam .name { font-weight: 750; font-size: .98rem; display: flex; justify-content: space-between; align-items: center; gap: .5rem; }
.cam .meta { font-size: .8rem; color: var(--pico-muted-color); display: flex; gap: .4rem; flex-wrap: wrap; align-items: center; }
.cam .acts { display: grid; grid-template-columns: 1fr 1fr; gap: .45rem; margin-top: auto; padding-top: .45rem; }
.cam .acts .btn { margin: 0; padding: .4rem .5rem; font-size: .82rem; }
.cam.add { border-style: dashed; border-width: 2px; align-items: center; justify-content: center; text-align: center; text-decoration: none; color: var(--pico-muted-color); padding: 1.2rem; min-height: 200px; box-shadow: none; background: transparent; }
.cam.add:hover { border-color: var(--pico-primary); color: var(--pico-primary); text-decoration: none; }
.cam.add .plus { width: 46px; height: 46px; border-radius: 50%; border: 2px solid currentColor; display: grid; place-items: center; font-size: 1.5rem; margin-bottom: .6rem; }
.cam.add b { color: var(--pico-color); font-size: 1rem; }

/* ---------- galerie ---------- */
.gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: .8rem; }
.shot { background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); border-radius: .9rem; overflow: hidden; display: flex; flex-direction: column; }
.shot img { width: 100%; aspect-ratio: 16 / 9; object-fit: cover; display: block; background: var(--sw-img-bg); }
.shot .b { padding: .55rem .7rem .7rem; font-size: .85rem; display: flex; flex-direction: column; gap: .2rem; }
.shot .s { font-weight: 800; font-size: .95rem; color: var(--pico-primary); }
.shot .when { font-weight: 700; }
.shot .btn.small { align-self: flex-start; margin-top: .3rem; }

/* ---------- seznam událostí s náhledem ---------- */
.feed { list-style: none; margin: 0; padding: 0; }
.feed li { display: flex; align-items: center; gap: .7rem; padding: .5rem 0; border-bottom: 1px solid var(--pico-card-border-color); }
.feed li:last-child { border: 0; }
.feed .th { width: 64px; height: 40px; border-radius: 6px; object-fit: cover; background: var(--sw-img-bg); flex: none; display: grid; place-items: center; font-size: 1.1rem; }
.feed .tx { flex: 1; min-width: 0; }
.feed .tx b { display: block; font-size: .9rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.feed .tx small { color: var(--pico-muted-color); font-size: .78rem; }
.feed .t { color: var(--pico-muted-color); font-size: .78rem; white-space: nowrap; }
.feed a { text-decoration: none; color: inherit; }

/* ---------- ostatní prvky ---------- */
.big { font-size: 1.8rem; font-weight: 800; letter-spacing: -.01em; }
.bar { height: 8px; background: var(--pico-muted-border-color); border-radius: 4px; overflow: hidden; margin-top: .5rem; }
.bar i { display: block; height: 100%; background: var(--pico-primary-background); border-radius: 4px; }
.bar i.warn { background: var(--sw-warn); } .bar i.err { background: var(--sw-err); } .bar i.ok { background: var(--sw-ok); }
.steps { counter-reset: s; margin: 0; padding: 0; list-style: none; }
.steps li { position: relative; padding: .4rem 0 .4rem 2.4rem; counter-increment: s; }
.steps li::before { content: counter(s); position: absolute; left: 0; top: .35rem; width: 26px; height: 26px; border-radius: 50%; background: var(--pico-primary-background); color: var(--pico-primary-inverse); font-weight: 800; display: flex; align-items: center; justify-content: center; font-size: .82rem; }
details { border: 1px solid var(--pico-card-border-color); border-radius: .8rem; padding: 0 .9rem; margin: .75rem 0; background: var(--pico-card-background-color); }
details summary { cursor: pointer; padding: .7rem 0; font-weight: 650; color: var(--pico-muted-color); margin: 0; }
details[open] summary { border-bottom: 1px solid var(--pico-card-border-color); margin-bottom: .5rem; }
details.card summary { padding: .85rem 0; }
details summary::after { display: none; }
.events { list-style: none; margin: 0; padding: 0; }
.events li { padding: .45rem 0; border-bottom: 1px solid var(--pico-card-border-color); font-size: .9rem; display: flex; gap: .6rem; align-items: flex-start; }
.events li:last-child { border: 0; }
.events .t { color: var(--pico-muted-color); font-size: .78rem; white-space: nowrap; min-width: 92px; padding-top: .1rem; }
.tabs { display: flex; flex-wrap: wrap; gap: .35rem; }
.tab { padding: .4rem .8rem; border-radius: .6rem; border: 1px solid var(--pico-muted-border-color); text-decoration: none; color: var(--pico-color); font-size: .9rem; background: var(--pico-card-background-color); }
.tab.active { background: var(--pico-primary-background); color: var(--pico-primary-inverse); border-color: var(--pico-primary-background); }
pre { background: var(--pico-card-sectioning-background-color, var(--pico-background-color)); border: 1px solid var(--pico-card-border-color); padding: .75rem; border-radius: .6rem; overflow: auto; font-size: .8rem; white-space: pre-wrap; word-break: break-word; max-height: 360px; margin: 0 0 .75rem; }
.logbox { max-height: 70vh; font-size: .8rem; line-height: 1.45; }
.guide { display: grid; gap: .5rem; padding: .3rem 0 .9rem; font-size: .9rem; line-height: 1.5; }
.guide > div { padding-left: .8rem; border-left: 3px solid var(--sw-info-bg); }

/* ---------- dashboard – mini statistiky ---------- */
.kpi { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: .7rem; }
.kpi .item { padding: .65rem .8rem; border-radius: .8rem; background: var(--pico-card-sectioning-background-color, var(--pico-background-color)); border: 1px solid var(--pico-card-border-color); min-width: 0; }
.kpi .item.ic { display: flex; gap: .6rem; align-items: center; }
.kpi .item > .ico { width: 36px; height: 36px; border-radius: 50%; display: grid; place-items: center; flex: none; background: var(--c-sky-bg); color: var(--c-sky); }
.kpi .item > .ico svg { width: 18px; height: 18px; }
.kpi .item > .ico.blue { background: var(--c-blue-bg); color: var(--c-blue); } .kpi .item > .ico.green { background: var(--c-green-bg); color: var(--c-green); }
.kpi .item > .ico.amber { background: var(--c-amber-bg); color: var(--c-amber); } .kpi .item > .ico.red { background: var(--c-red-bg); color: var(--c-red); }
.kpi .item > .ico.violet { background: var(--c-violet-bg); color: var(--c-violet); } .kpi .item > .ico.teal { background: var(--c-teal-bg); color: var(--c-teal); }
.kpi .item.ic > div { min-width: 0; }
.kpi .k { font-size: .72rem; color: var(--pico-muted-color); text-transform: uppercase; letter-spacing: .06em; }
.kpi .v { font-size: 1.12rem; font-weight: 800; }
.kpi .d { font-size: .78rem; color: var(--pico-muted-color); }
.ring { --p: 0; --ring-c: var(--pico-primary-background); width: 96px; height: 96px; border-radius: 50%; background: conic-gradient(var(--ring-c) calc(var(--p) * 1%), var(--pico-muted-border-color) 0); display: grid; place-items: center; flex: none; }
.ring > span { width: 74px; height: 74px; border-radius: 50%; background: var(--pico-card-background-color); display: grid; place-items: center; font-weight: 800; font-size: 1.05rem; }
.ring.small { width: 64px; height: 64px; } .ring.small > span { width: 50px; height: 50px; font-size: .85rem; }
.ring.warn { --ring-c: var(--sw-warn); } .ring.err { --ring-c: var(--sw-err); }
.ai-today { display: flex; gap: 1rem; align-items: center; }
.legend { list-style: none; margin: 0; padding: 0; font-size: .86rem; }
.legend li { display: flex; align-items: center; gap: .5rem; padding: .22rem 0; }
.legend li b { margin-left: auto; font-weight: 700; }
.legend .sw { width: 10px; height: 10px; border-radius: 50%; flex: none; background: var(--c-sky); }
.sunline { display: flex; gap: 1rem; align-items: center; font-size: .85rem; color: var(--pico-muted-color); flex-wrap: wrap; }
.brand-foot { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; font-size: .8rem; color: var(--pico-muted-color); padding: 1rem 1.6rem; max-width: var(--at-w); margin: 0 auto; width: 100%; box-sizing: border-box; border-top: 1px solid var(--pico-card-border-color); }
.brand-foot a { color: var(--pico-muted-color); text-decoration: none; margin-right: .9rem; }
.brand-foot a:hover { color: var(--pico-primary); }
.brand-foot .tag { font-family: "Segoe Script", "Bradley Hand", "Comic Sans MS", cursive; color: var(--pico-primary); }

/* ---------- mobil ---------- */
.scrim { display: none; }
@media (max-width: 1500px) { .head-status { display: none; } }
header.top .right .dd { flex: none; }
@media (max-width: 1080px) {
  header.top .inner { padding: 0 .9rem; height: 58px; }
  .brand { font-size: 1.1rem; margin-right: .2rem; }
  .brand .logo { width: 32px; height: 32px; }
  .brand small { display: none; }
  .head-status { display: none; }
  button.menu-btn:not(.block) { display: inline-flex; }
  nav.menu { position: fixed; top: 58px; left: 0; right: 0; bottom: 0; background: var(--pico-card-background-color); color: var(--pico-color); flex-direction: column; align-items: stretch; gap: 0; padding: .6rem .8rem 2rem; overflow-y: auto; z-index: 55; transform: translateY(-8px); opacity: 0; pointer-events: none; transition: .15s; border-top: 1px solid var(--pico-card-border-color); }
  nav.menu.open { transform: none; opacity: 1; pointer-events: auto; }
  nav.menu > a, nav.menu .dd > button { color: var(--at-text); padding: .7rem .8rem; font-size: 1rem; width: 100%; justify-content: flex-start; }
  nav.menu > a.active, nav.menu .dd > button.active { background: var(--sw-info-bg); color: var(--sw-info); }
  nav.menu > a.active::after, nav.menu .dd > button.active::after { display: none; }
  nav.menu > a:hover, nav.menu .dd > button:hover, nav.menu .dd.open > button { background: var(--pico-card-sectioning-background-color); color: var(--at-text); }
  nav.menu .dd { width: 100%; }
  .dd-panel { position: static; box-shadow: none; border: 0; padding: 0 0 .3rem .8rem; min-width: 0; }
  .dd-panel.end { padding-left: 0; }
  header.top .right .btn span { display: none; }
  header.top .right .btn { padding: .45rem .6rem; }
  header.top .right { gap: .35rem; }
  main.page { padding: .9rem .9rem 3rem; }
  h1 { font-size: 1.3rem; }
  .card { padding: .9rem; }
  .hero { padding: 1.1rem 1.1rem; }
  .hero h1 { font-size: 1.5rem; }
  .hero .sun { grid-template-columns: repeat(4, 1fr); }
  .row > * { min-width: 100%; }
  .tiles { grid-template-columns: repeat(2, 1fr); gap: .6rem; }
  .tile { padding: .7rem .75rem; gap: .6rem; }
  .tile .ico { width: 42px; height: 42px; } .tile .ico svg { width: 22px; height: 22px; }
  .tile .v { font-size: 1.15rem; }
  .tile .arrow { display: none; }
  .kpi { grid-template-columns: repeat(2, 1fr); }
  .toasts { left: .75rem; right: .75rem; top: auto; bottom: 1rem; max-width: none; }
  th, td { padding: .45rem .4rem; font-size: .85rem; }
  .brand-foot { padding: 1rem .9rem; }
}
@media (max-width: 480px) { .tiles { grid-template-columns: 1fr; } header.top .right .btn.ghost { display: none; } }

/* ---------- AI: výběr poskytovatele ---------- */
.prov { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: .7rem; margin: .4rem 0 .6rem; }
.prov-card { display: block; margin: 0; padding: .8rem .9rem; border: 2px solid var(--pico-card-border-color); border-radius: 12px; background: var(--pico-card-sectioning-background-color); cursor: pointer; font-size: .82rem; color: var(--pico-muted-color); font-weight: 500; position: relative; }
.prov-card:hover { border-color: var(--pico-primary); }
.prov-card.on { border-color: var(--pico-primary); background: var(--sw-info-bg); color: var(--pico-color); }
.prov-card input { position: absolute; opacity: 0; width: 0; height: 0; }
.prov-card .ph { display: flex; justify-content: space-between; align-items: center; gap: .5rem; margin-bottom: .45rem; }
.prov-card .ph b { color: var(--pico-color); font-size: .98rem; }
.prov-card .pr { display: flex; gap: .45rem; align-items: flex-start; margin: .2rem 0; line-height: 1.35; }
.prov-card .pr span:first-child { flex: none; }

/* ---------- Přehled: co AI naposledy viděla ---------- */
.ai-last { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: .9rem; }
.ai-ev { display: flex; gap: .9rem; margin: 0; padding: .7rem; border: 1px solid var(--pico-card-border-color); border-radius: 12px; background: var(--pico-card-sectioning-background-color); }
.ai-ev.hit { border-color: rgba(34, 197, 94, .45); }
.ai-ev .pic { position: relative; flex: none; width: 200px; border-radius: 9px; overflow: hidden; background: var(--sw-img-bg); }
.ai-ev .pic img { width: 100%; aspect-ratio: 16 / 9; object-fit: cover; display: block; }
.ai-ev .sc { position: absolute; left: .45rem; bottom: .45rem; padding: .1rem .5rem; border-radius: .4rem; font-weight: 800; font-size: .8rem; background: rgba(2, 6, 23, .75); color: #fff; }
.ai-ev .sc.ok { color: #4ade80; } .ai-ev .sc.mut { color: #cbd5e1; }
.ai-ev .tx { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ai-ev .hd { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; font-size: .85rem; }
.ai-ev .ph { font-weight: 750; font-size: 1rem; margin: .15rem 0 .1rem; }
.ai-ev .desc { font-size: .88rem; color: var(--pico-muted-color); margin: 0 0 .4rem; line-height: 1.45; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.ai-ev .acts { margin-top: auto; display: flex; gap: .4rem; }
.ai-ev .acts .btn { margin: 0; }
@media (max-width: 560px) { .ai-last { grid-template-columns: 1fr; } .ai-ev { flex-direction: column; } .ai-ev .pic { width: 100%; } }

/* poslední hodnocení AI v kartě kamery */
.cam .ai-note { display: flex; gap: .55rem; align-items: flex-start; margin-top: .35rem; padding: .5rem .6rem; border-radius: 9px; background: var(--pico-card-sectioning-background-color); border: 1px solid var(--pico-card-border-color); text-decoration: none; color: inherit; font-size: .82rem; line-height: 1.35; }
.cam .ai-note:hover { border-color: var(--pico-primary); text-decoration: none; }
.cam .ai-note.hit { border-color: rgba(34, 197, 94, .5); }
.cam .ai-note .sc { flex: none; font-weight: 800; font-size: .78rem; padding: .1rem .45rem; border-radius: .4rem; background: var(--sw-ok-bg); color: var(--sw-ok); }
.cam .ai-note .sc.mut { background: var(--pico-muted-border-color); color: var(--pico-muted-color); }
.cam .ai-note .t { min-width: 0; }
.cam .ai-note .t small { color: var(--pico-muted-color); }
.cam .ai-note .desc { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; color: var(--pico-muted-color); }
.shot .desc2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

/* ---------- hero: východ/západ výrazně, svítání/soumrak tlumeně ---------- */
.hero .sun span.tw { color: rgba(255, 255, 255, .55); font-weight: 600; }
.hero .sun span.tw small { color: rgba(255, 255, 255, .4); }
.hero .sun span.main { font-size: 1.05rem; color: #fff; }
.hero .sun span.main small { color: #fde68a; }

/* ---------- historie: filtry z tlačítek + řádkový výpis ---------- */
.filters { display: flex; flex-wrap: wrap; gap: .6rem 1.4rem; align-items: center; margin-bottom: 1rem; padding: .7rem .9rem; border-radius: var(--at-radius); background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); }
.fgroup { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
.fgroup .fl { font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: var(--pico-muted-color); font-weight: 700; }
.seg a:hover { color: var(--pico-color); text-decoration: none; }
h2.day { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em; color: var(--pico-muted-color); margin: 1.1rem 0 .5rem; }
.hrow { display: flex; gap: 1rem; align-items: center; margin: 0 0 .6rem; padding: .6rem; border-radius: var(--at-radius); background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); box-shadow: var(--sw-shadow); }
.hrow.hit { border-left: 4px solid var(--sw-ok); }
.hrow.err { border-left: 4px solid var(--sw-err); }
.hrow .pic { position: relative; flex: none; width: 220px; border-radius: 9px; overflow: hidden; background: var(--sw-img-bg); }
.hrow .pic img { width: 100%; aspect-ratio: 16 / 9; object-fit: cover; display: block; }
.hrow .sc { position: absolute; left: .45rem; bottom: .45rem; padding: .1rem .5rem; border-radius: .4rem; font-weight: 800; font-size: .82rem; background: rgba(2, 6, 23, .78); color: #fff; }
.hrow .sc.ok { color: #4ade80; } .hrow .sc.mut { color: #cbd5e1; } .hrow .sc.err { color: #f87171; }
.hrow .tx { flex: 1; min-width: 0; }
.hrow .hd { display: flex; align-items: center; gap: .55rem; flex-wrap: wrap; margin-bottom: .25rem; }
.hrow .when { font-weight: 800; font-size: 1.05rem; font-variant-numeric: tabular-nums; }
.hrow .ph { color: var(--pico-primary); font-weight: 700; }
.hrow .desc { margin: 0; font-size: .92rem; line-height: 1.45; color: var(--pico-color); }
.hrow .ac { flex: none; }
.hrow .ac .btn { margin: 0; }
@media (max-width: 720px) { .hrow { flex-wrap: wrap; } .hrow .pic { width: 100%; } .hrow .ac { width: 100%; } .hrow .ac .btn { width: 100%; } }

/* historie: skóre v řádku + stránkování */
.hrow .score { display: inline-flex; align-items: baseline; gap: .05rem; padding: .15rem .6rem; border-radius: .5rem; font-weight: 800; font-size: 1.1rem; line-height: 1.2; background: var(--pico-muted-border-color); color: var(--pico-muted-color); }
.hrow .score small { font-size: .7rem; font-weight: 600; opacity: .8; }
.hrow .score.ok { background: var(--sw-ok-bg); color: var(--sw-ok); }
.hrow .score.mid { background: var(--sw-warn-bg); color: var(--sw-warn); }
.hrow .score.low { background: var(--pico-muted-border-color); color: var(--pico-muted-color); }
.hrow .score.err { background: var(--sw-err-bg); color: var(--sw-err); }
.pager { display: flex; align-items: center; justify-content: center; gap: .8rem; margin: 1.2rem 0 .5rem; flex-wrap: wrap; }
.pager .btn { margin: 0; }
.pager .btn.dis { opacity: .4; pointer-events: none; }
.pager .pages { display: flex; gap: .25rem; align-items: center; }
.pager .pages a, .pager .pages span { min-width: 34px; height: 34px; display: inline-flex; align-items: center; justify-content: center; border-radius: .55rem; text-decoration: none; font-weight: 700; font-size: .9rem; color: var(--pico-muted-color); }
.pager .pages a:hover { background: var(--pico-card-sectioning-background-color); color: var(--pico-color); }
.pager .pages a.on { background: var(--pico-primary-background); color: var(--pico-primary-inverse); }

/* ---------- AI: záložky, pravidla kamer, lišta uložení ---------- */
.tabs.big { gap: .4rem; margin-bottom: 1rem; }
.tabs.big button { display: inline-flex; align-items: center; gap: .5rem; padding: .55rem .9rem; border-radius: .7rem; border: 1px solid var(--pico-card-border-color); background: var(--pico-card-background-color); color: var(--pico-muted-color); font-weight: 700; font-size: .92rem; margin: 0; width: auto; cursor: pointer; box-shadow: none; }
.tabs.big button .n { width: 22px; height: 22px; border-radius: 50%; background: var(--pico-muted-border-color); color: var(--pico-muted-color); display: inline-grid; place-items: center; font-size: .75rem; }
.tabs.big button:hover { border-color: var(--pico-primary); color: var(--pico-color); }
.tabs.big button.on { background: var(--pico-primary-background); border-color: var(--pico-primary-background); color: var(--pico-primary-inverse); }
.tabs.big button.on .n { background: rgba(255, 255, 255, .25); color: #fff; }
.cam-rules { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 560px), 1fr)); gap: 1rem; margin-bottom: 1rem; align-items: start; }
.cam-rules .card { margin: 0; }
.cam-rule.off { opacity: .6; }
.cam-rule .seg label { margin: 0; cursor: pointer; }
.savebar { position: sticky; bottom: 0; z-index: 5; display: flex; align-items: center; gap: .8rem; padding: .7rem 1rem; margin: 0 0 1rem; border-radius: var(--at-radius); background: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); box-shadow: 0 -8px 30px rgba(0, 0, 0, .25); }
.savebar .btn { margin: 0; }
.plainlist { list-style: none; margin: 0 0 .8rem; padding: 0; }
.plainlist li { padding: .35rem 0; border-bottom: 1px solid var(--pico-card-border-color); display: flex; align-items: center; flex-wrap: wrap; gap: .3rem; }
.plainlist li:last-child { border: 0; }
.plainlist form .btn { margin: 0; }
@media (max-width: 640px) { .cam-rules { grid-template-columns: 1fr; } .tabs.big button { font-size: .82rem; padding: .45rem .6rem; } }
.check.any { padding: .5rem .7rem; border-radius: .7rem; background: var(--sw-info-bg); border: 1px solid var(--pico-primary); }

/* ---------- srozumitelný log ---------- */
.loglist { display: flex; flex-direction: column; gap: .2rem; max-height: 70vh; overflow: auto; padding-right: .3rem; }
.lrow { display: grid; grid-template-columns: 82px 20px minmax(0, 1fr); gap: .5rem; align-items: start; padding: .4rem .6rem; border-radius: .55rem; font-size: .86rem; line-height: 1.4; background: var(--pico-card-sectioning-background-color); }
.lrow .lt { color: var(--pico-muted-color); font-variant-numeric: tabular-nums; white-space: nowrap; }
.lrow .li { text-align: center; font-weight: 800; }
.lrow .lx { word-break: break-word; }
.lrow .lx small { display: block; color: var(--pico-muted-color); font-size: .8rem; }
.lrow.ok .li { color: var(--pico-muted-color); }
.lrow.note { background: var(--sw-info-bg); } .lrow.note .li { color: var(--sw-info); }
.lrow.warn { background: var(--sw-warn-bg); } .lrow.warn .li { color: var(--sw-warn); }
.lrow.err { background: var(--sw-err-bg); } .lrow.err .li { color: var(--sw-err); }
.lrow.err .lx small, .lrow.warn .lx small { color: inherit; opacity: .85; }
@media (max-width: 640px) { .lrow { grid-template-columns: 20px minmax(0, 1fr); } .lrow .lt { grid-column: 2; font-size: .72rem; } }

/* ---------- Video studio (zrychlení, intro, hudba) ---------- */
.seg.speeds label { cursor: pointer; }
.studio-src { display: flex; gap: 1rem; align-items: center; }
.studio-src .thumb { position: relative; width: 180px; aspect-ratio: 16 / 9; flex: none; border-radius: .5rem; overflow: hidden; background: var(--sw-img-bg); display: block; }
.studio-src .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
.studio-src .thumb .play { position: absolute; inset: 0; margin: auto; width: 40px; height: 40px; border-radius: 50%; background: rgba(2, 6, 23, .6); color: #fff; display: flex; align-items: center; justify-content: center; padding-left: .2rem; }
.studio-wait { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: .6rem; min-height: 260px; padding: 1.5rem; text-align: center; background: var(--sw-img-bg); }
.studio-wait p { margin: 0; }
.pbar { width: min(420px, 90%); height: 10px; border-radius: 999px; background: var(--pico-muted-border-color); overflow: hidden; }
.pbar i { display: block; height: 100%; background: var(--pico-primary); transition: width .5s; }
.studio-intro, .studio-music { display: flex; gap: .9rem; align-items: center; padding: .5rem 0; }
.studio-intro img, .studio-intro video { width: 200px; aspect-ratio: 16 / 9; object-fit: cover; border-radius: .5rem; background: #000; flex: none; }
.studio-music audio { width: 220px; flex: none; height: 36px; }
.studio-music > div, .studio-intro > div { flex: 1; min-width: 0; }
.studio-acts { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; }
.studio-acts .btn { margin: 0; }
.btn.dis { opacity: .55; pointer-events: none; }
input[type="file"] { padding: .4rem 0; }
@media (max-width: 600px) { .studio-src { flex-direction: column; align-items: flex-start; } .studio-src .thumb { width: 100%; } .studio-music, .studio-intro { flex-wrap: wrap; } }
.speed-preview { margin-top: .7rem; }
.speed-preview video { width: 100%; max-height: 420px; aspect-ratio: 16 / 9; background: #000; border-radius: .6rem; display: block; cursor: pointer; }
.finder summary { cursor: pointer; font-weight: 600; }
.tracks { display: flex; flex-direction: column; gap: .4rem; margin-top: .6rem; }
.track { display: flex; align-items: center; gap: .7rem; padding: .45rem .6rem; border-radius: .6rem; background: var(--pico-card-sectioning-background-color); }
.track audio { width: 230px; flex: none; height: 34px; }
.track .tx { flex: 1; min-width: 0; font-size: .92rem; line-height: 1.3; }
.track .btn { margin: 0; flex: none; }
@media (max-width: 640px) { .track { flex-wrap: wrap; } .track audio { width: 100%; } }
.speed-pick { display: flex; align-items: center; gap: .6rem; }
.speed-pick input[type="range"] { flex: 1; margin: 0; accent-color: var(--pico-primary); }
.speed-pick .btn { margin: 0; flex: none; }
.speed-val { font-size: 1.5rem; font-weight: 800; min-width: 4.2rem; text-align: right; }
.yt-code { margin-top: .9rem; padding: .9rem 1rem; border-radius: .7rem; background: var(--pico-card-sectioning-background-color); border: 1px solid var(--pico-card-border-color); }
.yt-code .code { font-size: 2.2rem; font-weight: 800; letter-spacing: .12em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: .3rem 0 .5rem; user-select: all; }
.eta { margin: .3rem 0 0; font-weight: 600; }
.cleanup { margin-top: .8rem; padding-top: .6rem; border-top: 1px solid var(--pico-card-border-color); }
.cleanup h3 { font-size: 1rem; margin: 0 0 .2rem; }
.cleanup .check { margin: .35rem 0; }
.ideas { margin: .35rem 0 .6rem; display: flex; flex-wrap: wrap; align-items: center; gap: .5rem; }
.ideas .btn { margin: 0; }
.ideas .chips { width: 100%; }
.ideas .chip { cursor: pointer; }
.ideas .chip:hover { border-color: var(--pico-primary); background: var(--sw-info-bg); }
ATMOVIO_CSS_EOF
  cat > "$1/atmovio.js" <<'ATMOVIO_JS_EOF'
/* Atmovio – interakce (Alpine.js komponenty + pomocné funkce). */
(function () {
  'use strict';

  // ---------- Alpine komponenty ----------
  document.addEventListener('alpine:init', function () {
    // Kostra stránky: mobilní menu, rozbalovací nabídky v hlavičce (dd), přepínač vzhledu, toasty, lightbox.
    Alpine.data('shell', function (opts) {
      opts = opts || {};
      return {
        menu: false,
        dd: '',
        theme: document.documentElement.getAttribute('data-theme') || 'dark',
        toasts: [],
        lb: { open: false, src: '', caption: '', items: [], index: -1 },
        init: function () {
          var self = this;
          (opts.flashes || []).forEach(function (f) { self.toast(f.text, f.kind); });
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') { self.lb.open = false; self.menu = false; document.body.classList.remove('lb-open'); }
            if (self.lb.open && e.key === 'ArrowRight') self.lbStep(1);
            if (self.lb.open && e.key === 'ArrowLeft') self.lbStep(-1);
          });
          document.addEventListener('click', function (e) {
            var a = e.target.closest('a[data-lightbox]');
            if (!a) return;
            e.preventDefault();
            var group = a.dataset.lightbox || '';
            var links = group ? Array.prototype.slice.call(document.querySelectorAll('a[data-lightbox="' + group + '"]')) : [a];
            self.lb.items = links.map(function (l) { return { src: l.href, caption: l.dataset.caption || '' }; });
            self.lb.index = Math.max(0, links.indexOf(a));
            self.lbShow();
          });
        },
        toggleTheme: function () {
          this.theme = this.theme === 'dark' ? 'light' : 'dark';
          document.documentElement.setAttribute('data-theme', this.theme);
          try { localStorage.setItem('atmovio-theme', this.theme); } catch (e) { /* soukromý režim */ }
        },
        toast: function (text, kind) {
          var id = Date.now() + Math.random();
          this.toasts.push({ id: id, text: text, kind: kind || '' });
          if (kind !== 'err') {
            var self = this;
            setTimeout(function () { self.dismiss(id); }, 7000);
          }
        },
        dismiss: function (id) { this.toasts = this.toasts.filter(function (t) { return t.id !== id; }); },
        lbShow: function () {
          var it = this.lb.items[this.lb.index];
          if (!it) return;
          this.lb.src = it.src; this.lb.caption = it.caption; this.lb.open = true;
          document.body.classList.add('lb-open');
        },
        lbClose: function () { this.lb.open = false; this.lb.src = ''; document.body.classList.remove('lb-open'); },
        lbStep: function (d) {
          if (this.lb.items.length < 2) return;
          this.lb.index = (this.lb.index + d + this.lb.items.length) % this.lb.items.length;
          this.lbShow();
        }
      };
    });

    // Automatické obnovení stránky (dashboard, logy) – ne při otevřeném obrázku, menu nebo rozepsaném formuláři.
    Alpine.data('autorefresh', function (seconds) {
      return {
        init: function () {
          var self = this;
          function tick() {
            var busy = document.querySelector('form:focus-within') || document.body.classList.contains('lb-open') ||
              document.querySelector('details[open][data-keep]');
            if (!busy && document.visibilityState === 'visible') location.reload(); else setTimeout(tick, 15000);
          }
          setTimeout(tick, (seconds || 60) * 1000);
        }
      };
    });

    // Průběh aktualizace Atmovio (/system/update): každé 3 s se ptá /system/update/status.
    // Během restartu služby dotaz selže – to je normální fáze "restart"; hotovo = odpověď s jinou verzí.
    Alpine.data('updater', function (running, version, log) {
      return {
        running: !!running, version: version, log: log || '', phase: running ? 'run' : '', newVersion: '', idle: 0,
        init: function () { if (this.running) this.poll(); },
        later: function () { var self = this; setTimeout(function () { self.poll(); }, 3000); },
        poll: function () {
          var self = this;
          fetch('/system/update/status', { credentials: 'same-origin', cache: 'no-store' })
            .then(function (r) { if (!r.ok || r.redirected) throw new Error('nedostupné'); return r.json(); })
            .then(function (s) {
              if (s.log) self.log = s.log;
              if (s.version && s.version !== self.version) { self.phase = 'done'; self.newVersion = s.version; self.running = false; return; }
              if (s.running) { self.phase = 'run'; self.idle = 0; self.later(); return; }
              // Jednotka skončila a verze je stejná: buď rollback (poznáme z logu), nebo se ještě nerozběhla.
              if (/selhala|obnovuji|rollback/i.test(self.log) || ++self.idle > 10) { self.phase = 'failed'; self.running = false; return; }
              self.phase = 'run'; self.later();
            })
            .catch(function () { self.phase = 'restart'; self.later(); });
        }
      };
    });

    // ---------- Návrh titulku přes AI (studio) ----------
    Alpine.data('titleIdeas', function (opts) {
      return {
        titles: [], msg: '', busy: false,
        ask: function (speed) {
          var self = this, fd = new FormData(), csrf = document.querySelector('input[name=csrf_token]');
          fd.append('csrf_token', csrf ? csrf.value : ''); fd.append('sid', opts.sid || 0); fd.append('vid', opts.vid || 0); fd.append('speed', speed || 20);
          self.busy = true; self.msg = '';
          fetch('/studio/titles', { method: 'POST', body: fd, credentials: 'same-origin' }).then(function (r) { return r.json(); })
            .then(function (d) { if (!d.ok) { self.msg = d.error; return; } self.titles = d.titles; self.msg = 'Klikni na návrh, který se ti líbí:'; })
            .catch(function () { self.msg = 'Návrh selhal.'; }).finally(function () { self.busy = false; });
        }
      };
    });

    // ---------- Odpočet „zbývá asi …“ mezi obnoveními stránky ----------
    Alpine.data('countdown', function (seconds) {
      return {
        left: Math.max(0, seconds || 0), txt: '',
        fmt: function () { var s = this.left; if (s <= 0) return 'už jen chvilku…'; return 'zbývá asi ' + (s >= 90 ? Math.round(s / 60) + ' min' : (s >= 10 ? Math.round(s / 5) * 5 : s) + ' s'); },
        init: function () { var self = this; self.txt = self.fmt(); setInterval(function () { if (self.left > 0) self.left -= 1; self.txt = self.fmt(); }, 1000); }
      };
    });

    // ---------- Propojení YouTube: sleduje stav zadání kódu na google.com/device ----------
    Alpine.data('ytLink', function (active) {
      return {
        st: {},
        init: function () {
          var self = this;
          function poll() {
            fetch('/studio/youtube/status', { credentials: 'same-origin' }).then(function (r) { return r.json(); }).then(function (d) {
              self.st = d || {};
              if (d.status === 'done') { location.href = '/studio/settings#youtube'; location.reload(); return; }
              if (d.status === 'waiting') setTimeout(poll, 4000);
            }).catch(function () { setTimeout(poll, 8000); });
          }
          if (active) poll();
        }
      };
    });

    // ---------- Hledání hudby (Openverse) přímo u videa ----------
    Alpine.data('musicFinder', function (initial) {
      return {
        q: '', len: '', items: [], msg: '', busy: false, open: false, music: initial || '',
        search: function () {
          var self = this;
          if (self.q.trim().length < 2) { self.msg = 'Zadej aspoň dvě písmena.'; return; }
          self.busy = true; self.msg = 'Hledám…'; self.items = [];
          fetch('/studio/music/search?q=' + encodeURIComponent(self.q.trim()) + '&length=' + encodeURIComponent(self.len), { credentials: 'same-origin' })
            .then(function (r) { return r.json(); })
            .then(function (d) { self.items = d.items || []; self.msg = d.error || (self.items.length + ' skladeb – přehraj si je a klikni Použít'); })
            .catch(function () { self.msg = 'Hledání selhalo – RPi nejspíš nemá přístup na internet.'; })
            .finally(function () { self.busy = false; });
        },
        use: function (t) {
          var self = this, fd = new FormData();
          var csrf = document.querySelector('input[name=csrf_token]');
          fd.append('csrf_token', csrf ? csrf.value : '');
          ['id', 'url', 'title', 'creator', 'license', 'attribution', 'page', 'filetype'].forEach(function (k) { fd.append(k, t[k] || ''); });
          self.busy = true; self.msg = 'Stahuji „' + t.title + '“ na RPi…';
          fetch('/studio/music/fetch', { method: 'POST', body: fd, credentials: 'same-origin' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
              if (!d.ok) { self.msg = d.error || 'Stažení selhalo.'; return; }
              var sel = self.$refs.sel;
              if (![].some.call(sel.options, function (o) { return o.value === d.name; })) { var o = document.createElement('option'); o.value = d.name; o.textContent = d.name; sel.appendChild(o); }
              self.music = d.name; sel.value = d.name; t.name = d.name;
              self.msg = 'Vybráno: ' + d.name + '. Autor se doplní do popisu videa.';
            })
            .catch(function () { self.msg = 'Stažení selhalo.'; })
            .finally(function () { self.busy = false; });
        }
      };
    });

  // ---------- Náhled rychlosti ve studiu: přehraje zdrojové video tak, jak bude vypadat zrychlené ----------
    // Do 16× nativně, výš skoky v čase (jako v přehrávači). Orientační – hotové video je plynulé.
    Alpine.data('speedPreview', function (src, speed) {
      return {
        src: src, on: false, speed: speed || 20, running: false, timer: null, seekHandler: null, pos: '',
        fmt: function (t) { t = Math.max(1, Math.round(t || 0)); return Math.floor(t / 60) + ':' + ('0' + t % 60).slice(-2); },
      // Odhad doby vytváření na RPi 5: dekódování všech snímků (do 120×) nebo jen klíčových, + kódování ~35 sn./s v 1080p.
      eta: function (dur, fps, width) {
        var px = Math.min(1, (width || 1920) / 1920) || 1;
        var decode = this.speed >= 120 ? dur / 40 : dur * (fps || 25) / (260 / px);
        var encode = (dur / this.speed) * 30 / (35 / px);
        var s = Math.max(5, decode + encode + 3);
        return s < 90 ? 'asi ' + Math.round(s / 10) * 10 + ' s' : 'asi ' + Math.round(s / 60) + ' min';
      },
        get video() { return this.$refs.v; },
        stop: function () {
          this.running = false;
          if (this.timer) { clearTimeout(this.timer); this.timer = null; }
          if (this.seekHandler) { this.video.removeEventListener('seeked', this.seekHandler); this.seekHandler = null; }
          this.video.pause();
        },
        tick: function () {
          var self = this, v = this.video, ms = this.speed >= 120 ? 250 : 125;
          if (!self.running) return;
          if (!isFinite(v.duration)) { self.stop(); return; }
        if (v.currentTime >= v.duration - 0.05) { v.currentTime = 0; }   // dokola, dokud to uživatel nezavře
          var t0 = performance.now();
          self.seekHandler = function () {
            v.removeEventListener('seeked', self.seekHandler); self.seekHandler = null;
            self.pos = self.fmt(v.currentTime) + ' / ' + self.fmt(v.duration);
            if (!self.running) return;
            self.timer = setTimeout(function () { self.tick(); }, Math.max(0, ms - (performance.now() - t0)));
          };
          v.addEventListener('seeked', self.seekHandler);
          v.currentTime = Math.min(v.duration, v.currentTime + self.speed * ms / 1000);
        },
        play: function (speed) {
          var self = this, v = this.video;
          this.speed = speed; this.on = true; this.stop();
          if (!v.src) { v.src = this.src; }
          v.muted = true; v.loop = true;
          var go = function () {
            v.currentTime = 0;
            if (self.speed <= 16) { v.playbackRate = self.speed; v.play().catch(function () {}); }
            else { v.playbackRate = 1; self.running = true; self.tick(); }
          };
          if (v.readyState >= 1) go(); else v.addEventListener('loadedmetadata', go, { once: true });
        },
        init: function () {
          var self = this;
          this.$watch('speed', function (s) { if (self.on) self.play(s); });
          this.$refs.v.addEventListener('timeupdate', function () { if (self.speed <= 16) self.pos = self.fmt(self.video.currentTime) + ' / ' + self.fmt(self.video.duration); });
                  }
      };
    });
  });

  // ---------- Odeslání formuláře: zablokovat tlačítko a ukázat, co se děje ----------
  var HINTS = [
    ['/cameras/add', 'Ověřuji kameru a čekám na skutečné snímky z každé adresy – může to trvat i několik minut, pak se restartuje nahrávání.'],
    ['/discover', 'Prohledávám síť a ověřuji každou nalezenou adresu – i několik minut.'],
    ['/storage/disk', 'Připravuji disk – formátování a připojení trvá do minuty.'],
    ['/ai/test', 'Beru snímek z kamery a posílám ho AI – do půl minuty.'],
    ['/ai/check', 'Ověřuji klíč u poskytovatele AI.'],
    ['/system/ctl', 'Provádím akci; služby se restartují.'],
    ['/system/update/check', 'Ptám se GitHubu na poslední vydání.'],
  ];
  function installBusy() {
    var busy = document.getElementById('busy');
    if (!busy) return;
    var txt = document.getElementById('busy-text'), hint = document.getElementById('busy-hint');
    document.addEventListener('submit', function (e) {
      var f = e.target;
      if (!(f instanceof HTMLFormElement) || f.dataset.nobusy !== undefined || f.method.toLowerCase() === 'get') return;
      var btn = e.submitter || f.querySelector('button:not([type=button]),[type=submit]');
      var label = (btn && (btn.dataset.busy || btn.textContent.trim())) || 'Odesílám';
      setTimeout(function () {
        if (e.defaultPrevented) return;
        if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.textContent = label.replace(/^[^\wÀ-ž]+/, '') + '…'; }
        txt.textContent = label + '…';
        var action = f.getAttribute('action') || '';
        var h = HINTS.filter(function (x) { return action.indexOf(x[0]) > -1; })[0];
        hint.textContent = h ? h[1] : 'Stránka se sama obnoví, až bude hotovo.';
        busy.hidden = false;
      }, 0);
    }, true);
    window.addEventListener('pageshow', function () {
      busy.hidden = true;
      document.querySelectorAll('button[disabled][data-label]').forEach(function (b) { b.disabled = false; b.textContent = b.dataset.label; });
    });
  }

  // ---------- Kopírování do schránky (funguje i na http bez certifikátu) ----------
  window.swCopy = function (el, btn) {
    var node = typeof el === 'string' ? document.getElementById(el) : el;
    if (!node) return;
    var text = node.value !== undefined ? node.value : node.textContent;
    function done(ok) {
      if (!btn) return;
      var old = btn.textContent;
      btn.textContent = ok ? 'Zkopírováno ✓' : 'Vyber text a stiskni Ctrl/Cmd+C';
      setTimeout(function () { btn.textContent = old; }, 2500);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      return;
    }
    var r = document.createRange(); r.selectNodeContents(node);
    var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
    try { done(document.execCommand('copy')); } catch (e) { done(false); }
  };

  // ---------- Náhledy kamer: když obrázek nejde, ukázat text místo prázdna ----------
  window.swImgFail = function (img, text) {
    img.style.display = 'none';
    var s = document.createElement('span'); s.textContent = text || 'bez obrazu';
    img.parentNode.appendChild(s);
  };

  // ---------- Kamery: snímky se samy obnovují, živý přenos jen na kliknutí ----------
  function installSnapshots() {
    document.querySelectorAll('img[data-refresh]').forEach(function (img) {
      var sec = Math.max(3, parseInt(img.dataset.refresh, 10) || 10);
      var base = img.dataset.snap || img.getAttribute('src').replace(/[?&]t=\d+/, '');
      img.dataset.snap = base;
      setInterval(function () {
        if (document.visibilityState !== 'visible' || img.dataset.live === '1' || document.body.classList.contains('lb-open')) return;
        img.src = base + (base.indexOf('?') > -1 ? '&' : '?') + 't=' + Date.now();
      }, sec * 1000);
    });
  }
  window.swLiveToggle = function (btn) {
    var img = document.getElementById(btn.dataset.target);
    if (!img) return;
    if (img.dataset.live === '1') {
      img.dataset.live = '0';
      img.src = img.dataset.snap + (img.dataset.snap.indexOf('?') > -1 ? '&' : '?') + 't=' + Date.now();
      btn.textContent = '▶ Spustit živý přenos'; btn.classList.remove('sec');
    } else {
      img.dataset.live = '1';
      img.src = img.dataset.stream + '&t=' + Date.now();
      btn.textContent = '⏹ Zastavit živý přenos'; btn.classList.add('sec');
    }
  };
  // Při opuštění stránky přenos ukončit (prohlížeč jinak drží spojení do bfcache).
  window.addEventListener('pagehide', function () {
    document.querySelectorAll('img[data-live="1"]').forEach(function (img) { img.src = ''; });
  });

  // ---------- Přehrávač videa přes celou obrazovku (s rychlostí až 120×) ----------
  // Do 16× používá nativní playbackRate (víc prohlížeče nedovolí); vyšší rychlosti se dělají
  // skokovým posunem času (timelapse) – funguje i na 60× a 120×.
  var SPEEDS = [1, 2, 4, 8, 16, 30, 60, 120];
  window.swPlayVideo = function (src, title) {
    var old = document.getElementById('sw-player');
    if (old) old.remove();
    var box = document.createElement('div');
    box.id = 'sw-player'; box.className = 'lightbox player';
    box.innerHTML = '<button type="button" class="close" aria-label="Zavřít">×</button><figure><video controls autoplay muted playsinline preload="metadata"></video>' +
      '<div class="speeds"><span class="lbl">Rychlost</span>' +
      SPEEDS.map(function (v) { return '<button type="button" data-v="' + v + '"' + (v === 1 ? ' class="on"' : '') + '>' + v + '×</button>'; }).join('') +
      '<button type="button" class="pp" hidden>⏸</button><span class="pos"></span></div><figcaption></figcaption></figure>';
    var video = box.querySelector('video'), bar = box.querySelector('.speeds'), pp = box.querySelector('.pp'), pos = box.querySelector('.pos');
    video.src = src;
    box.querySelector('figcaption').textContent = title || '';
    var step = { speed: 0, timer: null, running: false, seekHandler: null };
    function fmt(t) { t = Math.max(0, Math.floor(t || 0)); return Math.floor(t / 60) + ':' + ('0' + t % 60).slice(-2); }
    function showPos() { if (isFinite(video.duration)) pos.textContent = fmt(video.currentTime) + ' / ' + fmt(video.duration); }
    function stopStep() {
      step.running = false;
      if (step.timer) { clearTimeout(step.timer); step.timer = null; }
      if (step.seekHandler) { video.removeEventListener('seeked', step.seekHandler); step.seekHandler = null; }
      pp.textContent = '▶';
    }
    function tick() {
      if (!step.running) return;
      if (!isFinite(video.duration) || video.currentTime >= video.duration - 0.05) { stopStep(); return; }
      var t0 = performance.now();
      step.seekHandler = function () {
        video.removeEventListener('seeked', step.seekHandler); step.seekHandler = null;
        showPos();
        if (!step.running) return;
        step.timer = setTimeout(tick, Math.max(0, 125 - (performance.now() - t0)));
      };
      video.addEventListener('seeked', step.seekHandler);
      video.currentTime = Math.min(video.duration, video.currentTime + step.speed * 0.125);
    }
    function startStep() { if (step.running) return; video.pause(); step.running = true; pp.textContent = '⏸'; tick(); }
    function setSpeed(v) {
      stopStep();
      bar.querySelectorAll('button[data-v]').forEach(function (b) { b.classList.toggle('on', +b.dataset.v === v); });
      if (v <= 16) {
        step.speed = 0; pp.hidden = true;
        video.playbackRate = v; video.muted = v > 1 || video.muted;
        if (video.paused) video.play().catch(function () {});
      } else {
        step.speed = v; pp.hidden = false;
        video.playbackRate = 1;
        startStep();
      }
    }
    bar.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-v]');
      if (b) { setSpeed(+b.dataset.v); return; }
      if (e.target === pp) { if (step.running) stopStep(); else startStep(); }
    });
    // V režimu skoků nativní tlačítko Play jen znovu spustí skákání.
    video.addEventListener('play', function () { if (step.speed > 16 && !step.running) { video.pause(); startStep(); } });
    video.addEventListener('timeupdate', function () { if (!step.speed) showPos(); });
    video.addEventListener('loadedmetadata', showPos);
    function close() { stopStep(); video.pause(); video.removeAttribute('src'); video.load(); box.remove(); document.body.classList.remove('lb-open'); document.removeEventListener('keydown', onKey); }
    function onKey(e) {
      if (e.key === 'Escape') close();
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        var cur = step.speed || video.playbackRate, i = SPEEDS.indexOf(cur);
        if (i < 0) i = 0;
        i = Math.max(0, Math.min(SPEEDS.length - 1, i + (e.key === 'ArrowUp' ? 1 : -1)));
        setSpeed(SPEEDS[i]); e.preventDefault();
      }
    }
    box.querySelector('.close').addEventListener('click', close);
    box.addEventListener('click', function (e) { if (e.target === box) close(); });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(box); document.body.classList.add('lb-open');
    return false;
  };

  function boot() { installBusy(); installSnapshots(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
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
write_static "$SKY_DIR/static"
fetch_vendor "$SKY_DIR/static"
if [[ ! -x "$SKY_DIR/venv/bin/python" ]]; then python3 -m venv "$SKY_DIR/venv"; fi
"$SKY_DIR/venv/bin/pip" install -q --upgrade pip
"$SKY_DIR/venv/bin/pip" install -q -r "$SKY_DIR/requirements.txt" || die "Instalace Python balíčků pro Atmovio selhala"

# počáteční konfigurace (heslo, pásmo, retence)
ATMOVIO_DIR=$SKY_DIR ATMOVIO_ADMIN_PASSWORD="$ADMIN_PW" SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" SMTP_SEC="$SMTP_SEC" \
  SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" MAIL_FROM="$MAIL_FROM" MAIL_TO="$MAIL_TO" "$SKY_DIR/venv/bin/python" - <<EOF
import json, os, sys
sys.path.insert(0, "$SKY_DIR")
os.environ["ATMOVIO_DIR"] = "$SKY_DIR"
import app
cfg = app.load_config()
cfg["admin_password_hash"] = app.hash_pw(os.environ["ATMOVIO_ADMIN_PASSWORD"])
cfg["tz"] = "$TZONE"
cfg["frigate_config_path"] = "$FRIGATE_CFG_DIR/config.yml"
cfg["recordings_path"] = "$DATA_MNT/frigate/recordings"
cfg["snapshot_dir"] = "$DATA_MNT/atmovio/snapshots"
cfg["email"].update({"host": os.environ.get("SMTP_HOST", ""), "port": int(os.environ.get("SMTP_PORT", "587") or 587),
    "security": os.environ.get("SMTP_SEC", "starttls"), "user": os.environ.get("SMTP_USER", ""),
    "password": os.environ.get("SMTP_PASS", ""), "from": os.environ.get("MAIL_FROM", ""), "to": os.environ.get("MAIL_TO", "")})
app.save_config(cfg)
print("Atmovio config OK")
EOF

cat > /etc/systemd/system/atmovio.service <<EOF
[Unit]
Description=Atmovio – NVR administrace a AI hlídání oblohy
After=network-online.target docker.service
Wants=network-online.target

[Service]
UMask=0077
Environment=ATMOVIO_DIR=$SKY_DIR
Environment=ATMOVIO_PORT=80
WorkingDirectory=$SKY_DIR
ExecStart=$SKY_DIR/venv/bin/python $SKY_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/atmovio.service
systemctl daemon-reload
"$SKY_DIR/venv/bin/python" "$SKY_DIR/storage_guard.py" --install
systemctl daemon-reload
systemctl enable --now atmovio.service
sleep 3
systemctl is-active --quiet atmovio.service || { journalctl -u atmovio -n 30 --no-pager; die "Atmovio se nespustil"; }
ok "Atmovio běží na portu 80"

# ----------------------------------------------------------------------------- 7. Frigate heslo
step "Čekám na start Frigate a nastavuji heslo admin (stejné jako Atmovio, až 3 minuty)"
# Port 5000 je jen na localhostu a bez přihlášení – heslo se nastaví přímo přes API,
# nezávisle na tom, co Frigate vypíše do logu.
FRIGATE_PW_NOTE=""
FRIGATE_UP=0
for _ in $(seq 1 60); do
  sleep 3
  if curl -fsS -m 3 http://127.0.0.1:5000/api/version >/dev/null 2>&1; then FRIGATE_UP=1; break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' frigate 2>/dev/null)" == "false" ]]; then
    warn "Kontejner frigate spadl – poslední řádky logu:"
    docker logs --tail 40 frigate 2>&1 | grep -vE '^s6-rc' | tail -20 || true
    break
  fi
done
if [[ $FRIGATE_UP -eq 1 ]]; then
  PW_JSON=$(jq -cn --arg p "$ADMIN_PW" '{password:$p}')
  if curl -fsS -m 10 -X PUT http://127.0.0.1:5000/api/users/admin/password \
       -H 'Content-Type: application/json' -d "$PW_JSON" >/dev/null 2>&1; then
    ok "Heslo Frigate (admin) nastaveno stejné jako pro Atmovio"
  else
    warn "Heslo Frigate se nepodařilo nastavit přes API"
    FRIGATE_PW_NOTE="(nepodařilo se nastavit – nové vygeneruješ v Atmovio → Systém → Vygenerovat nové heslo)"
  fi
else
  warn "Frigate nenaběhl do 3 minut – heslo nenastaveno"
  FRIGATE_PW_NOTE="(Frigate nenaběhl – zkontroluj 'sudo docker logs frigate'; heslo pak nastavíš v Atmovio → Systém)"
fi

# ----------------------------------------------------------------------------- 7b. test e-mailu
MAIL_NOTE="zatím nenastaven – doplň v Atmovio → E-mail (příjemce $MAIL_TO je předvyplněný)"
if [[ -n "$SMTP_HOST" ]]; then
  step "Testovací e-mail na $MAIL_TO"
  IP_NOW=$(hostname -I | awk '{print $1}')
  if ATMOVIO_DIR=$SKY_DIR NVR_IP="$IP_NOW" "$SKY_DIR/venv/bin/python" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["ATMOVIO_DIR"])
import app
cfg = app.load_config()
app.send_email(cfg["email"], "[Atmovio] Instalace dokončena",
    "Raspberry Pi NVR je nainstalováno a odesílání e-mailů funguje.\n\nAtmovio: http://%s\n" % os.environ["NVR_IP"])
PYEOF
  then ok "Testovací e-mail odeslán na $MAIL_TO"; MAIL_NOTE="funkční, testovací e-mail odeslán na $MAIL_TO"
  else warn "Testovací e-mail se nepodařilo odeslat (nejspíš špatné heslo k SMTP). Instalace pokračuje – heslo opravíš a otestuješ v Atmovio → E-mail."; MAIL_NOTE="NEFUNKČNÍ – oprav heslo k SMTP v Atmovio → E-mail a klikni na test"
  fi
fi

# ----------------------------------------------------------------------------- 8. souhrn
IP=$(hostname -I | awk '{print $1}')
HOSTN=$(hostname)
{
echo "==================== RPi 5 NVR – přístupy ($(date '+%d.%m.%Y %H:%M')) ===================="
echo
echo "  Atmovio (administrace – funguje i na mobilu)     : http://$IP        (nebo http://$HOSTN.local)"
echo "      heslo: to, které jsi zadal při instalaci"
echo
echo "  Frigate (živý náhled, záznamy, export videa)      : https://$IP:8971"
echo "      uživatel: admin"
echo "      heslo:    stejné jako Atmovio $FRIGATE_PW_NOTE"
echo
echo "  Portainer (Docker kontejnery)                     : https://$IP:9443"
echo "      uživatel: admin      heslo: stejné jako Atmovio"
echo
echo "  Cockpit (systém, síť/statická IP, disky, updaty)  : https://$IP:9090"
echo "      přihlášení systémovým uživatelem (${SUDO_USER:-pi}) a jeho heslem"
echo
echo "  Prohlížeč bude u HTTPS adres hlásit nedůvěryhodný certifikát (self-signed) – potvrď výjimku."
echo
echo "  E-mailová upozornění: $MAIL_NOTE"
echo "  Záznamy: $DATA_MNT/frigate   (retence $RETAIN_DAYS dní)"
[[ -n "$DISK_NOTE" ]] && echo "  $DISK_NOTE"
echo "  Konfigurace Frigate: $FRIGATE_CFG_DIR/config.yml"
echo "  Log instalace: $LOG"
echo
echo "  Další kroky:"
echo "   1) http://$IP → Kamery → Vyhledat kamery v síti (nebo zadej RTSP ručně); Frigate se sám restartuje"
echo "   2) http://$IP → Upozornění → SMTP + test, hlídání výpadků kamer"
echo "   3) http://$IP → AI obloha → klíč (návod 'Jak získat AI zdarma' přímo na stránce), jevy, zapnout"
echo "   4) vzdálená kamera: http://$IP → Síť a VPN → Ping na její IP; když neprojde, vlož WireGuard konfiguraci"
echo "=========================================================================================="
} | tee "$INFO_FILE"
chmod 600 "$INFO_FILE"
echo
ok "Hotovo. Tento souhrn je uložen v $INFO_FILE"
