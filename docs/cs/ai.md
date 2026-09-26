# AI hlídání oblohy

*[English](../ai.md)*

Atmovio na Pi žádnou neuronovou síť nespouští. Pošle snímek hostovanému vizuálnímu modelu a zeptá se na jedno:
*jak zajímavá je tahle obloha a které z těchto jevů na ní opravdu vidíš?* Model vrátí skóre 0–10 a seznam jevů;
zbytek (epizody, odstupy, upozornění, video) dělá Atmovio.

## Klíč zdarma (Google Gemini)

1. Otevři [aistudio.google.com/apikey](https://aistudio.google.com/apikey), přihlas se Google účtem, **Create API key**. Bez platební karty.
2. Atmovio → **Nastavení → AI hlídání oblohy → 1 · Klíč k AI**, vlož klíč, **Uložit a ověřit klíč**.
3. Model nech na **auto** – Atmovio vybere nejnovější *Flash-Lite* model, který tvůj klíč může používat (největší denní limit zdarma, dnes ~500 dotazů/den), a při 404/429/503 přejde na jiný.
4. **Nejvíc dotazů na AI za den** nastav podle svého limitu; po jeho dosažení se Atmovio ten den už neptá.

Pozn.: v bezplatném tarifu může Google poslané snímky použít ke zlepšování modelů. Další poskytovatelé:

| Poskytovatel | Cena | Poznámka |
|---|---|---|
| Google Gemini | zdarma | výchozí, doporučeno |
| Groq (`https://api.groq.com/openai/v1`, Llama 4 Scout) | zdarma | poskytovatel „OpenAI-kompatibilní“ |
| OpenRouter | modely s příponou `:free` | OpenAI-kompatibilní |
| OpenAI `gpt-4o-mini`, Anthropic `claude-haiku-4-5` | placené, desítky Kč měsíčně při ~200 snímcích/den | nejpřesnější |
| Ollama na Pi (`moondream`, `qwen2.5vl:3b`) | zdarma, offline | pomalé (desítky sekund na snímek), méně přesné |

## Co hlídat (2 · Co hlídat)

Vyber kamery, které vidí oblohu, jevy, na které chceš upozornění, a **práh** (výchozí 7/10).
Katalog: červánky, shelf cloud / arcus, mammatus, beránky, bouřkový mrak, blesk, duha, halo / sluneční sloup,
krepuskulární paprsky, lentikulární mraky, mlha / inverze, nálevkový oblak / tornádo, wall cloud, roll cloud, asperitas,
kroupové / srážkové jádro, přeháňka, virga, silný déšť, sněžení, jiná zajímavá obloha.
Jevy přidané v nové verzi se u existující instalace jednorázově zapnou samy.

**Doplňující pokyny** pro model jsou volitelné (např. „kamera míří na západ, dole je střecha – ignoruj ji“).

V administraci je dostupný také **Jak funguje AI film?**: grafický průvodce, časová osa a ukázka různých intervalů.
Najdeš ho v nastavení AI i AI videí. Hodnoty v průvodci se neukládají; změny ve skutečném formuláři je nutné uložit.

## Sběr snímků a AI film (od 5.2)

V **Nastavení → AI detekce → Časování a AI film** zvol:

- **Používat AI film** a **Až po dokončení filmu**.
- **Snímek každých:** například 5 minut.
- **Délka AI filmu:** například 60 minut (10–180 minut).

Kamera nasbírá přibližně 13 snímků včetně začátku a konce hodiny. Teprve potom AI vyhodnotí celý průběh.
Další film už mezitím sbírá snímky; pomalá odpověď modelu sběr neblokuje. Každá kamera má vlastní posloupnost.
Hranice dvou filmů sdílí stejný okamžik. Časování se mění až od dalšího filmu; delší interval snímků než film se zkrátí na délku filmu.

**Upozornění má zpoždění až o délku filmu**, případně o čekání ve frontě. Hodinový film není okamžitý poplach.
Vypnutím denního omezení se sbírá i v noci. Při denním režimu se na konci světla uzavře i kratší film;
při delší mezeře ve snímcích se začne nový. Jediný snímek zůstane označen jako neúplný film, bez AI vyhodnocení.

V **AI detekci** jsou rozpracované filmy, počty snímků a plánovaný konec. **Otevřít AI film** umožní přehrávání
fotografií, posuvník, jednotlivé náhledy a jejich skutečné časy. U dokončeného filmu je také přesný obrázek odeslaný AI.
Při více než 36 snímcích dostane AI rovnoměrný výběr včetně prvního a posledního; označení **Podklad AI** ukazuje výběr.
Ostatní snímky zůstávají v archivu pro uživatele. Krátký jev mezi dvěma snímky nemusí být zachycen.

Stav i snímky přežijí restart. Denní limit zastaví pouze AI dotazy, sběr pokračuje a filmy čekají ve frontě.
Neúspěšná AI se zopakuje nejvýše dvakrát; pak lze použít **Zkusit vyhodnocení znovu**. Historie i čekající filmy
podléhají době uchovávání snímků. Při dlouho vyčerpaném limitu proto staré nevyhodnocené filmy mohou expirovat.

Původní režim **Při každém snímku s pohledem dozadu** lze znovu zvolit. V něm se AI ptá průběžně a přidává
starší snímky z paměti. Rychlý interval kolem východu/západu, přeskočení tmy a předfiltr nezměněného obrazu platí
pro tento režim a jednotlivé snímky. U dokončených filmů se tmavé i nezměněné snímky zachovávají.
Ruční test hodnotí aktuální pohled, nemění rozpracovaný film a neposílá upozornění.

Po aktualizaci je při zapnutém filmovém pásu výchozí nový režim dokončených filmů. Původní interval a délka filmu
zůstávají zachované. Starší hodnocení zůstávají dostupná včetně uloženého pásu; neuložené jednotlivé snímky zpětně vytvořit nelze.

## Upozornění, epizody, odstupy

- Detekce spustí upozornění, když **skóre ≥ práh** a aspoň jeden nalezený jev je mezi vybranými.
- **Epizoda:** stejný jev ze stejné kamery se hlásí jednou; znovu až poté, co zmizel a uplynul *odstup epizody* (výchozí 120 min). Nový jev v běžící epizodě upozornění vyvolá.
- **Odstup:** minimální rozestup upozornění z jedné kamery (výchozí 15 min).
- **Vyhodnotit oblohu teď** (ruční test) nikdy neposílá upozornění.
- Upozornění jde e-mailem a/nebo na [webhook](webhook.md) se snímkem a odkazem na detail detekce.

## Video podle události

V **Nastavení → AI videa** zapni automatické ukládání a vyber kamery. U dokončených filmů vzniká video podle
skóre a sledovaných jevů nezávisle na doručení e-mailu nebo odstupu upozornění. Průběžný režim zachovává původní
vytváření klipu po odeslaném upozornění.

AI označí první a poslední snímek události. Atmovio přidá sousední snímek jako rezervu nejistoty a nastavené
minuty před/po. Když model neurčí platný rozsah, použije se celý zachycený film. Pokud jev na posledním snímku
pokračuje, klip čeká na další film. Stejný navazující jev prodlouží tentýž klip; skončený nebo jiný jev původní klip uzavře.
Například červánky od 18:55 do 19:20 se mohou spojit přes hranici filmů v 19:00.

Čekání má pojistku: nejvýše délka dalšího filmu + 15 minut po posledním zachyceném snímku. Při výpadku se tedy uloží
dosud známý rozsah. Dlouhé události se ukládají v částech přibližně po šesti hodinách (na hranici filmu).
Navazující část může obsahovat překryv rezerv. Běžný záznam Frigate musí být na disku po celou dobu sběru,
vyhodnocení i čekání; bez něj fotografie samy kvalitní kamerové MP4 nenahradí.

Na detailu detekce lze přehrát a ručně vystřihnout rozsah události se zvolenými rezervami. V **AI videích** je vidět,
zda klip čeká na pokračování nebo už na export. U zdroje se uchovává souhrn AI z navazujících filmů pro návrh nadpisu
a popisu YouTube videa. Výsledek stále vychází z fotografií, nikoli z analýzy všech políček MP4.

### Celková délka a ruční korekce OD–DO

V **Nastavení → AI videa → Délka ukládaného videa** lze místo délky podle události zvolit **Pevná celková délka**
a zadat 1–120 minut. Počítá se od začátku jevu (u jednotlivého snímku od detekce) minus rezerva „Před detekcí“.
Rezerva před jevem je již součástí celkové délky; rezerva „Po detekci“ se nepřičítá. Při dalším pokračování jevu
vzniká další navazující pevně dlouhá část. Výchozí režim podle události zůstává zachován.

Na detailu detekce nebo u odkazu **Detekce** z uloženého videa nastav konkrétní **OD a DO** včetně data.
Změna pole délky přepočítá DO; ruční zadání obou časů přepočítá délku. Zvolený rozsah lze nejprve přehrát a potom
vytvořit jako nový klip, původní video se nepřepíše. Maximální ručně zadaný rozsah je 120 minut. Když DO ještě
nenastalo, klip čeká ve frontě na dokončení záznamu. Začátek musí být v minulosti. Časy používají pásmo zařízení,
ne pásmo počítače s prohlížečem; neexistující a opakované místní časy při změně letního času jsou odmítnuty.

Délka označuje **zdrojový záznam**. Při původní rychlosti má 120 minut záznamu i výsledné video 120 minut;
časosběr 25× má 4 minuty 48 sekund. Chybějící kamerový záznam se nedoplňuje ani nenahrazuje fotografiemi.

## Historie

Výchozí pohled ukazuje všechna hodnocení; lze filtrovat kameru, jev, skóre, datum a upozornění/chyby.
Čas hodnocení a časový rozsah snímků jsou uvedeny odděleně. Film lze smazat spolu s jeho snímky;
sousední film i již uložená videa zůstanou. Doba uchovávání historie a snímků je výchozí 14 dní.

## Ladění

- Moc upozornění? Zvyš práh na 8, odškrtni jevy, které tě nezajímají, prodluž odstup epizody.
- Ušlé západy? Sniž práh na 6, ověř, že okno je *nautický* a kamera opravdu vidí obzor.
- Kamera za šera přepne do IR/černobílé → to řeší filtr tmy; když přeskakuje moc brzo, sniž práh tmy (12–15).
- „Doplňujícími pokyny“ řekni modelu o trvalých objektech v záběru.
