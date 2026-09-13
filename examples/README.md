# Examples

| Folder | Direction | Use it when |
|---|---|---|
| [`api-php/`](api-php) | your script → Atmovio (REST API, `GET` with API key) | the script runs in your LAN/VPN: status, cameras, snapshots, detections, videos, a cron poller |
| [`home-assistant/`](home-assistant) | Home Assistant → Atmovio (REST integration) | sensors, camera entity, notification with the picture – no custom component |
| [`webhook-php/`](webhook-php) | Atmovio → your website (`POST` every minute + every alert) | the receiver is on the internet and cannot reach the Pi |

Docs: [REST API](../docs/api.md) · [Webhook](../docs/webhook.md) · [atmovio.com/api](https://www.atmovio.com/api/)
