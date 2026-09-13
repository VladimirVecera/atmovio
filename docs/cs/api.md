# REST API (jen čtení)

*[English](../api.md)*

SkyWatch nabízí malé JSON API pro dashboardy, Home Assistant, skripty – cokoli, co chce *číst* stav.
Nastavení měnit neumí (od toho je web).

## API klíče

**Nastavení → Systém → API pro jiné systémy → Vytvořit klíč.** Klíč (`sw_…`) se ukáže jen jednou; ukládá se jen hash.
Zrušit ho jde na stejné stránce. Posílej ho jako:

```
Authorization: Bearer sw_xxxxxxxx
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

Příklady odpovědí a ukázka pro Home Assistant jsou v [anglické verzi](../api.md#examples) – pole jsou stejná.

```sh
curl -s -H "Authorization: Bearer sw_…" http://192.168.1.20/api/v1/status | jq .
curl -s -H "Authorization: Bearer sw_…" http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg -o ted.jpg
```

## Chyby

`401 {"error": "unauthorized"}` – chybí nebo zrušený klíč. `404` – neznámé id/kamera. `503` – Frigate nebo disk nejsou dostupné (snímky, obrázky).
