# Časté dotazy

*[English](../faq.md)*

**Potřebuje to internet?** Nahrávání ne. AI hlídání oblohy ano (hostované modely), pokud nepoužiješ Ollamu na Pi. Upozornění e-mailem/webhookem ano.

**Kolik disku?** Součet bitrate kamer v Mbit/s × 10,8 ≈ GB za den. Čtyři kamery po 4 Mbit/s ≈ 173 GB/den ≈ 1,2 TB za týden.
Podle toho nastav retenci (instalátor / Záznamy a disk). Vystřižená videa mají vlastní retenci (Videa).

**Stačí SD karta?** Pro systém ano; záznamy potřebují USB HDD (SD karty od stálého zápisu umírají). Bez disku běží SkyWatch v režimu živého náhledu.

**Detekuje lidi/auta?** Ne – detekce objektů Frigate je záměrně vypnutá (na Pi není akcelerátor). SkyWatch je o obloze. Ve Frigate si ji můžeš zapnout sám, za cenu CPU.

**Proč HTTP bez certifikátu?** Běží v tvé LAN; vlastní certifikát by jen vyvolával varování prohlížeče. Pro přístup zvenku použij VPN; nikdy port-forward.

**Které kamery fungují?** Cokoli s RTSP H.264/H.265. Viz [kamery.md](kamery.md) a issues *Cameras* na GitHubu.

**Kolik kamer Pi 5 zvládne?** Nahrávání je jen kopírování, limitem je dekódování substreamů pro náhled: 4–6 kamer se substreamy 640×360 je v pohodě. Sleduj teplotu na Přehledu.

**Odchází moje video někam?** Jen jednotlivé snímky k poskytovateli AI, kterého sis nastavil, a na tvůj webhook, pokud je zapnutý. Záznamy Pi nikdy neopustí.

**Limity AI zdarma?** Google Gemini Flash-Lite zdarma je pár set dotazů denně; SkyWatch se zastaví na nastaveném denním limitu a přeskakuje nezměněné/tmavé snímky.

**Jak zálohovat?** `/opt/nvr/skywatch/config.json` (nastavení), `/opt/nvr/frigate/config/config.yml` (kamery), `/etc/wireguard/wg-remote.conf` (VPN). Záznamy jsou na HDD.

**Aktualizace se nepovedla?** Aktualizátor se vrátí sám; zálohy jsou v `/opt/nvr/skywatch/backups/`. Ruční obnova: zkopíruj `app.py` ze zálohy a `systemctl restart skywatch`.

**Kde jsou logy?** Stránka **Logy** (tlačítko Stáhnout), nebo `journalctl -u skywatch -n 200`.

**Anglické rozhraní?** Zatím ne – dokumentace je dvojjazyčná, rozhraní české. Příspěvky k i18n vrstvě vítány.
