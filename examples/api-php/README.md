# Atmovio REST API – PHP examples

*[Česky](README.cs.md)*

Working scripts that show how to read data from Atmovio (`GET http://<pi>/api/v1/…` with an API key).
PHP 8.0+ with ext-curl, no other dependencies. They run from the command line **and** as web pages.

They are for the case where your script can reach the Pi (LAN or VPN). If your server is on the
internet and cannot reach the Pi, use the [webhook](../webhook-php) – Atmovio then pushes the same data to you.

| File | What it does |
|---|---|
| `atmovio.php` | tiny client class: `status()`, `cameras()`, `snapshot()`, `detections()`, `detection()`, `detectionImage()`, `videos()`, `downloadVideo()`, `events()`, `health()` |
| `config.php` | Pi address + API key (or put them in `config.local.php`) |
| `status.php` | prints NVR status (Frigate, disk, AI quota, sun, temperature, outages, update) – `--json` for raw output |
| `cameras.php` | live overview of all cameras with snapshots, refreshes every 30 s |
| `detections.php` | latest AI sky detections as a gallery (browser) or table (CLI) |
| `image.php` | image proxy – `?camera=zahrada` live frame, `?detection=123` AI snapshot; the key never reaches the browser |
| `videos.php` | list exported clips, download one: `php videos.php 42 clip.mp4` |
| `watch.php` | cron-style poller: runs your code for every new alert ≥ 7/10 (saves the picture; add Telegram, lights, …) |

## Setup

1. In Atmovio: **Nastavení → Systém → API pro jiné systémy → Vytvořit klíč**. Copy the key (`at_…`, shown once).
2. Edit `config.php` (or create `config.local.php` with the same two constants):
   ```php
   const ATMOVIO_URL = 'http://192.168.1.20';
   const ATMOVIO_KEY = 'at_…';
   ```
3. Try it:
   ```sh
   php status.php
   php detections.php 5
   php videos.php
   ```
   or copy the folder to a PHP web server in your LAN and open `cameras.php` / `detections.php` in the browser.

## Using the client in your own code

```php
require 'atmovio.php';
$api = new Atmovio('http://192.168.1.20', 'at_…');

$s = $api->status();
echo "disk {$s['storage']['disk_pct']} %, AI {$s['ai']['used_today']}/{$s['ai']['daily_limit']} today\n";

foreach ($api->detections(['limit' => 3, 'min_score' => 8]) as $d) {
    echo "{$d['ts']} {$d['phenomenon']} {$d['score']}/10 – {$d['description']}\n";
    file_put_contents("sky-{$d['id']}.jpg", $api->detectionImage($d['id']));
}

file_put_contents('now.jpg', $api->snapshot('zahrada', 1080));
```

All methods throw `AtmovioException` (message + `httpCode`) on network or HTTP errors – 401/403 means a wrong key.

Full endpoint and field reference: [docs/api.md](../../docs/api.md). Home Assistant: [examples/home-assistant](../home-assistant).
