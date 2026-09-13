# Atmovio REST API – příklady v PHP

*[English](README.md)*

Funkční skripty, které ukazují, jak číst data z Atmovia (`GET http://<pi>/api/v1/…` s API klíčem).
PHP 8.0+ s ext-curl, nic dalšího. Fungují z příkazové řádky **i** jako webové stránky.

Hodí se, když se váš skript dostane k Raspberry (LAN nebo VPN). Pokud je váš server na internetu a na Pi
nedosáhne, použijte [webhook](../webhook-php) – Atmovio pak stejná data posílá samo.

| Soubor | Co dělá |
|---|---|
| `atmovio.php` | malá klientská třída: `status()`, `cameras()`, `snapshot()`, `detections()`, `detection()`, `detectionImage()`, `videos()`, `downloadVideo()`, `events()`, `health()` |
| `config.php` | adresa Pi + API klíč (nebo v `config.local.php`) |
| `status.php` | vypíše stav NVR (Frigate, disk, AI kvóta, slunce, teplota, výpadky, aktualizace) – `--json` pro surový výstup |
| `cameras.php` | živý přehled všech kamer se snímky, obnovuje se po 30 s |
| `detections.php` | poslední AI detekce oblohy jako galerie (prohlížeč) nebo tabulka (CLI) |
| `image.php` | proxy na obrázky – `?camera=zahrada` živý snímek, `?detection=123` AI snímek; klíč se do prohlížeče nikdy nedostane |
| `videos.php` | seznam exportovaných klipů, stažení: `php videos.php 42 klip.mp4` |
| `watch.php` | poller pro cron: spustí váš kód pro každou novou detekci ≥ 7/10 (uloží obrázek; doplňte Telegram, světla, …) |

## Nastavení

1. V Atmoviu: **Nastavení → Systém → API pro jiné systémy → Vytvořit klíč**. Klíč (`at_…`) se zobrazí jen jednou.
2. Upravte `config.php` (nebo vytvořte `config.local.php` se stejnými konstantami):
   ```php
   const ATMOVIO_URL = 'http://192.168.1.20';
   const ATMOVIO_KEY = 'at_…';
   ```
3. Vyzkoušejte:
   ```sh
   php status.php
   php detections.php 5
   php videos.php
   ```
   nebo složku nahrajte na PHP server v LAN a otevřete `cameras.php` / `detections.php` v prohlížeči.

## Použití klienta ve vlastním kódu

```php
require 'atmovio.php';
$api = new Atmovio('http://192.168.1.20', 'at_…');

$s = $api->status();
echo "disk {$s['storage']['disk_pct']} %, AI {$s['ai']['used_today']}/{$s['ai']['daily_limit']} dnes\n";

foreach ($api->detections(['limit' => 3, 'min_score' => 8]) as $d) {
    echo "{$d['ts']} {$d['phenomenon']} {$d['score']}/10 – {$d['description']}\n";
    file_put_contents("obloha-{$d['id']}.jpg", $api->detectionImage($d['id']));
}

file_put_contents('ted.jpg', $api->snapshot('zahrada', 1080));
```

Všechny metody při síťové/HTTP chybě vyhodí `AtmovioException` (zpráva + `httpCode`) – 401/403 znamená špatný klíč.

Úplný popis endpointů a polí: [docs/cs/api.md](../../docs/cs/api.md). Home Assistant: [examples/home-assistant](../home-assistant).
