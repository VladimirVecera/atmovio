# Contributing to SkyWatch

Thanks for helping! SkyWatch is a small project with a big goal: an NVR + sky watcher that a
non-technical person can install and understand. Every change should keep it that way.

*(Česky níže.)*

## Ground rules

- **Plain language first.** Every message the user can see must say what happened and what to do next,
  in words a non-technical person understands. No stack traces in the UI.
- **Never add a camera / setting that "probably works".** Streams are verified for real video frames
  before they are saved. Keep that standard for anything new.
- **One file app.** `src/skywatch/app.py` contains the app and its Jinja templates on purpose – it makes
  the single-file installer possible. CSS/JS live in `src/skywatch/static/`.
- **No personal defaults.** No hostnames, IPs, e-mails, tokens or coordinates of a real person in the code.
  Defaults must be neutral; the user fills in their own.
- **The installer must stay boring.** `sudo bash install.sh`, a handful of questions, done. Anything
  optional belongs into the web UI, not into the installer.

## Workflow

1. Fork, create a branch (`feature/…`, `fix/…`).
2. Edit sources in `src/` (never the generated `install.sh` / `update-skywatch.sh`).
3. Rebuild and check:
   ```sh
   python3 -m py_compile src/skywatch/app.py src/skywatch/storage_guard.py
   bash src/build.sh
   bash -n install.sh update-skywatch.sh
   ```
4. Test on a real Raspberry Pi 5 if the change touches the installer, Frigate config, disks or VPN.
   For UI-only changes a local run is fine: `SKYWATCH_DIR=/tmp/sw SKYWATCH_PORT=8099 SKYWATCH_ADMIN_PASSWORD=… python3 src/skywatch/app.py`.
5. Bump `APP_VERSION` in `app.py` for user-visible changes and add a line to `CHANGELOG.md`.
   (Maintainer: a release is a tag `v<APP_VERSION>` on `main` – the Release workflow attaches `install.sh`,
   `update-skywatch.sh` and `SHA256SUMS`; installed SkyWatch instances offer that release in the web UI.)
6. Open a pull request. Describe *what the user will notice*, not only what the code does.
   Screenshots of UI changes are very welcome.

## Good first contributions

- camera models: report what worked / did not in an issue (`Cameras` label) – RTSP paths, ONVIF quirks
- translations of the UI (an i18n layer is the first step – open an issue to coordinate)
- new sky phenomena for the AI catalogue (`PHENOMENA` in `app.py`) with a short description
- Home Assistant / Node-RED examples using the [REST API](docs/api.md)
- more webhook receivers (Node, Python, static site generators) in `examples/`

## Reporting bugs

Use the issue template. Attach the log from **Logy → Stáhnout** (SkyWatch and, if relevant, Frigate),
your camera model and the exact text of the message you saw. Remove passwords and tokens from logs
(the app masks them, but double-check).

---

# Přispívání (česky)

Díky! SkyWatch je malý projekt s velkým cílem: NVR a hlídání oblohy, které si nainstaluje a pochopí
i člověk bez IT vzdělání. Každá změna to má zachovat.

- **Srozumitelnost především.** Každá hláška musí říct, co se stalo a co dál, lidsky. Žádné výpisy chyb v UI.
- **Nic se nepřidá, když to „asi funguje“.** Streamy se před uložením ověřují na skutečné snímky.
- **Aplikace v jednom souboru** (`src/skywatch/app.py` včetně šablon) – kvůli instalátoru v jednom souboru.
- **Žádné osobní výchozí hodnoty** (adresy, e-maily, tokeny, souřadnice konkrétního člověka).
- **Instalátor zůstává nudný.** Pár otázek a hotovo; volitelné věci patří do webu.

Postup: fork → větev → úpravy v `src/` → `bash src/build.sh` → `bash -n install.sh update-skywatch.sh` →
test na RPi 5 (pokud se týká instalace, Frigate, disků nebo VPN) → zvýšit `APP_VERSION`, řádek do
`CHANGELOG.md` → pull request s popisem, co uživatel pozná.
