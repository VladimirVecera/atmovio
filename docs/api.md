# REST API (read-only)

*[Česky](cs/api.md)*

Atmovio exposes a small JSON API for dashboards, Home Assistant, scripts – anything that wants to *read* state.
It cannot change settings (that is what the web UI is for).

## Two directions

| | Who calls whom | Use it when |
|---|---|---|
| **REST API** (this page) | *your* system → Atmovio, `GET http://<pi>/api/v1/…` with an API key | the caller is inside your LAN/VPN: Home Assistant, a dashboard, a script on your PC |
| **Webhook** ([webhook.md](webhook.md)) | Atmovio → *your* URL, `POST` every minute + on every alert | the receiver is on the internet (a web hosting) and cannot reach the Pi. Since 3.3 the heartbeat carries `api` – the same data as every endpoint below – so the website shows everything the API offers, plus alerts with the snapshot. Configured in **Nastavení → Upozornění → vlastní web**. |

Both use the same field names, so code written for one works for the other.

## API keys

**Nastavení → Systém → API pro jiné systémy → Vytvořit klíč.** The key (`at_…`; keys created by SkyWatch 3.x start with `sw_` and keep working) is shown once; only a hash is stored.
Revoke a key on the same page. Send it as:

```
Authorization: Bearer at_xxxxxxxx
```
(`X-API-Key: …` header or `?api_key=…` query parameter also work; prefer the header.)
A browser session logged into Atmovio can call the API too, which is handy for trying it out.

The API is served over plain HTTP inside your LAN/VPN – do not expose it to the internet.

## Endpoints

| Method + path | Returns |
|---|---|
| `GET /api/v1/status` | NVR status: version, Frigate, storage, AI usage, sun times, system, current outages, available update (`update`) |
| `GET /api/v1/cameras` | list of cameras with online/fps/IP/path, AI flags and snapshot URL |
| `GET /api/v1/cameras/{name}/snapshot.jpg?h=720` | current JPEG frame (height 120–1080) |
| `GET /api/v1/detections?limit=20&camera=&notified=1&min_score=0` | latest AI detections (notified only by default; `notified=0` = all evaluations) |
| `GET /api/v1/detections/{id}` | one detection |
| `GET /api/v1/detections/{id}/image.jpg` | the AI snapshot |
| `GET /api/v1/videos` | exported clips with download URLs |
| `GET /api/v1/videos/{id}/download` | MP4 |
| `GET /api/v1/events?limit=20` | outage / recovery / sky events log |
| `GET /api/health` | `{"ok": true, …}` without authentication (for monitoring) |

### Examples

```sh
curl -s -H "Authorization: Bearer at_…" http://192.168.1.20/api/v1/status | jq .
curl -s -H "Authorization: Bearer at_…" "http://192.168.1.20/api/v1/detections?limit=5" | jq '.detections[] | {ts, camera_label, score, phenomenon}'
curl -s -H "Authorization: Bearer at_…" http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg -o now.jpg
```

`status`:

```json
{
  "ok": true, "version": "3.4", "time": "2026-09-13T19:12:00+02:00",
  "frigate": {"online": true, "version": "0.17.2"},
  "storage": {"mode": "recording", "reason": "", "disk_pct": 41, "disk_free": "1.2 TB", "disk_total": "1.8 TB", "retain_days": 14},
  "ai": {"enabled": true, "status": "běží, …", "used_today": 84, "daily_limit": 500, "cameras": ["zahrada"], "daytime": true, "threshold": 7},
  "sun": {"dawn": "05:04", "sunrise": "06:17", "sunset": "19:09", "dusk": "20:21"},
  "system": {"hostname": "rpi5", "temp": "52 °C", "uptime": "3 d 4 h", "load": "0.4 0.3 0.3", "ip": "192.168.1.20", "ip_vpn": "10.10.10.5", "mem": "1.1Gi / 7.9Gi"},
  "outages": {"cam:chata": 340},
  "update": {"latest": "3.2", "available": false, "checked": "2026-09-13T06:10:00"}
}
```

`detections[]`:

```json
{"id": 123, "ts": "2026-09-13T19:12:03", "camera": "zahrada", "camera_label": "Zahrada – západ",
 "score": 9, "phenomenon": "Červánky", "phenomena": ["cervanky"], "description": "…", "notified": true,
 "error": null, "exported": true, "image_url": "http://192.168.1.20/api/v1/detections/123/image.jpg",
 "detail_url": "http://192.168.1.20/detection/123"}
```

## Field reference

