# Changelog

All notable changes to Atmovio (versions ≤ 3.4 were released under the name SkyWatch). Versions correspond to `APP_VERSION` in `src/atmovio/app.py`.

## 5.3.5 – 2026-09-26 – visible AI video progress

- Show recording wait, export progress, saved files and failures directly above detection details and in detection history.
- Highlight pending videos with dated deadlines; distinguish export scheduling from completion.
- Preserve links from continuing AI detections to their shared video, including fixed-length clips.
- Refresh detail status without reloading the page or resetting edited video ranges.

## 5.3.4 – 2026-09-26 – grouped sky and timelapse phenomena

- Add 23 cloud, optical, night-sky and temporal categories in compact groups, including custom camera rules.
- Preserve existing selections; new installations include the extended catalog by default.
- Require time-series evidence for motion categories and reject those IDs from single-image responses.
- Ask for timelapse reasoning and observed frame bounds; distinguish camera artifacts from weather.

## 5.3.3 – 2026-09-26 – timelapse rule in AI detection

- Move the timelapse trigger and score threshold into AI detection → Cameras and phenomena.
- Preserve existing values and prevent video-settings saves from changing the detection rule.

## 5.3.2 – 2026-09-26 – consistent AI navigation and timelapse triggers

- Keep AI detection and video settings connected with shared navigation; strengthen primary and settings menus.
- Add an opt-in, independent timelapse score threshold for automatic clips from completed films.
- Ask AI to assess observed cloud motion and development separately from single-scene interest.
- Preserve selected cameras, clip duration, event continuity and notification rules; fix update-button contrast.

## 5.3.1 – 2026-09-26 – compact administration and redesigned system navigation

- Shorten administration labels and page introductions; move optional explanations into accessible disclosures
  across cameras, AI, storage, live view, videos, studio, system and diagnostics. Keep critical warnings visible.
- Replace widely spaced internal tabs with a compact sidebar, clear selected page and dedicated content heading.
- Share the navigation across overview, access, integration, maintenance and update pages; use a compact mobile grid.
- Put the primary Atmovio password form first and constrain its width for readable, consistent settings.
- Simplify AI timing into interval, frame capacity and editable auto-calculated duration, alongside a live
  contact-sheet layout, pixel dimensions and effective evaluation time. Recommended values fill only the draft.

## 5.3 – 2026-09-26 – clearer administration and bounded AI evidence

- Separate system overview, passwords, API integration and maintenance into dedicated pages; preserve existing actions.
- Correct mounted-disk messaging during recorder transitions. Never offer formatting merely because usage statistics
  are unavailable for a mounted recording disk. Log storage transitions and expose actual probe failures and timeouts.
- Poll recorder readiness and restart acknowledgement; refresh recovered status pages without discarding edited forms.
  Failed camera images recover automatically and show a single illustrated placeholder. Failed video cards explain causes.
- Show diagnostic entries newest first while preserving multiline details. Improve file inputs and laptop action layouts.
- Review missing optional music, intro, title, description and enabled-but-empty overlay text before studio creation.
- Configurable maximum frames per completed AI film. The 5-minute / 40-minute / 9-frame preset keeps evidence compact;
  films end at the earlier of the duration or frame limit, with the boundary snapshot starting the next film.
  Contact sheets with up to 9 frames use 720×405 photo areas; larger sets retain 480×270. Existing films finish unchanged.
  The compatibility default is 36 frames; long, dense future films can now close earlier to respect that limit.
- Offline checks cover timing boundaries, diagnostics, subpages, and responsive browser interactions.

## 5.2.1 – 2026-09-26 – reliable update progress

- Escape version and log JSON in the updater's HTML attribute so progress tracking initializes correctly.
- Show completion and the running version at the top without a manual refresh. Confirm success only after
  the installer exits with its HTTP health-check success marker; expose failure and unconfirmed outcomes honestly.
- Recover polling across restarts with request timeouts, a prolonged-outage message and an explicit login link
  when the session expires. Recover the last result after reopening the page.

## 5.2 – 2026-09-26 – completed AI films and continuous event clips

- Separate snapshot collection from AI evaluation: completed-film mode is the new default for enabled filmstrips.
  Existing sample intervals and film durations remain; new installations default to 5-minute samples / 60-minute films.
  The previous rolling-window mode remains selectable in Settings → AI → Timing and AI film.
