# Webhook – push status and alerts to your own website

*[Česky](cs/webhook.md)*

Atmovio lives in your LAN. To see your cameras and alerts from anywhere without opening ports, Atmovio
**pushes** data to a URL you own: a heartbeat with status and small previews every minute, and every alert with the AI snapshot.
Your website stores and shows them (and can forward e-mails). The website never controls the Pi.

A ready-to-use receiver in PHP is in [`examples/webhook-php`](../examples/webhook-php) – three files, no database.

## Setup in Atmovio

**Nastavení → Upozornění → Kam chodí upozornění: vlastní web (webhook)**

- **Adresa přijímače** – the exact final URL (`https://example.com/atmovio/webhook.php`). Avoid redirects (`www`, trailing slash) – a redirect turns the POST into a GET.
- **Token** – a long random secret, the same string you put into the receiver.
- Advanced: name of this NVR, whether to send thumbnails.
- **Uložit a otestovat spojení** sends `ping` and a `test` event.

The last error, if any, is shown on the page and in the **Logy** page.

## Protocol

`POST <url>` with `Content-Type: application/json`, headers:

```
Authorization: Bearer <token>
X-Token: <token>          (same value – for hosts that strip Authorization)
User-Agent: Atmovio/<version>
```

Response must be JSON. `{"ok": true}` = accepted. Anything else (or non-2xx) is treated as failure and shown to the user.
Timeouts: 20 s (ping), 30 s (heartbeat), 40 s (event). Body up to ~3 MB (images are base64 JPEG).

### `ping`

```json
{"type": "ping"}
```
Expected response: `{"ok": true, "nvr": "name to display", "server_time": "2026-09-13T19:12:00+02:00"}`.

### `heartbeat` – once per minute

```json
{
  "type": "heartbeat",
  "nvr": "Raspberry Pi 5 NVR", "version": "3.1",
  "atmovio_url": "http://192.168.1.20", "frigate_url": "https://192.168.1.20:8971",
  "status": {
    "frigate_online": "1", "frigate_version": "0.17.2",
    "storage_mode": "recording", "disk_pct": 41, "disk_free": "1.2 TB",
    "ai_enabled": "1", "ai_status": "běží, poslední tick 19:11:40, dnes 84/500 dotazů",
    "hostname": "rpi5", "temp": "52 °C", "uptime": "3 d 4 h", "load": "0.4 0.3 0.3"
  },
  "cameras": [
    {"name": "zahrada", "label": "Zahrada – západ", "ip": "192.168.1.50", "via": "LAN",
     "online": true, "fps": 15.0, "ai": true, "thumb": "<base64 JPEG, ≤190 kB, height 240 px>",
     "last_eval": {"id": 812, "ts": "2026-09-14T18:43:10", "score": 8, "phenomenon": "Duha a červánky",
                   "description": "Na obloze je vidět výrazná duha …", "notified": true}}
  ]
}
```
`last_eval` (since 4.4.3) is the newest AI evaluation of that camera – also when it scored below the threshold and
nothing was sent – so a website can show what the AI last said about the current view. Omitted for cameras the AI
does not watch or that have no evaluation yet.
`storage_mode`: `recording` | `legacy` | `live` (no disk) | other values = not ready. `via`: `LAN` | `VPN` | `?`.
`thumb` is omitted when thumbnails are disabled or the camera is offline.

Since 3.3 the heartbeat also carries **`api`** – a snapshot of everything the [REST API](api.md) returns, with identical
fields, so a website that cannot reach the Pi (LAN/VPN only) can still show it:

```json
"api": {
  "status":     { … same as GET /api/v1/status … },
  "cameras":    [ … same as GET /api/v1/cameras … ],
  "detections": [ … same as GET /api/v1/detections?limit=30 (notified only) …, "thumb": "<base64 JPEG, height 240 px>" ],
  "videos":     [ … same as GET /api/v1/videos …, "thumb": "<base64 JPEG>" ],
  "events":     [ … same as GET /api/v1/events?limit=30 … ]
}
```
`thumb` is sent only for detections/videos the Pi has not sent yet since it started (max. 3 + 3 per heartbeat), so store
them on your side keyed by `id`; items that disappear from the lists were deleted on the Pi. `api` is `null` when the
snapshot could not be built. All `*_url` links point to the Pi and work only at home / over VPN.

### `event`

```json
{
  "type": "event",
  "kind": "sky",                       // sky | outage | recovery | system | test
  "camera": "zahrada", "camera_label": "Zahrada – západ",
  "subject": "[Atmovio] Zahrada – západ: Červánky (9/10)",
  "message": "Kamera: …\nČas: 13.09.2026 19:12\nSkóre: 9/10\nJev: Červánky\n\n<AI description>…",
  "score": 9,                          // sky events only
  "phenomena": ["cervanky"],           // ids from the catalogue, sky events only
  "ts": "2026-09-13T19:12:03",
  "image": "<base64 JPEG, full resolution>",   // when a snapshot exists
  "link": "http://192.168.1.20/detection/123",  // detail in Atmovio (LAN/VPN only)
  "frigate_url": "https://192.168.1.20:8971"
}
```
Response: `{"ok": true}`; optionally `"emailed": true` if your site forwarded the event by e-mail – Atmovio then shows
"web + e-mail z webu" in the detection note.

Phenomenon ids: `cervanky, shelf, mammatus, beranci, bourka, blesk, duha, halo, paprsky, lentikularni, mlha, tornado,
wallcloud, rollcloud, asperitas, kroupy, prehanka, virga, dest, snezeni, jine`.

## Delivery rules

- If the webhook is configured and succeeds, the alert is marked delivered ("web"). If e-mail (SMTP) is also configured it is sent too.
- If the webhook fails and SMTP is configured, the e-mail is the fallback; the failure is logged.
- Outage alerts (`outage` / `recovery`) follow the same path.

## Writing your own receiver

Any language works – it is one HTTPS endpoint that accepts JSON. Checklist:

1. compare the token with a constant-time compare, respond `401` otherwise;
2. limit the body size (3 MB), validate that `image`/`thumb` decode to JPEG (`FF D8` header);
3. store the last heartbeat and the last N events; serve images through your own script so the storage stays private;
4. answer `{"ok": true}` quickly (do the e-mail sending after responding, or keep it short);
5. show a "last seen" time and mark the NVR offline when no heartbeat arrived for 3 minutes.
