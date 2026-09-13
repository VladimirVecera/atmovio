<p align="center">
  <img src="docs/img/atmovio-logo-wide.png" width="420" alt="Atmovio"><br>
  <sub>NVR na Raspberry Pi 5 s AI hlídáním oblohy – instalace jedním příkazem, administrace pro normální lidi</sub><br>
  <sub><i>dříve SkyWatch (≤ 3.4)</i></sub>
</p>

<p align="center">
  <a href="https://www.atmovio.com/cs/"><b>atmovio.com</b></a> ·
  <a href="README.md">🇬🇧 English</a> ·
  <a href="docs/cs/instalace.md">Instalace</a> ·
  <a href="docs/cs/hardware.md">Hardware</a> ·
  <a href="docs/cs/kamery.md">Kamery</a> ·
  <a href="docs/cs/ai.md">AI obloha</a> ·
  <a href="docs/cs/webhook.md">Webhook</a> ·
  <a href="#home-assistant-a-rest-api">🏠 Home Assistant</a> ·
  <a href="docs/cs/api.md">REST API</a> ·
  <a href="docs/cs/vpn.md">VPN</a> ·
  <a href="docs/cs/faq.md">Časté dotazy</a> ·
  <a href="examples/">Příklady</a> ·
  <a href="https://www.atmovio.com/cs/podpora/">♥ Podpořit</a>
</p>
<p align="center">
  <a href="https://www.atmovio.com/cs/podpora/"><img src="https://img.shields.io/badge/%E2%99%A5_Podpo%C5%99it_Atmovio-p%C5%99isp%C4%9Bt-e0245e?style=for-the-badge" alt="Podpořit Atmovio"></a>
  <a href="https://github.com/VladimirVecera/atmovio/releases/latest"><img src="https://img.shields.io/github/v/release/VladimirVecera/atmovio?style=for-the-badge&label=verze&color=2563eb" alt="Poslední verze"></a>
  <a href="#home-assistant-a-rest-api"><img src="https://img.shields.io/badge/Home_Assistant-REST_integrace-41bdf5?style=for-the-badge&logo=homeassistant&logoColor=white" alt="Home Assistant"></a>
  <a href="docs/cs/api.md"><img src="https://img.shields.io/badge/REST_API-JSON_%2B_API_kl%C3%AD%C4%8De-0f172a?style=for-the-badge" alt="REST API"></a>
</p>

