# Vzdálené kamery přes WireGuard

*[English](../vpn.md)*

Kameru jinde (chata, u rodičů, dílna) může Pi doma nahrávat, když se dostane do její sítě. Dvě možnosti:

1. **Řeší to router** (VPN mezi routery, nebo vzdálený router je dostupný). Pak jen přidáš kameru s její vzdálenou adresou – ve SkyWatch se nic nenastavuje.
2. **Pi je samo WireGuard klientem** vzdáleného routeru. Na to je **Nastavení → Síť a VPN**.

## Nastavení varianty 2

1. Na *vzdáleném* routeru (Mikrotik, OpenWrt, Fritz!Box, UniFi, Teltonika, …) vytvoř **WireGuard peer/klienta** pro Pi
   a stáhni vygenerovanou konfiguraci klienta (`[Interface] … [Peer] …`). Neupravuj ji.
2. SkyWatch → Síť a VPN → *Pro pokročilé: WireGuard tunel* – vlož **celou konfiguraci** a klikni **Uložit a aktivovat**.
3. Zadej IP vzdálené kamery do *Ověřit* (ping) – měla by odpovědět. Pak kameru přidej přes **Vyhledat kamery** se vzdálenou
   podsítí (např. `10.10.10.0/24`) nebo ručně `rtsp://10.10.10.4:554/…`.

SkyWatch je záměrně **split tunnel**: tunelem jde jen provoz ke vzdálené kameře; e-mail, AI, webhook i domácí síť jedou
normálně. Vloženou konfiguraci si proto upraví:

- vynechá `DNS`, `PreUp/PostUp/PreDown/PostDown`, `Table`, `SaveConfig`, `FwMark` (a řekne to);
- `AllowedIPs = 0.0.0.0/0, ::/0` nahradí konkrétními vzdálenými sítěmi (z `Address` tunelu a IP vzdálených kamer, kde to jde zúží na `/32`);
- odmítne konfiguraci, jejíž `AllowedIPs` by pohltily domácí síť nebo výchozí trasu;
- po startu ověří, že brána ani internet nejdou tunelem – jinak tunel zastaví a vrátí předchozí konfiguraci; watchdog totéž hlídá každou minutu i po restartu.

Privátní klíč je jen v `/etc/wireguard/wg-remote.conf` (root, 600). Při pozdější úpravě se zachová, dokud nevložíš nový; web ho nikdy neukazuje.

## Export / import

- **Export:** platná konfigurace (bez privátního klíče) je na stránce ke zkopírování; celý soubor je `/etc/wireguard/wg-remote.conf` na Pi.
- **Import:** vlož libovolnou klientskou konfiguraci z routeru nebo z `wg genkey` – standardní formát `wg-quick`.

## Když něco nejde

- *Ping nejde, ale RTSP ano* – některé kamery blokují ICMP; zkus kameru přidat i tak.
- *Tunel se sám zastaví* – konfigurace měla v `AllowedIPs` domácí síť nebo výchozí trasu; viz **Logy → VPN**.
- *Handshake se nedokončí* – špatný endpoint/port nebo firewall vzdáleného routeru; výstup `wg show` je na stránce Logy → VPN.
- Šířka pásma: vzdálenou kameru streamuj na 1–2 Mbit/s (případně substream jako hlavní); uplinky na chatách jsou malé.
