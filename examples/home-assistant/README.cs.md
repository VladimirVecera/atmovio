# Atmovio + Home Assistant

*[English](README.md)*

Atmovio nemá vlastní komponentu – stačí vestavěná **REST** integrace Home Assistanta,
protože každá hodnota je jeden `GET` s API klíčem. Dva soubory:

| Soubor | Co dostanete |
|---|---|
| `configuration.yaml` | senzory: AI požadavky dnes, obsazení disku, teplota, verze (+ atribut `update`); binární senzory: nahrává, den, kamera online; entitu `camera` s živým obrazem; `sensor.atmovio_last_sky_alert` s poslední detekcí (atributy `id`, `ts`, `score`, `camera_label`, `description`, `image_url`, `detail_url`) |
| `automations.yaml` | push notifikace do telefonu s obrázkem při každé nové detekci ≥ 7/10 |

## Nastavení

1. Atmovio: **Nastavení → Systém → API pro jiné systémy → Vytvořit klíč** → zkopírujte klíč `at_…`.
2. V obou souborech nahraďte `192.168.1.20` a `at_XXX…`. Home Assistant musí na Pi dosáhnout (stejná LAN nebo VPN).
3. Id kamery (`zahrada` v příkladu) je název kamery v Atmoviu (**Kamery**), ne popisek.
4. Vložte do svého `configuration.yaml` / `automations.yaml` (nebo `rest: !include atmovio.yaml`), zkontrolujte konfiguraci, restartujte.
5. V automatizaci změňte `notify.mobile_app_my_phone` na notify službu svého telefonu.

Nápady: rozsvítit světlo, když `binary_sensor.atmovio_recording` spadne, `camera.garden_sky` na dashboard,
graf `sensor.atmovio_disk_used`, atribut `update` senzoru `sensor.atmovio_version` jako připomínka aktualizace.

Endpointy a všechna pole: [docs/cs/api.md](../../docs/cs/api.md). Skripty v PHP: [examples/api-php](../api-php).
