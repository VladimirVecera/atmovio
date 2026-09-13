<p align="center">
  <img src="docs/img/logo.svg" width="96" alt="SkyWatch logo"><br>
  <b>SkyWatch</b><br>
  <sub>Raspberry Pi 5 NVR with AI sky watching – one-command install, plain-language admin</sub>
</p>

<p align="center">
  <a href="README.cs.md">🇨🇿 Česky</a> ·
  <a href="docs/install.md">Install</a> ·
  <a href="docs/cameras.md">Cameras</a> ·
  <a href="docs/ai.md">AI sky watching</a> ·
  <a href="docs/webhook.md">Webhook</a> ·
  <a href="docs/api.md">REST API</a> ·
  <a href="docs/vpn.md">VPN</a> ·
  <a href="docs/faq.md">FAQ</a>
</p>

SkyWatch turns a **Raspberry Pi 5** with a USB hard drive into a home video recorder for IP cameras
(**[Frigate](https://frigate.video)** does the recording) and adds something Frigate does not do:
it watches the **sky** through your cameras and tells you when something beautiful or dangerous is
happening – red sunsets, shelf clouds, mammatus, rainbows, halos, lightning, fog…

It is built for people who are not sysadmins. Everything is in one web page, in plain language,
and the installer asks only what it really needs.

> The web UI is currently in **Czech**. Documentation is in English and Czech. An English UI is on the
> roadmap – contributions welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## What you get

| | |
|---|---|
| **Recording** | Continuous H.264/H.265 recording of any RTSP camera without re-encoding, playback and clip export via Frigate. Retention in days. Works without the HDD too (live view only). |
| **Camera setup that just works** | Finds cameras on the LAN (ONVIF + port scan), tests every stream for *real video frames* before saving, fixes wrong ports, explains errors in human words. Remote cameras over WireGuard. |
| **AI sky watching** | Every few minutes a snapshot goes to a vision model (Google Gemini free tier by default; Groq, OpenAI, Anthropic, Ollama also supported). The model returns a 0–10 score and the phenomena it sees; you choose which ones to be alerted about. Watches from dawn to dusk (nautical twilight), skips unchanged or dark frames to save your daily quota. Episodes and cooldowns prevent alert storms. |
| **Alerts** | E-mail (SMTP) and/or a **webhook to your own website** (status + snapshots every minute, alerts with the AI image). Camera / recording / disk outage alerts with recovery. |
| **Videos** | Cut a clip around any detection (−N/+M minutes) or let SkyWatch do it **automatically after each alert**; watch it in the browser at up to 120×, download MP4, optional 25× timelapse export. |
| **Per-camera page** | Everything about one camera in one place: live view, status, AI toggles, detections, videos, stream settings. |
| **Ops for humans** | Disk health (SMART) with plain-language warnings, storage guard that keeps the system alive when the HDD disappears, logs with search, one-file updater with automatic rollback. |
| **Integrations** | Read-only **REST API** with API keys (Home Assistant, dashboards, scripts) and a documented outbound webhook. |

## Quick start

Requirements: Raspberry Pi 5 (4 GB+), Raspberry Pi OS Lite 64-bit (Debian 12/13) on SSD or SD card,
optionally a USB 3 hard drive for recordings, wired Ethernet, one or more RTSP cameras.

```sh
# on your computer
scp install.sh pi@<RPI-IP>:
ssh pi@<RPI-IP>
sudo bash install.sh
```

The installer asks for an admin password (min. 12 characters), retention, time zone, optional SMTP and
which disk to use for recordings (existing ext4 is reused, formatting requires typing `SMAZAT`). It installs
Docker, Frigate 0.17, Portainer, Cockpit and SkyWatch. Then open `http://<RPI-IP>` and follow the
4-step checklist on the dashboard: add cameras → disk → alerts → AI key.

Updating later: `scp update-skywatch.sh pi@<RPI-IP>: && ssh pi@<RPI-IP> sudo bash update-skywatch.sh`
(backs up, verifies, rolls back on failure).

Full guide: [docs/install.md](docs/install.md).

## Services after install

| Service | URL | Purpose |
|---|---|---|
| SkyWatch | `http://IP` | the admin you actually use |
| Frigate | `https://IP:8971` | recordings player, clip export (user `admin`, same password) |
| Cockpit | `https://IP:9090` | system: network, disks, updates |
| Portainer | `https://IP:9443` | containers (rarely needed) |

SkyWatch uses plain HTTP on purpose – run it in your LAN or behind your router's VPN. **Never expose port 80 to the internet.**
For remote viewing use the [webhook](docs/webhook.md) (push to your website) or a VPN.

## How the AI part works

1. From dawn to dusk (configurable: civil / nautical / astronomical twilight or fixed minutes) SkyWatch grabs one full-resolution frame per camera every *N* minutes (faster around sunrise/sunset).
2. Dark frames and frames that did not change since the last evaluation are skipped without an AI call.
3. The model receives a catalogue of phenomena and returns a score and what it sees. Detections at or above your threshold trigger an alert – once per *episode* (a 40-minute sunset is one alert, not ten).
4. Alerts go to e-mail and/or your webhook with the snapshot. Optionally a video clip is exported automatically.
5. Everything is visible in **Historie** (history), per-camera pages and the dashboard; daily statistics are kept independently of history clean-up.

Free tier of Google Gemini is enough for a couple of cameras (hundreds of requests/day). See [docs/ai.md](docs/ai.md).

## Repository layout

```
install.sh              built installer (do not edit – generated)
update-skywatch.sh      built updater (generated)
src/
  build.sh              builds the two scripts above from the templates + app
  install.template.sh   installer source
  update.template.sh    updater source
  skywatch/
    app.py              the whole web app (FastAPI + Jinja templates inside)
    storage_guard.py    HDD watchdog / Frigate live-vs-recording switch
    static/             CSS + JS (Pico CSS, Alpine.js vendored at install time)
docs/                   documentation (en) and docs/cs (Czech)
examples/webhook-php/   drop-in PHP receiver + status page for the webhook
```

Development: `bash src/build.sh` after any change in `src/`, `bash src/build.sh --check` verifies that the built
scripts match. Run `python3 -m py_compile src/skywatch/app.py`; a lightweight local run is possible with
`SKYWATCH_DIR=/tmp/sw SKYWATCH_PORT=8099 SKYWATCH_ADMIN_PASSWORD=… python3 src/skywatch/app.py` (Frigate features will show as offline).

## Contributing

Issues and pull requests are welcome – bug reports with logs (**Logy** page → download), camera models that
did or did not work, translations, new phenomena, integrations. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Vladimír Večeřa. Frigate, Pico CSS and Alpine.js are separate projects under their own licenses.