- Persist per-camera films and samples across restarts. Collect the next film while background inference processes
  the previous one. Daily AI limits pause inference, not collection; provider failures retry twice and remain visible.
- Show ongoing films in AI detections, chronological snapshot playback, exact timestamps, selected AI frames and the
  actual contact sheet sent to the provider. At most 36 evenly spaced frames are submitted; all collected frames remain viewable.
- Evaluate the whole film, including events that ended before its last frame. Validate model frame indices and pad
  event boundaries with neighbouring samples. Missing boundary evidence falls back to the full observed film.
- Create interesting-film clips independently of email delivery and notification cooldown. Join continuing matching
  events across adjacent films; finalize when the event ends, on continuation timeout, or in bounded six-hour parts.
  Keep accumulated AI evidence with the exported source for subsequent title/description generation.
- Optional fixed-length source clips (1–120 minutes, including the before-margin) for both AI modes.
  Exact device-local date/time OD–DO controls preview or create a corrected clip; a future end queues creation.
  Corrections preserve existing videos. Invalid/reversed/overlong and ambiguous DST ranges are rejected.
- Manual clip playback/export uses the observed event range for completed films. Legacy detection and clip behavior
  remains available. Night/outage partial films are explicit; historical unsaved frames cannot be reconstructed.
- Plain-language illustrated guide inside AI/video settings, with a non-saving timing simulator and a live
  explanation beside the real timing fields. Covers overlapping events, fixed clip length, OD–DO and YouTube.
- Offline tests cover sampling, restart, quotas, slow inference, retries, hour-boundary episodes, immutable evidence,
  authenticated playback/deletion and migration. Installer and updater regenerated.

## 5.1 – 2026-09-25 – polished administration and forms

- Compact desktop header with a single horizontal navigation row, quieter service status and a separate account/tools menu.
  Original logo retained; mobile navigation and account dropdown work independently.
- Consistent form controls, labels, spacing, focus states, tabs and save bars across the administration.
  Camera, AI-provider, AI-video and YouTube-default forms now use explanatory sections with related fields aligned together.
- Accessible label associations for existing forms, labelled navigation controls, light/dark themes and responsive layouts.
  Field names, save actions and recording/AI/video processing behavior remain unchanged.

## 5.0 – 2026-09-25 – clearer administration and video metadata from AI filmstrips

- Horizontal navigation: **Dashboard · Živý přenos · AI detekce · AI videa · YouTube videa · Nastavení**.
  The dashboard summarizes cameras, recent evaluations, source clips, YouTube outputs, storage and system health.
  Quieter light and dark themes, responsive layout, original Atmovio logo retained.
- Separate source AI clips and processed YouTube videos, including processing/upload states and failed automatic exports.
  Settings have a persistent submenu; YouTube settings are grouped into video defaults, intro/music and channel connection.
  AI-video settings save independently of the detector configuration, camera selection and custom rules.
- AI detections show all evaluations by default. Combine camera, phenomenon, score, date and alert/error filters.
  Skipped dark/unchanged frames remain aggregate counters, not fictitious image history.
- Filmstrip evaluations retain their time range and an observed evolution description. Both **title and description** can
  be proposed from stored visual evidence and the clip interval. A preview requires explicit application before saving;
  automatic studio videos use both generated fields, falling back to templates together if the AI request fails.
  Evolution outside the exported clip is excluded from the metadata prompt. This is analysis of sampled frames, not the MP4.
- Exported clips retain their AI evidence after the original detection is deleted. Existing 4.7 data is migrated additively.
  Camera display-name edits preserve stable camera IDs and references. Deleting a detection removes its filmstrip too.
  Retention skips videos being processed/uploaded; active source clips cannot be deleted underneath a worker.
  Intentionally deleted automatic studio outputs are not silently recreated; explicit recreation remains available.
- Offline regression checks cover settings isolation, authentication/CSRF, all page states, filmstrip evidence,
  video metadata, retention, camera rename and migration. Generated install/update scripts and tag-based releases retained.

## 4.7 – 2026-09 – the AI sees the film, not a photo

- **Filmstrip evaluation**: instead of one snapshot the AI now gets one picture made of the current frame (large,
  "teď") plus a strip of older frames from the same camera with time offsets (default 6 frames over the last
  60 minutes, Nastavení → AI → Kdy se dívat → "Filmový pás"). It still is one API call per check, so the daily
  limit is unchanged. Atmovio collects a small thumbnail from every check (also skipped ones) to build the strip;
  after a restart the strip fills up within an hour.
