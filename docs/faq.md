# FAQ

*[Česky](cs/faq.md)*

**Does it need the internet?** Recording no. AI sky watching yes (hosted models) unless you use Ollama on the Pi. Alerts by e-mail/webhook yes.

**How much disk?** Bitrate of all cameras in Mbit/s × 10.8 ≈ GB per day. Four 4 Mbit/s cameras ≈ 173 GB/day ≈ 1.2 TB per week.
Set retention accordingly (installer / Záznamy a disk). Exported videos have their own retention (Videa).

**Can I use an SD card only?** Yes for the system; recordings need the USB HDD (SD cards die from constant writes). Without a disk Atmovio runs in live-view mode.

**Does it detect people/cars?** No – Frigate object detection is intentionally off (no accelerator on the Pi). Atmovio is about the sky. You can enable detection in Frigate yourself, at the cost of CPU.

**Why HTTP without a certificate?** It runs in your LAN; a self-signed certificate would only produce browser warnings. Use a VPN for remote access; never port-forward.

**Which cameras work?** Anything with RTSP H.264/H.265. See [cameras.md](cameras.md) and the *Cameras* issues on GitHub for reports.

**How many cameras can a Pi 5 handle?** Recording is copy-only, so the limit is the preview decoding of sub streams: 4–6 cameras with 640×360 sub streams are fine. Watch the temperature on the dashboard.

**Is my video sent anywhere?** Only single snapshots go to the AI provider you configured, and to your own webhook if enabled. Recordings never leave the Pi.

**Free AI limits?** Google Gemini Flash-Lite free tier is a few hundred requests/day; Atmovio stops at your configured daily limit and skips unchanged/dark frames.

**How do I back up?** `/opt/nvr/atmovio/config.json` (settings), `/opt/nvr/frigate/config/config.yml` (cameras), `/etc/wireguard/wg-remote.conf` (VPN). Recordings are on the HDD.

**Update went wrong?** The updater rolls back automatically; backups are in `/opt/nvr/atmovio/backups/`. Manual restore: copy `app.py` from a backup and `systemctl restart atmovio`.

**Where are the logs?** Page **Logy** (download button), or `journalctl -u atmovio -n 200`.

**English UI?** Not yet – documentation is bilingual, the UI is Czech. Contributions for an i18n layer are welcome.
