<p align="center"><img src="docs/img/atmovio-logo-wide.png" width="360" alt="Atmovio"></p>

<p align="center"><b>Vaše kamery. Okamžiky, které stojí za uložení.</b><br>Živý obraz, záznamy a tvorba časosběrů na Raspberry Pi 5.</p>

<p align="center"><a href="README.md">English</a> · <a href="docs/cs/instalace.md">Instalace</a> · <a href="https://github.com/VladimirVecera/atmovio/releases/latest">Stáhnout</a> · <a href="https://www.atmovio.com/">Web</a></p>

![Nové rozhraní kamer Atmovio](docs/img/v6/cameras.png)

- **Sledujte a vraťte se v čase.** Otevřete kameru, projděte záznam a označením OD–DO uložte klip.
- **Zachovejte zajímavé okamžiky.** Volitelné hlídání oblohy hledá události. Překrývající se automatické klipy ze stejné kamery spojí, pokud je původní záznam dostupný.
- **Vytvořte video.** Vyberte střih, rychlost, hudbu, intro, text nebo výzvu k odběru a sdílení. Projekt můžete uložit a později znovu upravit.
- **Sdílejte hotový výsledek.** Pusťte si náhled, stáhněte MP4 nebo video nahrajte na svůj YouTube kanál.

<details><summary>Podívat se na video editor</summary>

![Atmovio Studio](docs/img/v6/studio.png)

</details>

## Začínáme

Raspberry Pi 5 · 64bit Raspberry Pi OS · USB disk · RTSP kamera. Podrobnosti: [hardware](docs/cs/hardware.md) a [podporované kamery](docs/cs/kamery.md).

```sh
curl -fsSL -o install.sh https://github.com/VladimirVecera/atmovio/releases/latest/download/install.sh
sudo bash install.sh
```

Po instalaci otevřete vypsanou adresu. Rozhraní je česky. Nahrávání funguje bez AI účtu; pro cloudové AI je potřeba vlastní klíč poskytovatele a jeho služby mohou být placené.

**Atmovio 6.0.5** obsahuje Frigate 0.18.2, ověření konfigurace a zálohu pro návrat při chybě. Starší instalaci aktualizujete v **Nastavení → Systém → Aktualizace → Zkontrolovat teď**. Obrázky používají ukázková data. [Co vědět před aktualizací →](docs/cs/verze-6.0.md)

## Další informace

[Instalace](docs/cs/instalace.md) · [Hlídání oblohy](docs/cs/ai.md) · [YouTube](docs/youtube.md) · [API a Home Assistant](docs/cs/api.md) · [Řešení potíží](docs/cs/faq.md)

[Změny verzí](CHANGELOG.md) · [Jak přispět](CONTRIBUTING.md) · [Licence MIT](LICENSE) · [Podpořit vývoj](https://www.atmovio.com/donate/)
