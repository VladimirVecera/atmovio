# Atmovio 6

Hlavní nabídka má čtyři místa: **Kamery, Okamžiky, Moje videa a Studio**. Hudba, nastavení a diagnostika jsou ve spodní části nabídky. Technické podklady AI zůstávají v rozbalitelných detailech.

## Kamera a záznam

Kliknutím na náhled otevřete živý přenos. Pod přehrávačem vyberte den a modrý úsek časové osy. Označte **OD**, přejděte na konec a označte **DO**. Výběr lze přehrát a uložit. Klávesy I a O označují hranice; datum a čas používají časové pásmo zařízení.

Jeden výběr může mít nejvýše šest hodin. Mezery na ose znamenají chybějící záznam. U výběru s mezerou lze zkrátit rozsah nebo výslovně potvrdit uložení dostupných částí. Časová osa při přehrávání zohledňuje přeskočené výpadky. Dostupná minulost závisí na uchovávání záznamů a volném místě.

## Okamžiky a Studio

Okamžiky ukazují hotové klipy. Další zajímavé nálezy obsahují vybraná hodnocení AI. Surová historie a fotografie slouží hlavně při hledání problémů.

Překrývající se automatické klipy stejné kamery se spojují do jednoho rozsahu, nejvýše šest hodin. Například 10:00–12:20, 10:50–13:00 a 12:00–13:30 vytvoří 10:00–13:30. Staré klipy se skryjí až po dokončení spojeného videa. Pokud původní záznam už chybí, zůstanou původní klipy dostupné. Zdroje uložených projektů se automatickým úklidem neodstraňují; prostor lze uvolnit ručně.

Studio nabízí střih, rychlost 1× nebo časosběr 10–240×, hudbu s přehrávačem a volbou začátku, vlastní intro, text a výzvu k odběru či sdílení. Náhled zdroje slouží k výběru střihu; celý výsledek s efekty a hudbou je dostupný po přípravě videa. Uložený projekt lze znovu otevřít. Úprava hotového videa vytvoří další verzi; již publikované video se samo nezmění.

## Aktualizace a diagnostika

Aktualizátor stáhne Frigate 0.18.2 a ověří kopii konfigurace za běhu staré verze. Před přepnutím zálohuje konfiguraci i zastavenou databázi. Během restartu vznikne krátká mezera v nahrávání. Nová verze musí potvrdit API a obraz dříve dostupných kamer; při selhání se obnoví původní Frigate i jeho databáze. Záznamy na datovém disku se nepřesouvají.

Zálohy jsou v `/opt/nvr/atmovio/backups/`. Pro diagnostiku slouží seskupené chyby, označení vyřešených problémů a export JSON. Nový výskyt vyřešené chyby ji znovu zobrazí. Export maskuje přístupové údaje a e-maily; před zveřejněním zkontrolujte také volný text.
