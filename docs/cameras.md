# Cameras

*[Česky](cs/kamery.md)*

## Adding a camera

**Kamery (Nastavení → Kamery) → Vyhledat kamery v síti** is the easiest way:

1. Enter the camera's **user name and password** (the ones you use in the camera's own web page). Without them most
   cameras refuse to stream (HTTP 401) and cannot be verified.
2. Atmovio scans the LAN (ONVIF discovery + TCP scan of ports 554/80/8000/8080/8554 in the given subnets; you can add a
   remote subnet reachable over VPN, e.g. `10.10.10.0/24`).
3. For each device it reads the stream profiles over ONVIF and **tests every RTSP URL for real decoded video frames**
   – exactly the way Frigate will read it. URLs without video are dropped; a wrong port is corrected automatically.
4. Confirm the name and click **Přidat kameru**. Frigate restarts (20–40 s) and the camera appears on the overview.

Manual add (**Přidat kameru ručně**) needs the RTSP URLs. Typical paths:

| Brand | Main stream | Sub stream |
|---|---|---|
| Hikvision / HiLook / Annke | `/Streaming/Channels/101` | `/Streaming/Channels/102` |
| Dahua / Imou / Amcrest | `/cam/realmonitor?channel=1&subtype=0` | `…subtype=1` |
| Reolink | `/h264Preview_01_main` | `/h264Preview_01_sub` |
| TP-Link Tapo / Vigi | `/stream1` | `/stream2` |
| Uniview | `/media/video1` | `/media/video2` |
| Axis | `/axis-media/media.amp` | |

Full URL: `rtsp://user:password@192.168.1.50:554/stream1`. Special characters in the password must be URL-encoded
(`@` → `%40`, space → `%20`) – or leave the URL without credentials and fill user/password into the form fields.

## Main vs. sub stream

- **Main stream** (full resolution) is **recorded as is** – no re-encoding, so the CPU stays cool. H.264 and H.265 both work.
- **Sub stream** (low resolution, e.g. 640×360) is used for the live preview and for Frigate's detect pipeline. Optional but recommended: without it Frigate decodes the full-resolution stream for preview.
- AI snapshots are taken from the main stream (one full-resolution frame every few minutes).

Recommended camera settings: main stream H.264/H.265 constant bitrate 2–6 Mbit/s, 15–20 fps, key frame interval = fps (1 s);
sub stream 640×360 at 5–10 fps. Disable audio if you do not need it (some cameras only send AAC over the main profile and confuse go2rtc).

## The per-camera page

Click any camera (overview, Kamery, history…) to open `/camera/<id>`:

- large auto-refreshing snapshot, **live MJPEG** on demand (button), full-resolution frame;
- status: fps, recording of the last 10 minutes on disk, IP and path (LAN / VPN), last AI evaluation, recent outages;
- AI toggles for this camera (watch / automatic video after alert) and a "test AI now" button;
- last alerts and videos from this camera;
- stream settings (name, URLs, credentials), link to Frigate masks/zones, remove camera.

**Kamery** (main menu) shows all cameras as large snapshots; **▶ Živě všechny kamery** opens live MJPEG for all of them.

## Remote cameras (VPN)

A camera in another location (a cottage, a parent's house) is added the same way, using its address in the remote
network. The Pi must reach that network: either your router already has a site-to-site VPN, or you paste a WireGuard
client config into **Nastavení → Síť a VPN** – see [vpn.md](vpn.md).

## Removing / editing

Per-camera page → Nastavení kamery → **Uložit změny** re-verifies the streams and restarts Frigate; Frigate masks and
zones are kept. **Odebrat kameru** removes it from recording and AI; recordings on the disk stay until retention deletes them.

## Known quirks

- Cameras that only speak RTSP over port 80 or 8554: discovery tries those ports and fixes the URL.
- Some cameras (Tapo, older Xiaomi) do not negotiate with go2rtc; Atmovio switches to an ffmpeg source automatically and tells you (no audio in that mode).
- ONVIF discovery is multicast – it only finds cameras in the Pi's own LAN. Use the subnet scan for VPN networks.
- If a camera shows **BEZ SIGNÁLU** after an IP change, edit the URL on the camera page; Atmovio does not track DHCP changes. Give cameras fixed IPs.
