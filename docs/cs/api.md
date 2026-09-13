# REST API (jen čtení)

*[English](../api.md)*

Atmovio nabízí malé JSON API pro dashboardy, Home Assistant, skripty – cokoli, co chce *číst* stav.
Nastavení měnit neumí (od toho je web).

## Dva směry

| | Kdo volá koho | Kdy použít |
|---|---|---|
| **REST API** (tato stránka) | *tvůj* systém → Atmovio, `GET http://<rpi>/api/v1/…` s API klíčem | volající je v tvé LAN/VPN: Home Assistant, dashboard, skript na PC |
| **Webhook** ([webhook.md](webhook.md)) | Atmovio → *tvoje* URL, `POST` každou minutu + při každém upozornění | přijímač je na internetu (hosting) a na RPi se nedostane. Od 3.3 nese heartbeat klíč `api` – stejná data jako všechny endpointy níže – takže web ukáže vše, co API nabízí, plus upozornění se snímkem. Nastavuje se v **Nastavení → Upozornění → vlastní web**. |

Oba směry používají stejná jména polí, kód napsaný pro jeden funguje i pro druhý.

## API klíče

**Nastavení → Systém → API pro jiné systémy → Vytvořit klíč.** Klíč (`at_…`; klíče vytvořené ve SkyWatch 3.x začínají `sw_` a platí dál) se ukáže jen jednou; ukládá se jen hash.
Zrušit ho jde na stejné stránce. Posílej ho jako:

```
Authorization: Bearer at_xxxxxxxx
```
(funguje i hlavička `X-API-Key: …` nebo parametr `?api_key=…`; preferuj hlavičku).
Přihlášený prohlížeč může API volat také – hodí se na vyzkoušení.

API běží na obyčejném HTTP v LAN/VPN – nevystavuj ho do internetu.

## Endpointy

| Metoda + cesta | Vrací |
|---|---|
| `GET /api/v1/status` | stav NVR: verze, Frigate, úložiště, využití AI, slunce, systém, aktuální výpadky, dostupná aktualizace (`update`) |
| `GET /api/v1/cameras` | seznam kamer: online/fps/IP/cesta, AI příznaky, URL snímku |
| `GET /api/v1/cameras/{name}/snapshot.jpg?h=720` | aktuální JPEG (výška 120–1080) |
| `GET /api/v1/detections?limit=20&camera=&notified=1&min_score=0` | poslední detekce AI (výchozí jen s upozorněním; `notified=0` = všechna vyhodnocení) |
| `GET /api/v1/detections/{id}` | jedna detekce |
| `GET /api/v1/detections/{id}/image.jpg` | snímek AI |
| `GET /api/v1/videos` | vystřižená videa s odkazy ke stažení |
| `GET /api/v1/videos/{id}/download` | MP4 |
| `GET /api/v1/events?limit=20` | log výpadků / obnovení / oblohy |
| `GET /api/health` | `{"ok": true, …}` bez přihlášení (pro monitoring) |

```sh
curl -s -H "Authorization: Bearer at_…" http://192.168.1.20/api/v1/status | jq .
curl -s -H "Authorization: Bearer at_…" http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg -o ted.jpg
```

## Popis polí

Časy jsou v místním čase RPi (`tz` z instalace) v ISO formátu, pokud není uvedeno jinak. Odkazy `*_url` vedou na RPi
(jeho LAN IP) a fungují jen doma / přes VPN.

### `status`

