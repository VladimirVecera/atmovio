# Hardware

*[Česky](cs/hardware.md)*

## Supported computer

| | |
|---|---|
| **Raspberry Pi 5** – 4 GB minimum, **8 GB recommended** | the only tested and supported board. The installer requires 64-bit ARM (`aarch64`) and warns if the model is not a Pi 5. |
| Raspberry Pi 4 | not supported: Frigate 0.17 runs, but sub-stream decoding for previews and the AI snapshots is CPU-bound and the Pi 4 has USB 3 on a slower bus. If you try it, expect 1–2 cameras and report results in a GitHub issue. |
| x86 / other SBCs | not supported (the installer, disk picker and storage guard are written for Raspberry Pi OS). |

Why a Pi 5: recording is **copy-only** (Frigate stores the camera's own H.264/H.265 stream, no re-encoding), so the CPU
is mainly used for decoding the small sub streams for live previews and for one full-resolution frame per camera every few minutes
for the AI. A Pi 5 handles 4–6 cameras with 640×360 sub streams comfortably; watch the temperature on the dashboard.

## What you need

| Part | Requirement | Notes |
|---|---|---|
| **OS** | Raspberry Pi OS **Lite 64-bit** (Debian 12 or 13) | Desktop version works too but is not needed. |
| **System disk** | NVMe/USB SSD recommended; SD card (A2, 32 GB+) works | Only the OS, Docker images (~2 GB) and Atmovio's small database live here. |
| **Recordings disk** | **USB 3 hard drive**, ext4 | The installer finds it, never touches the system disk, reuses an existing ext4 or formats it after you type `SMAZAT`. Recordings are the only thing on it; when it disappears Atmovio keeps running in live-view mode and alerts you. |
| **Power supply** | the official **27 W** Pi 5 supply | Needed for a bus-powered 2.5" HDD; otherwise use a self-powered drive. Under-powered Pis show as random disk drop-outs. |
| **Cooling** | active cooler or a case with a fan | Continuous decoding keeps the SoC warm; the dashboard shows the temperature and warns at 80 °C. |
| **Network** | **wired Ethernet** | Cameras stream constantly; Wi-Fi drop-outs show up as camera outages. |
| **Cameras** | any IP camera with **RTSP** (H.264 or H.265), ONVIF preferred | Main stream for recording, sub stream (≈640×360) for previews. Auto-discovery uses ONVIF + port scan; every stream is verified for real frames before it is saved. See [cameras.md](cameras.md). |
| **Remote camera** | reachable over **WireGuard** | Atmovio manages the tunnel and protects your LAN route. See [vpn.md](vpn.md). |
| **Internet** | for AI and alerts | Recording works offline. AI needs a hosted model (or Ollama locally, slow); e-mail/webhook need outbound HTTPS/SMTP. |

## Sizing the recordings disk

Copy-only recording means the disk grows exactly by the cameras' bitrate: **Mbit/s of all cameras × 10.8 ≈ GB per day**.

| Cameras | Typical bitrate | Per day | 7 days | 14 days |
|---|---|---|---|---|
| 1 × 1080p H.265 | 2 Mbit/s | 22 GB | 150 GB | 300 GB |
| 2 × 1080p H.264 | 2 × 4 Mbit/s | 86 GB | 600 GB | 1.2 TB |
| 4 × 2K H.265 | 4 × 4 Mbit/s | 173 GB | 1.2 TB | 2.4 TB |

Retention is set in days (installer, later *Záznamy a disk*); Frigate deletes the oldest hours automatically. Exported clips
have their own retention on the *Videa* page.

## Disk health

Atmovio reads S.M.A.R.T. every hour (system disk and the recordings disk, USB bridges included) and shows plain-language
warnings: a constant number of pending sectors is treated as a one-off (typically a hard power-off), a growing number turns the
banner red. A `storage guard` service makes sure Frigate starts only after the HDD is verified writable, so a missing or dying disk
can never fill up the system SSD.

## Tested setup

Raspberry Pi 5 8 GB, Raspberry Pi OS Lite 64-bit on a USB SSD, 4 TB USB 3 HDD (WD Red), two ONVIF cameras (one on the LAN,
one behind a WireGuard site-to-site tunnel), Google Gemini free tier for the AI. Idle load ≈ 0.5, temperature 40–50 °C with an active cooler.