- The AI now also reports the **trend** (nastupuje ↗ / vrcholí ★ / odeznívá ↘ / beze změny →) and a **time-lapse
  score 0–10** – shown in Historie, on the detection page and stored with every evaluation. Alerts and automatic
  videos work exactly as before, based on the score; the detection page shows "Co AI viděla" with the strip.

## 4.6.6 – 2026-09 – delete everything about a video, any time

- "Smazat z RPi" moved to the "Co dál" box and works whether or not the video went to YouTube: the studio
  video (always), the source clip and the AI detection with its snapshot are each a switch – tick all three and
  nothing about the video remains on the Pi. Blocked only while an upload is running.

## 4.6.5 – 2026-09 – the countdown is actually visible

- The "vytváří se… / zbývá asi … · hotovo asi v …" text in the rendering box was dark-on-dark in the light theme.
  It is now light, large and shows a ☕ when the wait is over three minutes.

## 4.6.4 – 2026-09 – capital letter at the start of titles

- Templates for title, description, intro and overlay text: the first letter of every line is capitalised, so
  a template starting with `{jev}` ("výrazné červánky – Březolupy …") no longer starts lowercase.

## 4.6.3 – 2026-09 – description always reaches YouTube

- If a video has an empty description at upload time (videos touched by the 4.6.0 bug), it is rebuilt from the
  description template, the AI text and the music credit before uploading. Angle brackets, which YouTube rejects,
  are replaced. The log now records the title and description length of every upload.

## 4.6.2 – 2026-09 – titles that attract viewers

- **✨ Navrhnout titulek (AI)** next to the title field (new video and finished video): the configured AI
  provider proposes five catchy Czech YouTube titles (≤ 70 characters, no clickbait) from the camera, date,
  phenomenon and the AI description – click one to use it. Automatic videos get an AI title too (switch in
  Nastavení → Video studio; the template stays as fallback). Default template changed to
  `{jev} nad obcí {kamera} · časosběr {datum}`.

## 4.6.1 – 2026-09 – upload keeps title, time estimates, clean-up after upload

- **Fix**: uploading to YouTube wiped the video's title and description (the upload form re-sent empty values).
  The upload now uses the saved title/description; an empty title falls back to the clip name.
- **When will it be done**: rendering and uploading show a live countdown ("zbývá asi 2 min") and the clock time
  ("hotovo asi v 17:05" / "na YouTube asi v 17:07") – also while a video waits in the queue (including videos
  ahead of it) and in the Videa list.
- **Clean up after upload**: once a video is on YouTube, the video page offers "Uklidit z RPi" – delete the
  studio video, the source clip and optionally the AI detection with its snapshot, freeing disk space.

## 4.6 – 2026-09 – YouTube upload

- **YouTube**: a finished studio video is uploaded to your channel from the video page (visibility, playlist or a
  new playlist, title and description taken from the page) with a progress bar and the link when done; or
  **automatically** for alert videos (Nastavení → Video studio → YouTube). Videos in the Videa list show a
  ▶ YouTube badge with the link.
- **Linking for humans**: a step-by-step guide inside Atmovio (Google Cloud project → enable YouTube Data API →
  consent screen → "TVs and Limited Input devices" client), then *Propojit YouTube* shows a short code you type
  at google.com/device – no redirect URLs, works from any browser, brand accounts supported. Playlists are
  loaded automatically; "Propojit znovu / jiný kanál" switches channels. Full guide in `docs/youtube.md`.
- Resumable upload in 8 MB chunks with retries; quota and token errors are explained in plain words
  (about 6 uploads a day; publish the consent screen so the link does not expire after 7 days).

## 4.5.5 – 2026-09 – readable overlay text, Openverse check

- Text in the picture sits on a translucent dark strip, so it is readable over a bright sky as well as over the
  fade-out at the end.
- Nastavení → Video studio: "Vyzkoušet hledání" button next to the Openverse registration shows whether the
  music search works with the current registration.

## 4.5.4 – 2026-09 – fades and finer speed steps

- **Fade from black / fade to black**: the sped-up recording now brightens from black at the start (1 s) and
  darkens at the end (2 s); the music fade-out is never shorter than the picture fade. Both lengths are in
  Nastavení → Video studio → "Obraz – rozjasnění a ztmavení". The intro is not affected.
