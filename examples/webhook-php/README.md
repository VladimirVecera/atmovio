# SkyWatch webhook receiver (PHP example)

A tiny, dependency-free receiver you can drop on any PHP hosting (PHP 8.0+). SkyWatch sends
camera status every minute and every alert (with the AI snapshot) to it; `index.php` shows a
simple status page you can open from anywhere on the internet.

No database is needed – everything is stored as JSON files and JPEGs in `data/`.

## Install

1. Upload `webhook.php`, `index.php` and `config.php` to a folder on your web, e.g. `https://example.com/skywatch/`.
2. Edit `config.php`:
   - `SKYWATCH_TOKEN` – a long random secret (`openssl rand -hex 32`).
   - optionally `SKYWATCH_MAIL_TO` to forward alerts by e-mail, and `SKYWATCH_VIEW_PASSWORD` to protect the page.
3. Make sure PHP can write to `data/` (it is created automatically; on Apache a `.htaccess` denies direct access to it).
4. In SkyWatch open **Nastavení → Upozornění → Vlastní web (webhook)**, paste the URL
   `https://example.com/skywatch/webhook.php` and the same token, click **Uložit a otestovat spojení**.

Use the exact final URL (with/without `www`, `https`) – a redirect would turn the POST into a GET.

## What it stores

| File | Content |
|---|---|
| `data/state.json` | last heartbeat: NVR status and camera list |
| `data/thumbs/<camera>.jpg` | latest small preview of each camera |
| `data/events.json` | last 500 events (alerts, outages, tests) |
| `data/events/<id>.jpg` | AI snapshot attached to an alert |

The message format is documented in [docs/webhook.md](../../docs/webhook.md). This example is
deliberately minimal – use it as a starting point for your own site.
