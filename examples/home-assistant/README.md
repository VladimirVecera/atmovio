# Atmovio + Home Assistant

*[Česky](README.cs.md)*

Atmovio has no custom component – the built-in **REST** integration of Home Assistant is enough,
because every value is one `GET` with an API key. Two files:

| File | Gives you |
|---|---|
| `configuration.yaml` | sensors: AI requests today, disk used, temperature, version (+ `update` attribute); binary sensors: recording, daytime, camera online; a `camera` entity with the live picture; `sensor.atmovio_last_sky_alert` with the last detection (attributes `id`, `ts`, `score`, `camera_label`, `description`, `image_url`, `detail_url`) |
| `automations.yaml` | push notification to your phone with the picture whenever a new alert ≥ 7/10 arrives |

## Setup

1. Atmovio: **Nastavení → Systém → API pro jiné systémy → Vytvořit klíč** → copy the `at_…` key.
2. Replace `192.168.1.20` and `at_XXX…` in both files. Home Assistant must reach the Pi (same LAN or VPN).
3. Camera id (`zahrada` in the example) is the camera name shown in Atmovio (**Kamery**), not the label.
4. Merge into your `configuration.yaml` / `automations.yaml` (or `rest: !include atmovio.yaml`), check the config, restart.
5. In the automation change `notify.mobile_app_my_phone` to your phone's notify service.

Ideas: turn on a light when `binary_sensor.atmovio_recording` goes off, show `camera.garden_sky` on a dashboard,
graph `sensor.atmovio_disk_used`, use `sensor.atmovio_version`'s `update` attribute to remind you to update.

Endpoints and all fields: [docs/api.md](../../docs/api.md). Scripts in PHP: [examples/api-php](../api-php).