Atmovio udělá z **Raspberry Pi 5** s USB diskem domácí záznamník IP kamer (o nahrávání se stará
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
| **Napojení** | Read-only **REST API** s API klíči (Home Assistant, dashboardy, skripty) a dokumentovaný odchozí webhook. Hotové příklady: [PHP skripty](examples/api-php), [Home Assistant YAML](examples/home-assistant), [přijímač webhooku](examples/webhook-php). |

## Hardware

| | |
|---|---|
| **Deska** | **Raspberry Pi 5**, minimálně 4 GB, doporučeno 8 GB. Testované a podporované je jen Pi 5 (instalátor vyžaduje 64bit ARM a na jiném modelu varuje). Pi 4 není podporováno – nahrávání by šlo, ale náhledy a snímky pro AI jdou přes CPU. |
| **Systém** | Raspberry Pi OS Lite 64-bit (Debian 12/13) na SSD (doporučeno) nebo SD kartě. |
| **Záznamy** | USB 3 pevný disk (ext4; instalátor ho bezpečně naformátuje, systémový disk nikdy). Velikost: datový tok všech kamer v Mbit/s × 10,8 ≈ GB/den – např. dvě kamery po 4 Mbit/s ≈ 86 GB/den, 600 GB/týden. Volitelné: bez disku běží Atmovio v živém náhledu. |
| **Zdroj a chlazení** | oficiální 27W zdroj (disk napájený z USB) a aktivní chladič. |
| **Síť** | kabelový Ethernet; vzdálené kamery přes WireGuard. |
| **Kamery** | libovolná IP kamera s RTSP H.264/H.265, nejlépe ONVIF; 4–6 kamer na jedno Pi 5 je v pohodě. |

Podrobnosti, tabulka velikostí disku a otestovaná sestava: [docs/cs/hardware.md](docs/cs/hardware.md).

## Rychlý start

```sh
curl -fsSL -o install.sh https://github.com/VladimirVecera/atmovio/releases/latest/download/install.sh
sudo bash install.sh
```

Instalátor se stáhne z [posledního vydání](https://github.com/VladimirVecera/atmovio/releases/latest) a musí běžet
v interaktivním terminálu (ptá se, proto `curl | bash` záměrně odmítne).
Raději `git clone`? `install.sh` je i v kořeni repozitáře: `git clone https://github.com/VladimirVecera/atmovio.git && cd atmovio && sudo bash install.sh`
(`main` může být rozpracovaný; vydání jsou vždy otestovaná).

Instalátor se zeptá na heslo správce (min. 12 znaků), retenci, časové pásmo, volitelně SMTP a který disk
použít na záznamy (existující ext4 se použije bez mazání, formátování vyžaduje napsat `SMAZAT`). Nainstaluje
Docker, Frigate 0.17, Portainer, Cockpit a Atmovio. Pak otevři `http://<IP-RPI>` a projdi 4 kroky na
Přehledu: kamery → disk → upozornění → klíč k AI.

Aktualizace: web sám hlásí, když vyšla nová verze, a nainstaluje ji na jedno kliknutí (Nastavení → Systém → Aktualizace);
nebo přes SSH: `curl -fsSL -o update-atmovio.sh https://github.com/VladimirVecera/atmovio/releases/latest/download/update-atmovio.sh && sudo bash update-atmovio.sh`.
V obou případech se zálohuje, ověří a při chybě vrátí.

Podrobně: [docs/cs/instalace.md](docs/cs/instalace.md).

> ♥ **Atmovio je a zůstane zdarma.** Pokud vám šetří čas, [podpořte projekt](https://www.atmovio.com/cs/podpora/) – libovolnou částkou, QR platbou nebo převodem, bez registrace.

## Služby po instalaci

| Služba | Adresa | K čemu |
|---|---|---|
| Atmovio | `http://IP` | administrace, kterou opravdu používáš |
| Frigate | `https://IP:8971` | přehrávač záznamů, export (uživatel `admin`, stejné heslo) |
| Cockpit | `https://IP:9090` | systém: síť, disky, aktualizace |
| Portainer | `https://IP:9443` | kontejnery (běžně nepotřebuješ) |

Atmovio běží záměrně na obyčejném HTTP – provozuj ho v domácí síti nebo přes VPN routeru. **Port 80 nikdy
nevystavuj do internetu.** Pro sledování odjinud použij [webhook](docs/cs/webhook.md) (posílá na tvůj web) nebo VPN.

## Home Assistant a REST API

Atmovio není uzavřená krabička. Vše, co ví – stav, kamery, živé snímky, AI detekce, videa, události – je jeden `GET`
daleko, s API klíči, které si vytvoříte v administraci. **Home Assistant nepotřebuje žádnou vlastní komponentu**: stačí
vestavěná REST integrace.

```yaml
rest:
  - resource: http://192.168.1.20/api/v1/status
    headers: {Authorization: "Bearer at_…"}
    sensor:
      - name: Atmovio AI požadavky dnes
        value_template: "{{ value_json.ai.used_today }}"
    binary_sensor:
      - name: Atmovio nahrává
        value_template: "{{ value_json.frigate.online }}"
camera:
  - platform: generic
    name: Zahrada obloha
    still_image_url: http://192.168.1.20/api/v1/cameras/zahrada/snapshot.jpg?api_key=at_…
```

| | |
|---|---|
| 🏠 **Home Assistant** | [`examples/home-assistant`](examples/home-assistant) – senzory, entita kamery, senzor poslední detekce a notifikace do telefonu s obrázkem |
| 🔌 **REST API** | [`docs/cs/api.md`](docs/cs/api.md) – všechny endpointy a pole; [`examples/api-php`](examples/api-php) – funkční PHP skripty (stav, kamery, galerie detekcí, videa, poller pro cron) |
| 📤 **Webhook** | [`docs/cs/webhook.md`](docs/cs/webhook.md) – Atmovio posílá stav + upozornění na váš web; [`examples/webhook-php`](examples/webhook-php) – hotový přijímač |

Více na webu: [atmovio.com/cs/api](https://www.atmovio.com/cs/api/).

## Jak funguje AI část

1. Od svítání do soumraku (nastavitelné: občanský / nautický / astronomický soumrak nebo pevné minuty) Atmovio vezme z každé kamery jeden snímek v plném rozlišení každých *N* minut (kolem východu a západu častěji).
2. Tmavé snímky a snímky, které se od minula nezměnily, se přeskočí bez dotazu na AI.
3. Model dostane katalog jevů a vrátí skóre a co vidí. Detekce na nebo nad prahem spustí upozornění – jednou za *epizodu* (40 minut červánků = jedno upozornění, ne deset).
4. Upozornění jde e-mailem a/nebo na webhook i se snímkem. Volitelně se automaticky vystřihne video.
5. Vše je vidět v **Historii**, na stránkách kamer a na Přehledu; denní statistiky se drží nezávisle na úklidu historie.

**Na Pi neběží žádná neuronová síť.** Atmovio pošle jeden JPEG hostovanému vision modelu s pevnou otázkou
(„jak zajímavá je obloha 0–10 a které z těchto jevů vidíš?“) a zpracuje odpověď v JSON. Podporovaní poskytovatelé:
**Google Gemini** (bezplatný tarif, výchozí – Flash-Lite se vybere sám, stovky dotazů denně), **Groq** a **OpenRouter**
(bezplatné modely, OpenAI-kompatibilní), **OpenAI** a **Anthropic** (placené, nejpřesnější) a **Ollama** přímo na Pi
(zdarma a offline, ale pomalé a méně přesné). Z Pi odcházejí jen jednotlivé snímky; záznamy nikdy.
Katalog má 21 jevů (červánky, shelf cloud, mammatus, beránky, bouřkový mrak, blesk, duha, halo, krepuskulární paprsky,
lentikulární, mlha, tromba, wall cloud, roll cloud, asperitas, kroupové jádro, přeháňka, virga, déšť, sněžení, jiné) – vybereš,
na které chceš upozornit, a práh. Podrobnosti, kvóty a ladění: [docs/cs/ai.md](docs/cs/ai.md).

## Struktura repozitáře

```
install.sh              sestavený instalátor (needituj – generuje se)
update-atmovio.sh      sestavený aktualizátor (generuje se)
src/
  build.sh              sestaví oba skripty ze šablon + aplikace
  install.template.sh   zdroj instalátoru
  update.template.sh    zdroj aktualizátoru
  atmovio/
    app.py              celá webová aplikace (FastAPI + Jinja šablony uvnitř)
    storage_guard.py    hlídač HDD / přepínání Frigate živě vs. nahrávání
    static/             CSS + JS (Pico CSS a Alpine.js se stáhnou při instalaci)
docs/                   dokumentace anglicky, docs/cs česky
examples/
  api-php/              PHP klient + skripty pro REST API (stav, kamery, detekce, videa, poller pro cron)
  home-assistant/       configuration.yaml + automations.yaml (REST integrace)
  webhook-php/          hotový PHP přijímač + stavová stránka pro webhook
```

Vývoj: po každé změně v `src/` spusť `bash src/build.sh`; `bash src/build.sh --check` ověří, že sestavené
skripty odpovídají zdrojům. `python3 -m py_compile src/atmovio/app.py` zkontroluje syntaxi; aplikaci jde
spustit i lokálně: `ATMOVIO_DIR=/tmp/sw ATMOVIO_PORT=8099 ATMOVIO_ADMIN_PASSWORD=… python3 src/atmovio/app.py`
(funkce závislé na Frigate se ukážou jako offline).

## Podpořte projekt

Atmovio je zdarma a nemá placenou verzi. Když vám šetří čas, můžete podpořit provoz serveru a další vývoj –
libovolnou částkou, QR platbou nebo převodem: **[atmovio.com/cs/podpora](https://www.atmovio.com/cs/podpora/)**.
Stejně pomůže ⭐ tomuto repozitáři a hlášení, které kamery fungují.

## Přispívání

Issues i pull requesty vítány – hlášení chyb s logy (stránka **Logy** → Stáhnout), modely kamer, které
fungovaly nebo ne, překlady, nové jevy, integrace. Přečti si [CONTRIBUTING.md](CONTRIBUTING.md) a
[SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE) © 2026 Vladimír Večeřa. Frigate, Pico CSS a Alpine.js jsou samostatné projekty s vlastními licencemi.
