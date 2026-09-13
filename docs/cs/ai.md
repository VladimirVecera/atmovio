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

## Kdy se dívá (3 · Jak často se dívat)

- **Okno:** od *svítání* do *soumraku* – občanský (slunce 6° pod obzorem, ≈ ±35 min), **nautický (12°, ≈ ±75 min, výchozí)** nebo
  astronomický soumrak, případně pevně ± minut kolem východu/západu. Potřebuje tvoje souřadnice (Pokročilé).
- **Běžný interval** (výchozí 10 min) a **rychlý interval** (výchozí 3 min) kolem svítání/soumraku a po zajímavém snímku.
- **Tmavé snímky** (průměrný jas pod prahem, výchozí 22/255) se přeskočí – bez dotazu, nic se neukládá.
- **Nezměněné snímky** (předfiltr – rozdíl oproti poslednímu vyhodnocenému snímku pod prahem) se přeskočí také.
- Odhad dotazů za den je ve formuláři; tabulka za 7 dní dole ukazuje skutečná čísla (dotazy, zajímavé, upozornění, přeskočeno, chyby)
  a nemění se při mazání historie.

## Upozornění, epizody, odstupy

- Detekce spustí upozornění, když **skóre ≥ práh** a aspoň jeden nalezený jev je mezi vybranými.
- **Epizoda:** stejný jev ze stejné kamery se hlásí jednou; znovu až poté, co zmizel a uplynul *odstup epizody* (výchozí 120 min). Nový jev v běžící epizodě upozornění vyvolá.
- **Odstup:** minimální rozestup upozornění z jedné kamery (výchozí 15 min).
- **Vyhodnotit oblohu teď** (ruční test) nikdy neposílá upozornění.
- Upozornění jde e-mailem a/nebo na [webhook](webhook.md) se snímkem a odkazem na detail detekce.

## Video automaticky (4 · Video automaticky)

Po upozornění může Atmovio sám vystřihnout úsek −N/+M minut kolem snímku (pro vybrané kamery, volitelně timelapse 25×).
Video vznikne, až uplynou minuty „po“; najdeš ho ve **Videích** se štítkem *auto* a u detekce je „video exportováno“.
Videa se mažou po době nastavené na stránce Videa (výchozí 30 dní).

## Historie a Přehled

- **Historie AI detekcí** ukazuje ve výchozím stavu detekce s upozorněním; přepni na všechna vyhodnocení nebo chyby.
- Detail detekce: snímek, přehrání záznamu kolem něj (výchozí −2/+1 min), okolní upozornění ze všech kamer, vystřižení videa.
- Snímky a historie se drží *keep_days* (výchozí 14); přeskočené snímky se neukládají nikdy.
- Stránka každé kamery ukazuje její čísla za 7 dní, poslední vyhodnocení a poslední upozornění.

## Ladění

- Moc upozornění? Zvyš práh na 8, odškrtni jevy, které tě nezajímají, prodluž odstup epizody.
- Ušlé západy? Sniž práh na 6, ověř, že okno je *nautický* a kamera opravdu vidí obzor.
- Kamera za šera přepne do IR/černobílé → to řeší filtr tmy; když přeskakuje moc brzo, sniž práh tmy (12–15).
- „Doplňujícími pokyny“ řekni modelu o trvalých objektech v záběru.