| Pole | Význam |
|---|---|
| `version`, `time` | verze Atmovio, aktuální čas |
| `frigate.online`, `frigate.version` | záznamník běží, verze Frigate |
| `storage.mode` | `recording` / `legacy` = nahrává na HDD, `live` = bez disku (jen náhled), jiné = nepřipraveno; `storage.reason` vysvětlí |
| `storage.disk_pct`, `disk_free`, `disk_total`, `retain_days` | obsazení disku pro záznamy a uchovávání (null bez disku) |
| `ai.enabled`, `ai.status` | AI hlídání zapnuto a lidsky čitelný stav |
| `ai.used_today`, `ai.daily_limit` | dotazů na model dnes / nastavený strop (0 = žádný) |
| `ai.threshold` | práh upozornění 0–10 |
| `ai.cameras`, `ai.daytime` | hlídané kamery; jestli je teď okno svítání–soumrak |
| `sun.dawn`, `sunrise`, `sunset`, `dusk` | dnešní časy (`HH:MM`) podle nastaveného soumraku |
| `system.*` | `hostname`, `temp`, `uptime`, `load`, `ip`, `ip_vpn`, `mem` |
| `outages` | aktuální výpadky: `{"cam:<název>": sekundy, "frigate": sekundy, "storage": sekundy}` |
| `update.latest`, `update.available`, `update.checked` | nejnovější vydání na GitHubu, jestli je novější než `version`, kdy se kontrolovalo |

### `cameras[]`

| Pole | Význam |
|---|---|
| `name`, `label` | id ve Frigate (bez diakritiky) a zobrazovaný název |
| `ip`, `via` | IP kamery a cesta: `LAN`, `VPN` (WireGuard) nebo `?` |
| `online`, `fps`, `outage_s` | přijímá snímky, aktuální fps, sekund od začátku výpadku (null když online) |
| `ai`, `auto_video` | hlídá ji AI; automatické video po upozornění zapnuto |
| `snapshot_url` | aktuální JPEG (`?h=` výška 120–1080) |

### `detections[]`

| Pole | Význam |
|---|---|
| `id`, `ts`, `camera`, `camera_label` | id detekce, čas, kamera |
| `score` | 0–10 od modelu |
| `phenomenon` | krátký název hlavního jevu, jak ho napsal model (česky), nebo „nic zajímavého“ |
| `phenomena` | id všech rozpoznaných jevů (`cervanky`, `shelf`, `mammatus`, `beranci`, `bourka`, `blesk`, `duha`, `halo`, `paprsky`, `lentikularni`, `mlha`, `tornado`, `wallcloud`, `rollcloud`, `asperitas`, `kroupy`, `prehanka`, `virga`, `dest`, `snezeni`, `jine`) |
| `description` | jedna dvě věty od modelu |
| `notified` | upozornění odešlo (skóre ≥ práh, jev vybraný, epizoda/cooldown dovolily) |
| `exported` | z detekce je vystřižené video |
| `error` | chyba modelu/parsování (běžně null) |
| `image_url`, `detail_url` | vyhodnocený snímek; detail v Atmovio (snímek + přehrání záznamu kolem) |

Parametry: `limit` (1–200), `camera`, `notified` (1 = jen s upozorněním, výchozí; 0 = všechna vyhodnocení), `min_score`.

### `videos[]`

| Pole | Význam |
|---|---|
| `id`, `name`, `camera`, `camera_label` | id videa, název zadaný při exportu, kamera |
| `detection_id` | detekce, ze které je video vystřižené (null u ručního rozsahu) |
| `start_ts`, `end_ts` | rozsah jako Unix timestamp; `range` = totéž textem |
| `created` | kdy byl export zadán |
| `auto` | vystřiženo automaticky po upozornění |
| `ready`, `in_progress` | MP4 existuje / Frigate ještě stříhá |
| `duration`, `size` | délka a velikost souboru lidsky |
| `thumb_url`, `download_url` | náhledový snímek; MP4 (null dokud není `ready`) |

### `events[]`

| Pole | Význam |
|---|---|
| `id`, `ts` | id události, čas |
| `kind` | `sky` (upozornění), `outage` (výpadek), `recovery` (obnoveno), `system`, `test` |
| `subject`, `message` | předmět a text upozornění tak, jak šly e-mailem/webhookem |
| `emailed` | 1 když upozornění odešlo e-mailem/webhookem |

Příklady odpovědí a ukázka pro Home Assistant jsou v [anglické verzi](../api.md#examples) – pole jsou stejná.

## Chyby

`401 {"error": "unauthorized"}` – chybí nebo zrušený klíč. `404` – neznámé id/kamera. `503` – Frigate nebo disk nejsou dostupné (snímky, obrázky).
