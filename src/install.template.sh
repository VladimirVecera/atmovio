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
__ATMOVIO_APP__
ATMOVIO_APP_EOF
cat > "$SKY_DIR/storage_guard.py" <<'ATMOVIO_STORAGE_EOF'
__ATMOVIO_STORAGE__
ATMOVIO_STORAGE_EOF
cat > "$SKY_DIR/metrics.py" <<'ATMOVIO_METRICS_EOF'
__ATMOVIO_METRICS__
ATMOVIO_METRICS_EOF

cat > "$SKY_DIR/requirements.txt" <<'ATMOVIO_REQUIREMENTS_EOF'
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
