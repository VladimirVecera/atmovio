# Changelog

All notable changes to SkyWatch. Versions correspond to `APP_VERSION` in `src/skywatch/app.py`.

## 3.3 – 2026-09

- Webhook heartbeat carries `api`: a snapshot of everything the REST API returns (status, cameras, notified
  detections, videos, events – identical fields) plus thumbnails of new detections/videos, so a website that
  cannot reach the Pi can show the same data. `status.ai.threshold` added to the API.

## 3.2 – 2026-09

- Update from the web UI: SkyWatch checks GitHub Releases once a day (can be turned off), shows a banner when a
  newer version exists, and installs it on one click (Nastavení → Systém → Aktualizace) – downloads
  `update-skywatch.sh` from the release, verifies SHA-256 against `SHA256SUMS`, runs it as a separate systemd unit
  and shows progress/result; the existing automatic rollback applies.
- `GET /api/v1/status` reports `update.latest` / `update.available`.
- Release workflow: pushing a `v*` tag builds a GitHub release with `install.sh`, `update-skywatch.sh` and `SHA256SUMS`.

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