- **Speed in steps of 10×**: a slider with −10 / +10 buttons from 10× to 240× (was a fixed set of six values),
  on the new-video page and for the default speed in settings.

## 4.5.3 – 2026-09 – music for every video, intro sound, time estimate

- **Find music per video**: in Studio → Hudba, "Najít hudbu k tomuto videu" searches Openverse (Creative Commons
  music, only CC0 / CC BY so YouTube never complains), with quick moods (klidná, klavír, západ slunce, epická…),
  a player for every result and **Použít** – the track is downloaded to the Pi and selected for this video.
  The author credit is added to the video description automatically. Optional one-click registration at Openverse
  (e-mail + confirmation link) in Nastavení → Video studio lifts the small anonymous search limit.
- **Intro keeps its sound**: an intro video with audio is no longer silent; the music starts after the intro and
  fades in (intro sound fades out over its last 0.8 s). Intro without music → sound during the intro, silence after.
- **How long will it take**: the new-video page estimates the rendering time for the chosen speed, and the
  progress page shows "zbývá asi …" computed from the real encoding pace.

## 4.5.2 – 2026-09 – videos no longer lost on updates

- **Root cause of "zaseklo se – Frigate export nedokončil"**: every Atmovio update (and every restart of the
  storage guard) re-created the Frigate container, which killed exports that were being cut at that moment –
  with 1.5-hour clips that happened a lot. The guard now **adopts the running Frigate** instead of recreating it
  when the disk mode has not changed, so updates no longer interrupt recording or exports.
- **Automatic recovery**: an export that Frigate did start but was restarted underneath (power cut, manual
  restart) is detected (Frigate's uptime is shorter than the export's age) and re-submitted automatically,
  up to twice, while the recording still exists. Only then does the video show "Vytvořit znovu".

## 4.5.1 – 2026-09 – see the speed before rendering

- Studio: **"Ukázat, jak bude video rychlé"** plays the source clip right on the page at the chosen speed
  (10–240×, switch speeds while it plays, loops until closed) so you can pick the right speed by eye before
  anything renders. Above 16× the preview steps through the clip, the finished video is smooth 30 fps.

## 4.5 – 2026-09 – Video studio

- **Video studio** (Videa → ⏩ Studio, Nastavení → Video studio): a finished clip becomes a shareable time-lapse.
  Speed **10× / 20× / 30× / 60× / 120× / 240×** (the page tells you how long the result will be), optional **intro**
  (an MP4 up to 15 s, or just a logo image that gets the camera name and date), **text in the picture** from a
  template (`{kamera} · {datum} · {rychlost}×`), **background music** with a smooth fade in and fade out (looped when
  shorter than the video), and an editable **title and description** pre-filled from the AI text.
- **Preview first**: the video renders in the background (progress shown, one at a time so recording is not
  disturbed); you watch it, edit the title/description, download the MP4. Nothing is uploaded anywhere yet –
  YouTube upload with playlists arrives in 4.6, the "Nahrát na YouTube" button already shows where it will be.
- **Automatic mode**: with "Automatika" on, every automatic alert video is turned into a studio video with the
  default settings as soon as Frigate finishes cutting it.
- Studio videos live on the recordings disk (`atmovio/studio`), are listed at the top of Videa and are deleted with
  the same retention as clips. Uploads of intro/music are stored in the Atmovio data folder.
- Installer/updater add `fonts-dejavu-core` (needed for text in the picture).

## 4.4.4 – 2026-09 – AI outages no longer swallow interesting skies

- **Retries on provider hiccups**: a 503/529 "overloaded", a timeout or a dropped connection from the AI provider is
  retried twice (after 5 s and 20 s) with the same snapshot before giving up; the request timeout is 60 s instead of 90 s.
- **Quick re-check after a failure**: when the AI still fails, the camera is checked again after 2 minutes (up to 3×)
  instead of waiting for the full interval – a shower or a sunset is not lost to a minute-long Google outage.
- Logs explain both cases in plain words; the history record says "zkusím znovu za 2 min".

## 4.4.3 – 2026-09 – last AI evaluation in the web heartbeat

- **Webhook heartbeat** carries `last_eval` for every AI-watched camera – the most recent evaluation (score, phenomenon,
  description, time, whether it alerted), including evaluations below the threshold. A website receiving the
  heartbeat can show "what the AI just said" under the current snapshot, exactly like the Atmovio dashboard.

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
