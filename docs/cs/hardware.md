# Hardware

*[English](../hardware.md)*

## Podporovaný počítač

| | |
|---|---|
| **Raspberry Pi 5** – minimálně 4 GB, **doporučeno 8 GB** | jediná testovaná a podporovaná deska. Instalátor vyžaduje 64bit ARM (`aarch64`) a varuje, když nejde o Pi 5. |
| Raspberry Pi 4 | nepodporováno: Frigate 0.17 na něm běží, ale dekódování sub streamů pro náhledy a snímky pro AI jdou přes CPU a USB 3 je na pomalejší sběrnici. Když to zkusíš, počítej s 1–2 kamerami a napiš výsledek do issue na GitHubu. |
| x86 / jiné SBC | nepodporováno (instalátor, výběr disku a hlídač úložiště jsou psané pro Raspberry Pi OS). |

Proč Pi 5: nahrávání je **jen kopírování** (Frigate ukládá H.264/H.265 přímo z kamery, nic se nepřekódovává), takže procesor
zatěžuje hlavně dekódování malých sub streamů pro živý náhled a jeden snímek v plném rozlišení z každé kamery jednou za pár minut
pro AI. Pi 5 zvládne v pohodě 4–6 kamer se sub streamem 640×360; teplotu hlídej na Přehledu.

## Co potřebuješ

| Část | Požadavek | Poznámka |
|---|---|---|
| **Systém** | Raspberry Pi OS **Lite 64-bit** (Debian 12 nebo 13) | Desktop verze funguje taky, ale není potřeba. |
| **Systémový disk** | doporučeno NVMe/USB SSD; SD karta (A2, 32 GB+) funguje | Je tu jen systém, obrazy Dockeru (~2 GB) a malá databáze Atmovio. |
| **Disk pro záznamy** | **USB 3 pevný disk**, ext4 | Instalátor ho najde, systémový disk nikdy nesáhne, existující ext4 použije, jinak formátuje až po napsání `SMAZAT`. Jsou na něm jen záznamy; když zmizí, Atmovio běží dál v živém náhledu a upozorní tě. |
| **Zdroj** | oficiální **27W** zdroj pro Pi 5 | Nutný pro 2,5" disk napájený z USB; jinak použij disk s vlastním napájením. Slabý zdroj se projevuje náhodným odpadáváním disku. |
| **Chlazení** | aktivní chladič nebo krabička s ventilátorem | Neustálé dekódování čip hřeje; Přehled ukazuje teplotu a varuje od 80 °C. |
| **Síť** | **kabelový Ethernet** | Kamery streamují nepřetržitě; výpadky Wi-Fi se projeví jako výpadky kamer. |
| **Kamery** | libovolná IP kamera s **RTSP** (H.264 nebo H.265), nejlépe ONVIF | Hlavní stream pro záznam, sub stream (≈640×360) pro náhledy. Hledání používá ONVIF + sken portů; každý stream se před uložením ověří na skutečné snímky. Viz [kamery.md](kamery.md). |
| **Vzdálená kamera** | dostupná přes **WireGuard** | Atmovio tunel spravuje a chrání trasu do domácí sítě. Viz [vpn.md](vpn.md). |
| **Internet** | pro AI a upozornění | Nahrávání funguje i bez něj. AI potřebuje hostovaný model (nebo Ollama lokálně, pomalé); e-mail/webhook potřebují odchozí HTTPS/SMTP. |

## Jak velký disk

Při kopírování bez překódování roste disk přesně o datový tok kamer: **Mbit/s všech kamer × 10,8 ≈ GB za den**.

| Kamery | Typický tok | Za den | 7 dní | 14 dní |
|---|---|---|---|---|
| 1 × 1080p H.265 | 2 Mbit/s | 22 GB | 150 GB | 300 GB |
| 2 × 1080p H.264 | 2 × 4 Mbit/s | 86 GB | 600 GB | 1,2 TB |
| 4 × 2K H.265 | 4 × 4 Mbit/s | 173 GB | 1,2 TB | 2,4 TB |

Uchovávání se nastavuje ve dnech (instalátor, později *Záznamy a disk*); Frigate nejstarší hodiny maže sám. Vystřižená videa
mají vlastní dobu uchování na stránce *Videa*.

## Zdraví disku

Atmovio čte S.M.A.R.T. každou hodinu (systémový disk i disk pro záznamy včetně USB boxů) a hlásí srozumitelně: stálý počet
nečitelných sektorů bere jako jednorázovou chybu (typicky tvrdé vypnutí), rostoucí počet zčervená. Služba `storage guard`
pouští Frigate až po ověření, že je HDD zapisovatelný, takže chybějící nebo umírající disk nikdy nezaplní systémové SSD.

## Otestovaná sestava

Raspberry Pi 5 8 GB, Raspberry Pi OS Lite 64-bit na USB SSD, 4 TB USB 3 HDD (WD Red), dvě ONVIF kamery (jedna v LAN,
druhá za WireGuard site-to-site tunelem), Google Gemini bezplatný tarif pro AI. Zátěž v klidu ≈ 0,5, teplota 40–50 °C s aktivním chladičem.
