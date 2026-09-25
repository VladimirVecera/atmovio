# Atmovio 5.0

## Kde co najdu

| Sekce | Obsah |
|---|---|
| Dashboard | Stav kamer, nedávná AI hodnocení, AI klipy, YouTube výstupy, úložiště a systém |
| Živý přenos | Živý obraz všech kamer a detail jedné kamery |
| AI detekce | Všechna vyhodnocení, filtry kamera/jev/skóre/datum/upozornění/chyba, snímek a AI film |
| AI videa | Zdrojové klipy, čekající a neúspěšné automatické exporty, přehrání a stažení |
| YouTube videa | Zrychlené výstupy, nadpis a popis, intro/hudba, stav vytváření a nahrávání |
| Nastavení | Kamery, AI detekce, AI videa, YouTube videa, úložiště, upozornění, síť, systém a diagnostika |

Nastavení AI videí mění pouze automatický výstřih a dobu uchovávání. Nemění poskytovatele AI, zapnutí
hlídání ani pravidla kamer. YouTube nastavení mají tři záložky: podoba videa a automatika, intro a hudba,
propojení YouTube. Externí nástroje (Frigate, Cockpit, Portainer) jsou dostupné v nabídce účtu vpravo nahoře.

## Nadpis a popis z AI filmu

AI kontrola uloží popis jevu a u filmového pásu také popis vývoje, počet snímků a časový rozsah.
Zdrojový export si uchová kopii tohoto vyhodnocení. Zůstane dostupná i po vymazání detekce nebo její retenci.

U jednotlivého videa nabídne tlačítko **Navrhnout nadpis i popis z AI filmu** návrh ke kontrole.
**Použít návrh** vloží oba texty do formuláře; poté je potřeba uložit změny nebo vytvořit video.
Samotné získání návrhu nepřepíše uložené texty. Automatické studio může připravit nadpis a popis samo;
při nedostupnosti poskytovatele použije obě nastavené šablony. Návrh představuje další textový požadavek
na nastaveného poskytovatele AI. Popis vývoje při detekci je součástí původního obrazového požadavku.

Jde o analýzu vybraných snímků. Atmovio tímto neposílá AI výsledné MP4. Vývoj z hodinového pásu nesmí být
vydáván za děj pětiminutového klipu: pokud pás neleží celý uvnitř klipu, jeho vývoj ani trend se do návrhu
nepředají. Starší hodnocení bez přesných časů použijí popis tehdejšího snímku. Text před publikací zkontroluj.

## Uchovávání a mazání

Zdrojové klipy a výstupy studia mají společnou dobu uchovávání v Nastavení → AI videa.
Snímky a průběžné nahrávání mají samostatnou retenci. Aktivně zpracovávaná nebo nahrávaná videa a jejich
zdroje se nemažou pod běžícím úkolem. Po dokončení je můžeš smazat. Smazaný automatický výstup se znovu
sám nevytvoří; nový lze výslovně zadat ze zachovaného AI klipu. Mazání místních souborů nemaže video na YouTube.

## Vydání na GitHub

V kořeni projektu na Macu, po kontrole změn:

```sh
bash src/build.sh --check && git diff --check && git add -A && git commit -m "5.0: redesigned administration and filmstrip-based video titles and descriptions" && git push && git tag v5.0 && git push origin v5.0
```

Tag odpovídá `APP_VERSION = "5.0"`. GitHub Actions z něj vytvoří release s instalačním a aktualizačním
skriptem a kontrolními součty. Samotný push aplikaci na RPi ještě neaktualizuje.

Na RPi po dokončení GitHub Release použij **Nastavení → Systém → Aktualizace**, případně přes SSH:

```sh
curl -fsSL -o update-atmovio.sh https://github.com/VladimirVecera/atmovio/releases/download/v5.0/update-atmovio.sh && sudo bash update-atmovio.sh
```

Aktualizace zachová existující konfiguraci a přidá nové databázové sloupce. Před přechodem na hlavní verzi
si ulož kopii `/opt/nvr/atmovio/config.json` a konzistentní zálohu `atmovio.db`; automatická obnova programu
není úplná záloha uživatelských dat.

## Ověření

Lokální kontrola bez kamer a externích služeb:

```sh
python3 -m pip install -r src/atmovio/requirements.txt httpx
python3 tests/regression.py
bash src/build.sh --check
bash -n install.sh update-atmovio.sh
```

Testy používají dočasnou konfiguraci a databázi. Ověřují přihlášení a CSRF, izolaci nastavení, migraci
z předchozího schématu, přejmenování kamer, filmový pás, metadata a jejich záložní šablony, mazání a
vykreslení stránek s daty i bez nich. Lokální prohlížeč byl ověřen na desktopu, tabletu a mobilní šířce.

Fyzické RPi 5, konkrétní ONVIF kamery, dlouhodobé nahrávání na HDD, výstup FFmpeg a skutečné nahrání na
YouTube vyžadují kontrolu na cílovém zařízení. Po aktualizaci ověř živý obraz, pokračující záznam,
jednu AI kontrolu s pásem, vytvoření klipu a jedno neveřejné YouTube video. Lokální testy tyto služby simulují.