All timestamps are local time of the Pi (`tz` from the installer) in ISO format unless stated. `*_url` links point to the Pi
and work only inside the LAN/VPN (they use the Pi's LAN IP).

### `status`

| Field | Meaning |
|---|---|
| `version`, `time` | Atmovio version, current time |
| `frigate.online`, `frigate.version` | recorder running, Frigate version |
| `storage.mode` | `recording` / `legacy` = recording to HDD, `live` = no disk (live view only), other = not ready; `storage.reason` explains |
| `storage.disk_pct`, `disk_free`, `disk_total`, `retain_days` | recordings disk usage and retention (null without disk) |
| `ai.enabled`, `ai.status` | AI watching on/off and a human-readable status line |
| `ai.used_today`, `ai.daily_limit` | requests to the model today / configured cap (0 = none) |
| `ai.threshold` | alert threshold 0–10 |
| `ai.cameras`, `ai.daytime` | cameras being watched; whether it is inside the dawn–dusk window now |
| `sun.dawn`, `sunrise`, `sunset`, `dusk` | today's times (`HH:MM`) for the configured twilight |
| `system.*` | `hostname`, `temp`, `uptime`, `load`, `ip`, `ip_vpn`, `mem` |
| `outages` | current outages: `{"cam:<name>": seconds, "frigate": seconds, "storage": seconds}` |
| `update.latest`, `update.available`, `update.checked` | newest GitHub release, whether it is newer than `version`, when it was checked |

### `cameras[]`

| Field | Meaning |
|---|---|
| `name`, `label` | Frigate id (ASCII) and the display name |
| `ip`, `via` | camera IP and path: `LAN`, `VPN` (WireGuard) or `?` |
| `online`, `fps`, `outage_s` | receiving frames, current fps, seconds since the outage started (null when online) |
| `ai`, `auto_video` | watched by the AI; automatic clip after an alert enabled |
| `snapshot_url` | current JPEG (`?h=` height 120–1080) |

### `detections[]`

| Field | Meaning |
|---|---|
| `id`, `ts`, `camera`, `camera_label` | detection id, time, camera |
| `score` | 0–10 from the model |
| `phenomenon` | short name of the main phenomenon as written by the model (Czech), or "nic zajímavého" |
| `phenomena` | ids of all detected phenomena (`cervanky`, `shelf`, `mammatus`, `beranci`, `bourka`, `blesk`, `duha`, `halo`, `paprsky`, `lentikularni`, `mlha`, `tornado`, `wallcloud`, `rollcloud`, `asperitas`, `kroupy`, `prehanka`, `virga`, `dest`, `snezeni`, `jine`) |
| `description` | one or two sentences from the model |
| `notified` | an alert was sent (score ≥ threshold, phenomenon selected, episode/cooldown allowed it) |
| `exported` | a clip was cut from this detection |
| `error` | model/parse error text (null normally) |
| `image_url`, `detail_url` | the evaluated snapshot; the detail page in Atmovio (snapshot + playback around it) |

Query parameters: `limit` (1–200), `camera`, `notified` (1 = alerts only, default; 0 = every evaluation), `min_score`.

### `videos[]`

| Field | Meaning |
|---|---|
| `id`, `name`, `camera`, `camera_label` | clip id, name given at export, camera |
| `detection_id` | detection the clip was cut from (null for manual range exports) |
| `start_ts`, `end_ts` | clip range as Unix timestamps; `range` = the same as text |
| `created` | when the export was requested |
| `auto` | cut automatically after an alert |
| `ready`, `in_progress` | MP4 exists / Frigate is still cutting |
| `duration`, `size` | human-readable length and file size |
| `thumb_url`, `download_url` | poster frame; the MP4 (null until `ready`) |

### `events[]`

| Field | Meaning |
|---|---|
| `id`, `ts` | event id, time |
| `kind` | `sky` (alert), `outage`, `recovery`, `system`, `test` |
| `subject`, `message` | the alert subject and body as sent by e-mail/webhook |
| `emailed` | 1 when an e-mail/webhook alert went out |

## Home Assistant example

```yaml
rest:
  - resource: http://192.168.1.20/api/v1/status
    headers:
      Authorization: "Bearer at_…"
    scan_interval: 60
    sensor:
      - name: Atmovio AI requests today
        value_template: "{{ value_json.ai.used_today }}"
      - name: Atmovio disk used
        value_template: "{{ value_json.storage.disk_pct }}"
        unit_of_measurement: "%"
    binary_sensor:
      - name: Atmovio recording
        value_template: "{{ value_json.frigate.online and value_json.storage.mode == 'recording' }}"

camera:
  - platform: generic
    name: Zahrada
    still_image_url: http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg?api_key=at_…
```

## Errors

`401 {"error": "unauthorized"}` – missing or revoked key. `404` – unknown id/camera. `503` – Frigate or disk not available (snapshots, images).
