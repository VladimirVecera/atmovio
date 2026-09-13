# Installation

*[Česky](cs/instalace.md)*

## What you need

- **Raspberry Pi 5** (4 GB RAM or more), official 27 W power supply. A Pi 4 may work but is not tested.
- **Raspberry Pi OS Lite 64-bit** (Debian 12 "bookworm" or 13 "trixie") freshly written with Raspberry Pi Imager.
  In Imager set: hostname, user `pi` (or any), password, **enable SSH**. Boot from SSD (recommended) or SD card.
- **Wired Ethernet.** Wi-Fi works, but cameras stream continuously – don't.
- **USB 3 hard drive** for recordings (2 TB+ recommended). Externally powered or with a good USB enclosure.
  Without a disk everything installs too, only recording and AI snapshots are paused ("live view only").
- One or more **IP cameras with RTSP** (H.264 or H.265). Almost every Hikvision/HiLook, Dahua/Imou, Reolink, Tapo,
  Uniview, Axis or generic ONVIF camera qualifies. See [cameras.md](cameras.md).

## Install

1. Download `install.sh` from [Releases](https://github.com/VladimirVecera/atmovio/releases) (or from the repository root).
2. Copy it to the Pi and run it as root **from an interactive terminal** (it asks questions; `curl | bash` is refused):

   ```sh
   scp install.sh pi@192.168.1.20:
   ssh pi@192.168.1.20
   sudo bash install.sh
   ```

3. Answer the questions:

   | Question | Notes |
   |---|---|
   | Admin password (twice) | Min. 12 characters. Used for Atmovio, Portainer and Frigate (`admin`). **Nothing is preset.** |
   | Recording retention (days) | 1–60. Frigate deletes older recordings automatically. |
   | Time zone | default `Europe/Prague` |
   | SMTP server | Enter = skip. You can set e-mail later in the web UI, or use the webhook instead. |
   | Disk for recordings | Lists USB disks that are not the system disk. An existing ext4 file system is used as is; formatting the whole disk requires typing `SMAZAT` (erase). `0` = continue without recording. |

4. Wait. Docker, Frigate (`0.17.2`), Portainer, Cockpit and Atmovio are installed and started (5–15 minutes depending on the internet connection).
5. At the end the script prints the addresses. Credentials are also stored in `/opt/nvr/INSTALL-INFO.txt` (root only).
6. Open `http://<IP>` and log in. The dashboard shows a **4-step checklist**: cameras → disk → alerts → AI key.

## After install

| Where | What |
|---|---|
| `http://IP` | **Atmovio** – the admin: Overview, Cameras, Recordings & disk, AI history, Videos, Settings |
| `https://IP:8971` | **Frigate** – recordings timeline, clip export. User `admin`, same password. Self-signed certificate – accept the browser warning. |
| `https://IP:9090` | **Cockpit** – Raspberry Pi OS: network (static IP), updates, users, disks. Log in with the OS user. |
| `https://IP:9443` | **Portainer** – Docker containers. Rarely needed. |

Set a **static IP** for the Pi (in your router's DHCP or in Cockpit → Networking), otherwise the address changes and your bookmarks break.

## Where things live on the Pi

```
/opt/nvr/                     docker-compose.yml, INSTALL-INFO.txt
/opt/nvr/frigate/config/      config.yml (Frigate – edited by Atmovio), live copy, database
/opt/nvr/atmovio/            app.py, config.json, atmovio.db, static/, venv, backups/
/mnt/nvr/                     the recordings disk: frigate/recordings, frigate/exports, atmovio snapshots
/etc/wireguard/wg-remote.conf VPN client config (if used)
```

Services: `atmovio.service` (web app, port 80), `nvr-storage.service` (disk guard, starts Frigate), `docker`.
Logs: **Logy** page in Atmovio; `journalctl -u atmovio`, `journalctl -u nvr-storage`.

## Update

**From the web UI (recommended):** Atmovio checks [GitHub Releases](https://github.com/VladimirVecera/atmovio/releases)
once a day (a single request; nothing is installed automatically) and shows a banner on the dashboard when a newer
version exists. Open **Nastavení → Systém → Aktualizace**, read what is new and click **Nainstalovat**. Atmovio downloads
`update-atmovio.sh` from the release, verifies its SHA-256 against the release's `SHA256SUMS`, and runs it as a separate
systemd unit (so it survives the restart of Atmovio itself); the page shows progress and the result. Recording keeps running;
the web UI is unavailable for about a minute. The daily check can be turned off on the same page.

**Manually over SSH** (same script, same result – useful when the Pi has no internet access):

```sh
scp update-atmovio.sh pi@192.168.1.20:
ssh pi@192.168.1.20
sudo bash update-atmovio.sh
```

The updater builds a new Python environment, verifies the app imports, backs up the old app + config + environment
into `/opt/nvr/atmovio/backups/<stamp>/`, switches, and checks the HTTP health endpoint. If anything fails it rolls
back automatically. Only the two most recent backups are kept. Configuration (`config.json`), cameras and recordings are untouched.

Frigate itself is pinned to `0.17.2` in `/opt/nvr/docker-compose.yml`; upgrading Frigate is a manual step
(read the [Frigate upgrade notes](https://docs.frigate.video/frigate/updating/), then Systém → Aktualizovat kontejnery).

## Uninstall

```sh
sudo systemctl disable --now atmovio nvr-storage
cd /opt/nvr && sudo docker compose down
sudo rm -rf /opt/nvr
# optionally: remove the /mnt/nvr line from /etc/fstab, apt remove docker-ce cockpit
```

## Troubleshooting

- **"Atmovio už je nainstalován"** – the installer refuses to overwrite an existing `config.json`. Use the updater, or remove `/opt/nvr` for a clean start.
- **Frigate does not start** – Overview shows a red banner with a "fix configuration and restart" button; details in Logy → Frigate.
- **The disk is not detected** – Záznamy a disk page lists candidates; `lsblk` on the Pi shows whether the OS sees it at all (USB power!).
- **Time in logs is wrong** – time zone is set during install; change it in Cockpit and restart.
