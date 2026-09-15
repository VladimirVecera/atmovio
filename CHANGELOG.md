# Changelog

All notable changes to Atmovio (versions ≤ 3.4 were released under the name SkyWatch). Versions correspond to `APP_VERSION` in `src/atmovio/app.py`.

## 4.4.2 – 2026-09 – readable logs

- **Logs made readable**: every Atmovio log line gets a level and a plain-language explanation – ✖ needs action,
  ⚠ worth a look, ◌ transient (hosting or AI provider hiccup that resolved itself), · normal. The summary counts only
  real problems; a hosting timeout is no longer an "error". "Surový text" toggle keeps the raw log.
- **Report a bug**: when the log contains errors, a "Nahlásit chybu na GitHub" button opens a pre-filled issue with
  the error lines and version (nothing personal).
- Logs: "Vymazat tento log" moved to the page header instead of dangling under the toolbar.
- Release workflow updates an existing release instead of failing when a tag is force-pushed.

## 4.4.1 – 2026-09 – camera page cleanup, stuck exports

- **Camera page is a dashboard only** – no forms; "Upravit kameru" opens the edit form on Nastavení → Kamery
  (`/cameras/edit/<id>`), AI is configured on one place in Nastavení → AI.
- **Stuck video exports** (Frigate restarted mid-export, "vytváří se…" for days) are flagged after 2 hours with
  "Vytvořit znovu" (re-submits the same range) and delete buttons, on Videa and on the camera page.
  When the recording for that range is already gone (retention), the export says so and offers delete only.
## 4.4 – 2026-09 – AI settings for humans

- **AI settings rebuilt** into five tabs: Who evaluates · Cameras and phenomena · When to look · Automatic video ·
  Test and statistics. One "Save" bar saves everything; the page stays on the tab you were on.
- **Per-camera rules**: every camera has its own "AI watches" switch, and either the default settings or its **own threshold
  and own list of phenomena** (e.g. a good west-facing camera alerts from 7/10, a poorer north one from 5/10). Automatic
  video is switched per camera too.
- **"Anything photogenic"** – a separate switch (default on, also per camera): alert even when none of the selected
  phenomena matched but the AI scored the view above the threshold. "Jiná zajímavá obloha" renamed to
  "Fotogenická / zajímavá obloha".
- **Custom phenomena**: add your own (name + description for the AI, e.g. "contrails"); the AI looks for them on every
  snapshot and they can be selected like the built-in ones.
- History page has a button to the AI settings; score badges use the camera's own threshold.
## 4.3 – 2026-09 – history, disk and log polish

- **History page** rebuilt: button filters (alerts / all / errors · camera · min. score), one row per evaluation grouped
  by day with the full AI text and a colour score badge, 30 rows per page with paging; delete actions moved to the page header.
- Dashboard shows an available update in the Raspberry Pi tile and in the System box (also in `/api/v1/status` → `update`).
- Sunrise/sunset are highlighted in the header strip, dawn/dusk muted.
- S.M.A.R.T.: a disk is no longer listed twice after `/dev/sdX` names swap on reboot (keyed by serial/model, one row per role).
- S.M.A.R.T.: a disk with ≥ 200 reallocated sectors is flagged as worn ("plan a replacement") even when the count is stable.
- Webhook heartbeat: a hosting hiccup shorter than 3 minutes is no longer logged; longer outages log start and end with duration.
- systemd unit files get mode 644 before `daemon-reload` – no more "world-inaccessible" warnings in the system log.

## 4.2 – 2026-09 – AI in focus

- **AI in focus**: every camera card on the dashboard shows the latest AI evaluation of that camera with score,
  phenomenon and the model's description (also below the threshold), with links to the detail and the camera's history.
  The events feed is gone; "Recent sky alerts" (with the AI text) sits above the storage / AI / system boxes.
- **AI provider chooser**: Gemini, Groq/OpenRouter, Claude, OpenAI and Ollama as cards with price, free limits, accuracy,
  where to get the key and recommended models (still editable by hand).
- Detection page plays the **exported clip** when one exists (smooth, seekable); the raw Frigate segment is used only for a
  custom range, with an explanation why its time may jump.
