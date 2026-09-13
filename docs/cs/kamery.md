# Kamery

*[English](../cameras.md)*

## Přidání kamery

**Nastavení → Kamery → Vyhledat kamery v síti** je nejjednodušší cesta:

1. Zadej **uživatele a heslo kamery** (to, čím se přihlašuješ do její webové stránky). Bez nich většina kamer video nevydá (HTTP 401) a nejde je ověřit.
2. SkyWatch prohledá síť (ONVIF + sken portů 554/80/8000/8080/8554 v zadaných sítích; můžeš přidat vzdálenou síť za VPN, např. `10.10.10.0/24`).
3. U každého zařízení načte profily streamů přes ONVIF a **každou RTSP adresu ověří na skutečné dekódované snímky** – přesně tak, jak ji bude číst Frigate. Adresy bez videa vynechá, špatný port opraví.
4. Potvrď název a klikni **Přidat kameru**. Frigate se restartuje (20–40 s) a kamera se objeví v Přehledu.

Ruční přidání (**Přidat kameru ručně**) potřebuje RTSP adresy. Typické cesty:

| Výrobce | Hlavní stream | Substream |
|---|---|---|
| Hikvision / HiLook / Annke | `/Streaming/Channels/101` | `/Streaming/Channels/102` |
| Dahua / Imou / Amcrest | `/cam/realmonitor?channel=1&subtype=0` | `…subtype=1` |
| Reolink | `/h264Preview_01_main` | `/h264Preview_01_sub` |
| TP-Link Tapo / Vigi | `/stream1` | `/stream2` |
| Uniview | `/media/video1` | `/media/video2` |
| Axis | `/axis-media/media.amp` | |

Celá adresa: `rtsp://uzivatel:heslo@192.168.1.50:554/stream1`. Speciální znaky v hesle zakóduj (`@` → `%40`, mezera → `%20`),
nebo nech adresu bez přihlášení a vyplň uživatele a heslo do polí formuláře.

## Hlavní vs. vedlejší stream

- **Hlavní stream** (plné rozlišení) se **ukládá tak, jak je** – bez překódování, procesor zůstává chladný. H.264 i H.265.
- **Substream** (nízké rozlišení, např. 640×360) slouží pro živý náhled a detekční pipeline Frigate. Nepovinný, ale doporučený: bez něj Frigate dekóduje pro náhled plné rozlišení.
- Snímky pro AI se berou z hlavního streamu (jeden snímek v plném rozlišení každých pár minut).

Doporučené nastavení kamery: hlavní stream H.264/H.265, konstantní bitrate 2–6 Mbit/s, 15–20 fps, interval klíčových snímků = fps (1 s);
substream 640×360, 5–10 fps. Zvuk vypni, pokud ho nepotřebuješ (některé kamery posílají jen AAC a matou go2rtc).

## Stránka kamery

Klikni na kameru kdekoli (Přehled, Kamery, historie…) a otevře se `/camera/<id>`:

- velký snímek, který se sám obnovuje, **živý MJPEG** na tlačítko, snímek v plném rozlišení;
- stav: fps, jestli posledních 10 minut je na disku, IP a cesta (LAN / VPN), poslední vyhodnocení AI, poslední výpadky;
- přepínače AI pro tuto kameru (hlídat / video automaticky po upozornění) a „Vyzkoušet AI teď“;
- poslední upozornění a videa z této kamery;
- nastavení streamů (název, adresy, přihlášení), odkaz na masky/zóny ve Frigate, odebrání kamery.

**Kamery** (hlavní menu) ukazují všechny kamery jako velké snímky; **▶ Živě všechny kamery** spustí živý MJPEG všech.

## Vzdálené kamery (VPN)

Kamera jinde (chata, u rodičů) se přidá stejně, jen s adresou ve vzdálené síti. Pi se do té sítě musí dostat: buď to řeší
router (VPN mezi routery), nebo vložíš WireGuard konfiguraci klienta do **Nastavení → Síť a VPN** – viz [vpn.md](vpn.md).

## Odebrání / úprava

Stránka kamery → Nastavení kamery → **Uložit změny** znovu ověří streamy a restartuje Frigate; masky a zóny ve Frigate zůstanou.
**Odebrat kameru** ji vyřadí z nahrávání i AI; záznamy na disku zůstanou, dokud je nesmaže retence.

## Známé zvláštnosti

- Kamery s RTSP jen na portu 80 nebo 8554: hledání tyto porty zkusí a adresu opraví.
- Některé kamery (Tapo, starší Xiaomi) se s go2rtc nedomluví; SkyWatch automaticky přepne na zdroj přes ffmpeg a řekne to (bez zvuku).
- ONVIF hledání je multicast – najde jen kamery ve vlastní síti Pi. Pro sítě za VPN použij sken podsítě.
- Když kamera po změně IP ukazuje **BEZ SIGNÁLU**, uprav adresu na stránce kamery; SkyWatch DHCP změny nesleduje. Dej kamerám pevné IP.
