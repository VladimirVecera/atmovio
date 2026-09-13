<p align="center">
  <img src="docs/img/logo.svg" width="96" alt="SkyWatch logo"><br>
  <b>SkyWatch</b><br>
  <sub>NVR na Raspberry Pi 5 s AI hlídáním oblohy – instalace jedním příkazem, administrace pro normální lidi</sub>
</p>

<p align="center">
  <a href="README.md">🇬🇧 English</a> ·
  <a href="docs/cs/instalace.md">Instalace</a> ·
  <a href="docs/cs/kamery.md">Kamery</a> ·
  <a href="docs/cs/ai.md">AI obloha</a> ·
  <a href="docs/cs/webhook.md">Webhook</a> ·
  <a href="docs/cs/api.md">REST API</a> ·
  <a href="docs/cs/vpn.md">VPN</a> ·
  <a href="docs/cs/faq.md">Časté dotazy</a>
</p>

SkyWatch udělá z **Raspberry Pi 5** s USB diskem domácí záznamník IP kamer (o nahrávání se stará
**[Frigate](https://frigate.video)**) a přidává něco, co Frigate neumí: dívá se kamerami na **oblohu**
a dá vědět, když se děje něco hezkého nebo nebezpečného – červánky, shelf cloud, mammatus, duha, halo,
blesky, mlha…

Je stavěný pro lidi, kteří nejsou správci serverů. Všechno je na jedné webové stránce, česky, srozumitelně,
a instalátor se ptá jen na to, co opravdu potřebuje.

## Co dostaneš

| | |
|---|---|
| **Nahrávání** | Souvislý záznam libovolné RTSP kamery bez překódování (H.264/H.265), přehrávání a export přes Frigate. Retence ve dnech. Funguje i bez HDD (jen živý náhled). |
| **Kamery, které se přidají opravdu jen když fungují** | Vyhledání v síti (ONVIF + sken portů), každý stream se před uložením ověří na *skutečné snímky*, špatný port se opraví, chyby jsou vysvětlené lidsky. Vzdálené kamery přes WireGuard. |
| **AI hlídání oblohy** | Každých pár minut jde snímek do vizuálního modelu (výchozí Google Gemini zdarma; dále Groq, OpenAI, Anthropic, Ollama). Model vrátí skóre 0–10 a jevy, které vidí; ty si vybereš, na co upozorňovat. Hlídá od svítání do soumraku, tmavé a nezměněné snímky přeskakuje (šetří denní limit). Epizody a odstupy brání záplavě upozornění. |
| **Upozornění** | E-mail (SMTP) a/nebo **webhook na tvůj vlastní web** (stav a náhledy každou minutu, upozornění se snímkem). Hlídání výpadků kamer, nahrávání a disku včetně obnovení. |
| **Videa** | Vystřihnout úsek kolem detekce (−N/+M minut) nebo to nechat udělat **automaticky po každém upozornění**; přehrát v prohlížeči až 120×, stáhnout MP4, volitelně timelapse 25×. |
| **Stránka kamery** | Vše o jedné kameře na jednom místě: živý obraz, stav, AI přepínače, detekce, videa, adresy streamů. |
| **Provoz bez stresu** | Zdraví disku (SMART) srozumitelně, hlídač úložiště, který udrží systém při životě i bez HDD, logy s hledáním, aktualizace jedním souborem s automatickým návratem při chybě. |
| **Napojení** | Read-only **REST API** s API klíči (Home Assistant, dashboardy, skripty) a dokumentovaný odchozí webhook. |

## Rychlý start

Potřebuješ: Raspberry Pi 5 (4 GB+), Raspberry Pi OS Lite 64-bit (Debian 12/13) na SSD nebo SD kartě,
volitelně USB 3 disk na záznamy, kabelový Ethernet a jednu nebo více RTSP kamer.

```sh
# na svém počítači
scp install.sh pi@<IP-RPI>:
ssh pi@<IP-RPI>
sudo bash install.sh
```

Instalátor se zeptá na heslo správce (min. 12 znaků), retenci, časové pásmo, volitelně SMTP a který disk
použít na záznamy (existující ext4 se použije bez mazání, formátování vyžaduje napsat `SMAZAT`). Nainstaluje
Docker, Frigate 0.17, Portainer, Cockpit a SkyWatch. Pak otevři `http://<IP-RPI>` a projdi 4 kroky na
Přehledu: kamery → disk → upozornění → klíč k AI.

Aktualizace: `scp update-skywatch.sh pi@<IP-RPI>: && ssh pi@<IP-RPI> sudo bash update-skywatch.sh`
(zálohuje, ověří, při chybě se vrátí).

Podrobně: [docs/cs/instalace.md](docs/cs/instalace.md).

## Služby po instalaci

| Služba | Adresa | K čemu |
|---|---|---|
| SkyWatch | `http://IP` | administrace, kterou opravdu používáš |
| Frigate | `https://IP:8971` | přehrávač záznamů, export (uživatel `admin`, stejné heslo) |
| Cockpit | `https://IP:9090` | systém: síť, disky, aktualizace |
| Portainer | `https://IP:9443` | kontejnery (běžně nepotřebuješ) |

SkyWatch běží záměrně na obyčejném HTTP – provozuj ho v domácí síti nebo přes VPN routeru. **Port 80 nikdy
nevystavuj do internetu.** Pro sledování odjinud použij [webhook](docs/cs/webhook.md) (posílá na tvůj web) nebo VPN.

## Jak funguje AI část

1. Od svítání do soumraku (nastavitelné: občanský / nautický / astronomický soumrak nebo pevné minuty) SkyWatch vezme z každé kamery jeden snímek v plném rozlišení každých *N* minut (kolem východu a západu častěji).
2. Tmavé snímky a snímky, které se od minula nezměnily, se přeskočí bez dotazu na AI.
3. Model dostane katalog jevů a vrátí skóre a co vidí. Detekce na nebo nad prahem spustí upozornění – jednou za *epizodu* (40 minut červánků = jedno upozornění, ne deset).
4. Upozornění jde e-mailem a/nebo na webhook i se snímkem. Volitelně se automaticky vystřihne video.
5. Vše je vidět v **Historii**, na stránkách kamer a na Přehledu; denní statistiky se drží nezávisle na úklidu historie.

Bezplatný tarif Google Gemini stačí na pár kamer (stovky dotazů denně). Viz [docs/cs/ai.md](docs/cs/ai.md).

## Struktura repozitáře

```
install.sh              sestavený instalátor (needituj – generuje se)
update-skywatch.sh      sestavený aktualizátor (generuje se)
src/
  build.sh              sestaví oba skripty ze šablon + aplikace
  install.template.sh   zdroj instalátoru
  update.template.sh    zdroj aktualizátoru
  skywatch/
    app.py              celá webová aplikace (FastAPI + Jinja šablony uvnitř)
    storage_guard.py    hlídač HDD / přepínání Frigate živě vs. nahrávání
    static/             CSS + JS (Pico CSS a Alpine.js se stáhnou při instalaci)
docs/                   dokumentace anglicky, docs/cs česky
examples/webhook-php/   hotový PHP přijímač + stavová stránka pro webhook
```

Vývoj: po každé změně v `src/` spusť `bash src/build.sh`; `bash src/build.sh --check` ověří, že sestavené
skripty odpovídají zdrojům. `python3 -m py_compile src/skywatch/app.py` zkontroluje syntaxi; aplikaci jde
spustit i lokálně: `SKYWATCH_DIR=/tmp/sw SKYWATCH_PORT=8099 SKYWATCH_ADMIN_PASSWORD=… python3 src/skywatch/app.py`
(funkce závislé na Frigate se ukážou jako offline).

## Přispívání

Issues i pull requesty vítány – hlášení chyb s logy (stránka **Logy** → Stáhnout), modely kamer, které
fungovaly nebo ne, překlady, nové jevy, integrace. Přečti si [CONTRIBUTING.md](CONTRIBUTING.md) a
[SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE) © 2026 Vladimír Večeřa. Frigate, Pico CSS a Alpine.js jsou samostatné projekty s vlastními licencemi.