- Camera fps badge explains that 5 fps is the preview/AI stream; recording keeps the camera's full quality.
## 4.1 – 2026-09 – new admin design

- **Redesigned web UI.** Horizontal menu in the header (Přehled · Kamery · Záznamy · Detekce a AI · Videa · Nastavení ▾ · Nástroje ▾),
  quick actions (live view, add camera), account menu with update notice and logout. No more sidebar.
- **Dark and light mode** with a switch in the header (remembered in the browser; dark is the default).
- **New dashboard**: hero strip with date/time and sun times, KPI tiles with coloured icons (cameras, storage, AI detections,
  alerts, Raspberry Pi), camera cards with live/settings buttons and an "add camera" card, recent events feed, storage ring,
  AI today with 7-day statistics, system tiles.
- Unified cards, tables, forms and buttons across all pages; camera cards on the Kamery page got action buttons.
- Help section links to the REST API / Home Assistant guide on atmovio.com.

## 4.0 – 2026-09 – renamed to Atmovio

- **SkyWatch is now Atmovio** (the old name collides with existing products). Everything is renamed: repository
  `VladimirVecera/atmovio`, install dir `/opt/nvr/atmovio`, service `atmovio.service`, `update-atmovio.sh`,
  env `ATMOVIO_DIR`, new API keys start with `at_` (old `sw_` keys keep working).
- The updater migrates an existing SkyWatch 3.x install in place (moves the directory, renames the service,
  database, log and snapshot folder, rewrites `config.json`); configuration, cameras, detections and videos are kept.
  Releases also ship `update-skywatch.sh` (same file, old name) so 3.2–3.4 installs can update from the web UI.
- Webhook heartbeat sends `atmovio_url` and, for older receivers, `skywatch_url` with the same value.
- New logo.

## 3.4 – 2026-09

- Systém page: wider cards; the API card explains where the outgoing webhook (data + alerts to your website) is configured.
- Docs: hardware page (supported Pi, parts, disk sizing), README hardware and AI sections, full REST API field reference
  and the REST-vs-webhook overview.

## 3.3 – 2026-09

- Webhook heartbeat carries `api`: a snapshot of everything the REST API returns (status, cameras, notified
  detections, videos, events – identical fields) plus thumbnails of new detections/videos, so a website that
  cannot reach the Pi can show the same data. `status.ai.threshold` added to the API.

## 3.2 – 2026-09

- Update from the web UI: Atmovio checks GitHub Releases once a day (can be turned off), shows a banner when a
  newer version exists, and installs it on one click (Nastavení → Systém → Aktualizace) – downloads
  `update-atmovio.sh` from the release, verifies SHA-256 against `SHA256SUMS`, runs it as a separate systemd unit
  and shows progress/result; the existing automatic rollback applies.
- `GET /api/v1/status` reports `update.latest` / `update.available`.
- Release workflow: pushing a `v*` tag builds a GitHub release with `install.sh`, `update-atmovio.sh` and `SHA256SUMS`.

## 3.1 – 2026-09

- Open-source release: generic webhook (any website), example PHP receiver, read-only REST API with API keys,
  documentation in English and Czech.
- Per-camera page: live view, status, AI toggles, detections, videos and stream settings in one place.
- Cameras overview with large auto-refreshing snapshots; live MJPEG on demand (single camera or all).
- Automatic video export after an alert (per camera, −N/+M minutes, optional 25× timelapse).
- In-browser video player with speeds up to 120×; range requests for seeking.
- AI watching from dawn to dusk (civil/nautical/astronomical twilight), dark-frame skipping,
  independent daily statistics (7-day table), skipped frames no longer stored.
- History shows notified detections by default and marks exported videos.
- Updater keeps only the last two backups and removes orphaned virtualenvs.
- New logo, favicon fix, nicer date formats everywhere.

## 3.0 – 2026-09

- New UI (Pico CSS + Alpine.js, dark mode, mobile bottom bar), settings grouped under "Nastavení".
- Detection detail with clip playback, neighbouring alerts and clip export; videos page.
- SMART disk monitoring with trend-based warnings; storage guard; VPN split-tunnel normalisation.
- Camera discovery verifies real frames from every stream; Frigate reads cameras directly.

## 2.x and earlier

Internal versions before the public release.
