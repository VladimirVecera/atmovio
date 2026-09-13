# Webhook – stav a upozornění na tvůj vlastní web

*[English](../webhook.md)*

SkyWatch žije v domácí síti. Aby ses na kamery a upozornění podíval odkudkoli bez otevírání portů, SkyWatch **posílá**
data na adresu, kterou vlastníš: každou minutu stav s malými náhledy a každé upozornění se snímkem AI. Tvůj web je uloží a
zobrazí (a může přeposlat e-mailem). Web Pi nikdy neovládá.

Hotový přijímač v PHP je v [`examples/webhook-php`](../../examples/webhook-php) – tři soubory, bez databáze.

## Nastavení ve SkyWatch

**Nastavení → Upozornění → Kam chodí upozornění: vlastní web (webhook)**

- **Adresa přijímače** – přesná finální URL (`https://example.com/skywatch/webhook.php`). Bez přesměrování (`www`, lomítko na konci) – přesměrování změní POST na GET.
- **Token** – dlouhý náhodný řetězec, stejný jako v přijímači.
- Pokročilé: název tohoto záznamníku, posílání náhledů.
- **Uložit a otestovat spojení** pošle `ping` a událost `test`.

Poslední chyba je vidět na stránce a v **Logy**.

## Protokol

`POST <url>` s `Content-Type: application/json`, hlavičky:

```
Authorization: Bearer <token>
X-Token: <token>          (totéž – pro hostingy, které Authorization odstraní)
User-Agent: SkyWatch/<verze>
```

Odpověď musí být JSON. `{"ok": true}` = přijato. Cokoli jiného (nebo ne-2xx) se bere jako chyba a ukáže se uživateli.
Timeouty: 20 s (ping), 30 s (heartbeat), 40 s (událost). Tělo do ~3 MB (obrázky jsou base64 JPEG).

Formát zpráv `ping`, `heartbeat` a `event` včetně příkladů je v [anglické verzi](../webhook.md#protocol) – pole jsou stejná.
Od verze 3.3 nese heartbeat i klíč `api` – snímek všeho, co vrací [REST API](api.md) (status, kamery, detekce, videa,
události, stejná pole) plus náhledy nových detekcí a videí, takže web, který se na RPi nedostane, může zobrazit totéž
co SkyWatch.
Identifikátory jevů: `cervanky, shelf, mammatus, beranci, bourka, blesk, duha, halo, paprsky, lentikularni, mlha, tornado,
wallcloud, rollcloud, asperitas, kroupy, prehanka, virga, dest, snezeni, jine`.

## Pravidla doručení

- Když je webhook nastavený a uspěje, upozornění je doručené („web“). Když je nastavené i SMTP, jde i e-mail.
- Když webhook selže a SMTP je nastavené, e-mail je záloha; selhání se zaloguje.
- Výpadky (`outage` / `recovery`) jdou stejnou cestou.

## Vlastní přijímač

Jde to v čemkoli – je to jeden HTTPS endpoint, který přijímá JSON. Checklist:

1. token porovnej v konstantním čase, jinak `401`;
2. omez velikost těla (3 MB), ověř, že `image`/`thumb` je JPEG (hlavička `FF D8`);
3. ulož poslední heartbeat a posledních N událostí; obrázky vydávej přes vlastní skript, aby úložiště zůstalo soukromé;
4. odpověz `{"ok": true}` rychle (e-mail pošli až po odpovědi nebo rychle);
5. ukazuj „naposledy viděn“ a označ záznamník offline, když 3 minuty nepřišel heartbeat.
