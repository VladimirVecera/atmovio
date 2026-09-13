# REST API (read-only)

*[Česky](cs/api.md)*

SkyWatch exposes a small JSON API for dashboards, Home Assistant, scripts – anything that wants to *read* state.
It cannot change settings (that is what the web UI is for).

## API keys

**Nastavení → Systém → API pro jiné systémy → Vytvořit klíč.** The key (`sw_…`) is shown once; only a hash is stored.
Revoke a key on the same page. Send it as:

```
Authorization: Bearer sw_xxxxxxxx
```
(`X-API-Key: …` header or `?api_key=…` query parameter also work; prefer the header.)
A browser session logged into SkyWatch can call the API too, which is handy for trying it out.

The API is served over plain HTTP inside your LAN/VPN – do not expose it to the internet.

## Endpoints

| Method + path | Returns |
|---|---|
| `GET /api/v1/status` | NVR status: version, Frigate, storage, AI usage, sun times, system, current outages |
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
curl -s -H "Authorization: Bearer sw_…" http://192.168.1.20/api/v1/status | jq .
curl -s -H "Authorization: Bearer sw_…" "http://192.168.1.20/api/v1/detections?limit=5" | jq '.detections[] | {ts, camera_label, score, phenomenon}'
curl -s -H "Authorization: Bearer sw_…" http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg -o now.jpg
```

`status`:

```json
{
  "ok": true, "version": "3.1", "time": "2026-09-13T19:12:00+02:00",
  "frigate": {"online": true, "version": "0.17.2"},
  "storage": {"mode": "recording", "reason": "", "disk_pct": 41, "disk_free": "1.2 TB", "disk_total": "1.8 TB", "retain_days": 14},
  "ai": {"enabled": true, "status": "běží, …", "used_today": 84, "daily_limit": 500, "cameras": ["zahrada"], "daytime": true},
  "sun": {"dawn": "05:04", "sunrise": "06:17", "sunset": "19:09", "dusk": "20:21"},
  "system": {"hostname": "rpi5", "temp": "52 °C", "uptime": "3 d 4 h", "load": "0.4 0.3 0.3", "ip": "192.168.1.20", "ip_vpn": "10.10.10.5", "mem": "1.1Gi / 7.9Gi"},
  "outages": {"cam:chata": 340}
}
```

`detections[]`:

```json
{"id": 123, "ts": "2026-09-13T19:12:03", "camera": "zahrada", "camera_label": "Zahrada – západ",
 "score": 9, "phenomenon": "Červánky", "phenomena": ["cervanky"], "description": "…", "notified": true,
 "error": null, "exported": true, "image_url": "http://192.168.1.20/api/v1/detections/123/image.jpg",
 "detail_url": "http://192.168.1.20/detection/123"}
```

## Home Assistant example

```yaml
rest:
  - resource: http://192.168.1.20/api/v1/status
    headers:
      Authorization: "Bearer sw_…"
    scan_interval: 60
    sensor:
      - name: SkyWatch AI requests today
        value_template: "{{ value_json.ai.used_today }}"
      - name: SkyWatch disk used
        value_template: "{{ value_json.storage.disk_pct }}"
        unit_of_measurement: "%"
    binary_sensor:
      - name: SkyWatch recording
        value_template: "{{ value_json.frigate.online and value_json.storage.mode == 'recording' }}"

camera:
  - platform: generic
    name: Zahrada
    still_image_url: http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg?api_key=sw_…
```

## Errors

`401 {"error": "unauthorized"}` – missing or revoked key. `404` – unknown id/camera. `503` – Frigate or disk not available (snapshots, images).
