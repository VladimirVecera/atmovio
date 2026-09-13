# Instalace

*[English](../install.md)*

## Co potřebuješ

- **Raspberry Pi 5** (4 GB RAM nebo víc), oficiální zdroj 27 W. Pi 4 může fungovat, není testováno.
- **Raspberry Pi OS Lite 64-bit** (Debian 12 „bookworm“ nebo 13 „trixie“) čerstvě zapsaný přes Raspberry Pi Imager.
  V Imageru nastav: hostname, uživatele `pi` (nebo jiného), heslo, **zapni SSH**. Boot z SSD (doporučeno) nebo SD karty.
- **Kabelový Ethernet.** Wi-Fi funguje, ale kamery streamují nepřetržitě – nedělej to.
- **USB 3 pevný disk** na záznamy (doporučeno 2 TB+), s vlastním napájením nebo v kvalitním boxu.
  Bez disku se nainstaluje vše také, jen nahrávání a snímky AI čekají („jen živý náhled“).
- Jednu nebo více **IP kamer s RTSP** (H.264 nebo H.265). Prakticky každý Hikvision/HiLook, Dahua/Imou, Reolink, Tapo,
  Uniview, Axis nebo obecná ONVIF kamera. Viz [kamery.md](kamery.md).

## Instalace

1. Stáhni `install.sh` z [Releases](https://github.com/VladimirVecera/atmovio/releases) (nebo z kořene repozitáře).
2. Zkopíruj ho na Pi a spusť jako root **v interaktivním terminálu** (skript se ptá; `curl | bash` odmítne):

   ```sh
   scp install.sh pi@192.168.1.20:
   ssh pi@192.168.1.20
   sudo bash install.sh
   ```

3. Odpověz na otázky:

   | Otázka | Poznámka |
   |---|---|
   | Heslo správce (2×) | Min. 12 znaků. Platí pro Atmovio, Portainer i Frigate (`admin`). **Nic není přednastavené.** |
   | Retence záznamů (dní) | 1–60. Starší záznamy Frigate maže sám. |
   | Časové pásmo | výchozí `Europe/Prague` |
   | SMTP server | Enter = přeskočit. E-mail nastavíš později ve webu, nebo použij webhook. |
   | Disk na záznamy | Nabídne USB disky mimo systémový. Existující ext4 se použije beze změny; formátování celého disku vyžaduje napsat `SMAZAT`. `0` = pokračovat bez nahrávání. |

4. Počkej. Nainstaluje se Docker, Frigate (`0.17.2`), Portainer, Cockpit a Atmovio (5–15 minut podle připojení).
5. Na konci skript vypíše adresy. Přístupy jsou také v `/opt/nvr/INSTALL-INFO.txt` (jen root).
6. Otevři `http://<IP>` a přihlas se. Přehled ukáže **4 kroky**: kamery → disk → upozornění → klíč k AI.

## Po instalaci

| Kde | Co |
|---|---|
| `http://IP` | **Atmovio** – administrace: Přehled, Kamery, Záznamy a disk, Historie AI, Videa, Nastavení |
| `https://IP:8971` | **Frigate** – časová osa záznamů, export úseků. Uživatel `admin`, stejné heslo. Vlastní certifikát – potvrď varování prohlížeče. |
| `https://IP:9090` | **Cockpit** – Raspberry Pi OS: síť (statická IP), aktualizace, uživatelé, disky. Přihlášení účtem systému. |
| `https://IP:9443` | **Portainer** – Docker kontejnery. Běžně nepotřebuješ. |

Nastav Pi **pevnou IP** (v DHCP routeru nebo Cockpit → Networking), jinak se adresa změní a záložky přestanou fungovat.

## Kde co na Pi je

```
/opt/nvr/                     docker-compose.yml, INSTALL-INFO.txt
/opt/nvr/frigate/config/      config.yml (Frigate – edituje Atmovio), živá kopie, databáze
/opt/nvr/atmovio/            app.py, config.json, atmovio.db, static/, venv, backups/
/mnt/nvr/                     disk na záznamy: frigate/recordings, frigate/exports, snímky Atmovio
/etc/wireguard/wg-remote.conf konfigurace VPN klienta (pokud se používá)
```

Služby: `atmovio.service` (web, port 80), `nvr-storage.service` (hlídač disku, startuje Frigate), `docker`.
Logy: stránka **Logy** ve Atmovio; `journalctl -u atmovio`, `journalctl -u nvr-storage`.

## Aktualizace

**Z webu (doporučeno):** Atmovio se jednou denně zeptá [GitHub Releases](https://github.com/VladimirVecera/atmovio/releases)
(jeden dotaz; nic se neinstaluje samo) a když existuje novější verze, ukáže lištu na Přehledu. Otevři
**Nastavení → Systém → Aktualizace**, přečti si, co je nového, a klikni na **Nainstalovat**. Atmovio stáhne
`update-atmovio.sh` z vydání, ověří jeho SHA-256 proti `SHA256SUMS` z vydání a spustí ho jako samostatnou systemd
jednotku (přežije restart samotného Atmovio); stránka ukazuje průběh a výsledek. Nahrávání běží dál, web je asi minutu
nedostupný. Denní kontrolu jde na téže stránce vypnout.

**Ručně přes SSH** (stejný skript, stejný výsledek – hodí se, když RPi nemá přístup na internet):

```sh
scp update-atmovio.sh pi@192.168.1.20:
ssh pi@192.168.1.20
sudo bash update-atmovio.sh
```

Aktualizátor připraví nové prostředí Pythonu, ověří import aplikace, zazálohuje starou aplikaci + konfiguraci + prostředí do
`/opt/nvr/atmovio/backups/<čas>/`, přepne a zkontroluje HTTP health endpoint. Když cokoli selže, vrátí se sám zpět. Drží se
dvě poslední zálohy. Konfigurace (`config.json`), kamery a záznamy se nemění.

Frigate je připnutý na `0.17.2` v `/opt/nvr/docker-compose.yml`; přechod na novější Frigate je ruční krok
(přečti [poznámky k aktualizaci Frigate](https://docs.frigate.video/frigate/updating/), pak Systém → Aktualizovat kontejnery).

## Odinstalace

```sh
sudo systemctl disable --now atmovio nvr-storage
cd /opt/nvr && sudo docker compose down
sudo rm -rf /opt/nvr
# volitelně: odstranit řádek /mnt/nvr z /etc/fstab, apt remove docker-ce cockpit
```

## Když něco nejde

- **„Atmovio už je nainstalován“** – instalátor nepřepíše existující `config.json`. Použij aktualizátor, nebo smaž `/opt/nvr` pro čistý start.
- **Frigate nestartuje** – Přehled ukáže červený pruh s tlačítkem „Opravit konfiguraci a restartovat“; detaily v Logy → Frigate.
- **Disk není vidět** – stránka Záznamy a disk vypíše kandidáty; `lsblk` na Pi ukáže, jestli ho systém vůbec vidí (napájení USB!).
- **Špatný čas v logu** – pásmo se nastavuje při instalaci; změň v Cockpitu a restartuj.
