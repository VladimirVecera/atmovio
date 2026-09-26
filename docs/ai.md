# AI sky watching

*[Česky](cs/ai.md)*

Atmovio does not run a neural network on the Pi. It sends a snapshot to a hosted vision model and asks
one question: *how interesting is this sky, and which of these phenomena do you actually see?*
The model answers with a 0–10 score and a list of phenomena; Atmovio does the rest (episodes, cooldowns, alerts, video).

## Getting a free key (Google Gemini)

1. Open [aistudio.google.com/apikey](https://aistudio.google.com/apikey), sign in with a Google account, **Create API key**. No credit card.
2. Atmovio → **Nastavení → AI hlídání oblohy → 1 · Klíč k AI**, paste the key, **Uložit a ověřit klíč**.
3. Leave the model on **auto** – Atmovio picks the newest *Flash-Lite* model your key can use (largest free daily quota, currently ~500 requests/day) and falls back to other models on 404/429/503.
4. Set **Nejvíc dotazů na AI za den** to your quota; Atmovio stops asking for the day when it is reached.

Note: on the free tier Google may use the sent images to improve its models. Other providers:

| Provider | Cost | Notes |
|---|---|---|
| Google Gemini | free tier | default, recommended |
| Groq (`https://api.groq.com/openai/v1`, Llama 4 Scout) | free tier | provider "OpenAI-compatible" |
| OpenRouter | free models with `:free` suffix | OpenAI-compatible |
| OpenAI `gpt-4o-mini`, Anthropic `claude-haiku-4-5` | paid, a few € / month at ~200 frames/day | most accurate |
| Ollama on the Pi (`moondream`, `qwen2.5vl:3b`) | free, offline | slow (tens of seconds per frame), less accurate |

## What it watches (2 · Co hlídat)

Pick the cameras that see the sky, the phenomena you want alerts for and the **threshold** (default 7/10).
Catalogue: red sky (červánky), shelf cloud / arcus, mammatus, altocumulus "sheep" (beránky), thunderstorm cloud,
lightning, rainbow, halo / sun pillar, crepuscular rays, lenticular clouds, fog / inversion, funnel cloud / tornado,
wall cloud, roll cloud, asperitas, hail / precipitation core, shower, virga, rain, snowfall, other interesting sky.
New phenomena added in a release are enabled automatically once on existing installs.

**Extra instructions** for the model are optional (e.g. "the camera faces west, ignore the roof at the bottom").

## When it looks (3 · Jak často se dívat)

- **Window:** from *dawn* to *dusk* – choose civil (sun 6° below horizon, ≈ ±35 min), **nautical (12°, ≈ ±75 min, default)** or
  astronomical twilight, or a fixed ± minutes around sunrise/sunset. Needs your coordinates (advanced section).
- **Normal interval** (default 10 min) and **fast interval** (default 3 min) used around dawn/dusk and after an interesting frame.
- **Dark frames** (average brightness below the threshold, default 22/255) are skipped – no AI call, nothing stored.
- **Unchanged frames** (pre-filter, difference below threshold vs. the last evaluated frame) are skipped too.
- Estimated requests per day are shown in the form; the 7-day statistics table at the bottom shows real numbers
  (requests, interesting, alerts, skipped, errors) and does not change when you delete history.

## Alerts, episodes, cooldowns

- A detection triggers an alert when **score ≥ threshold** and at least one detected phenomenon is among the selected ones.
- **Episode:** the same phenomenon from the same camera is reported once; it is reported again only after it disappeared
  and the *episode gap* (default 120 min) passed. A new phenomenon inside a running episode does alert.
- **Cooldown:** minimum spacing of alerts from one camera (default 15 min).
- **Vyhodnotit oblohu teď** (manual test) never sends alerts.
- Alerts go to e-mail and/or the [webhook](webhook.md) with the snapshot and a link to the detection detail.

## Automatic video (4 · Video automaticky)

After an alert Atmovio can cut a clip −N/+M minutes around the snapshot automatically (per camera, optional 25× timelapse).
The clip is created once the "after" minutes have passed; you find it in **Videa** marked *auto*, and the detection shows
"video exportováno". Videos are deleted after the retention set on the Videa page (default 30 days).

## History and the dashboard

- **Historie AI detekcí** shows notified detections by default; switch to all evaluations or errors.
- Detection detail: snapshot, playback of the recording around it (−2/+1 min by default), neighbouring alerts from all cameras, clip export.
- Snapshots and history are kept for *keep_days* (default 14); skipped frames are never stored.
- Each camera page shows its own 7-day numbers, last evaluation and last alerts.

## Tuning tips

- Too many alerts? Raise the threshold to 8, deselect phenomena you do not care about, increase the episode gap.
- Missed sunsets? Lower the threshold to 6, make sure the window is *nautical* and the camera actually sees the horizon.
- Camera goes to IR/black-and-white at dusk → the dark-frame filter handles it; lower the dark threshold (12–15) if it skips too early.
- Add "extra instructions" to tell the model about permanent objects in the frame.

## Completed AI films (since 5.2)

Settings → AI → Timing and AI film separates **sample interval** (e.g. 5 minutes) from **film duration**
(e.g. 60 minutes, configurable from 10 to 180). The default enabled-film mode evaluates completed windows,
not each incoming snapshot. Existing installations retain their interval/duration; new installs use 5/60.
The former rolling-window mode remains available. Its fast cadence and dark/unchanged-frame filters do not
apply to completed films. Alerts arrive after a window finishes, not immediately.

Per-camera samples and windows persist across restarts. Inference runs in the background while the next film
collects. Daily quotas pause inference but not sampling. Provider failures retry twice, then remain available
for an explicit retry. Night/outage gaps produce partial or explicitly incomplete films. Pending and completed
films expire with snapshot retention, including unevaluated backlog.

AI detections shows ongoing films. The film viewer plays actual snapshots, shows their timestamps and the exact
contact sheet submitted to AI. At most 36 evenly spaced frames including both endpoints are submitted; all samples
remain viewable and selected frames are labelled. Frames never stored by older versions cannot be reconstructed.

The model assesses the whole sequence, including events already over at its end, and returns event frame indices.
Validated boundaries are padded with neighbouring samples and the configured before/after margins. Missing or
invalid boundaries fall back to the full observed sequence. Interesting-film video creation is independent of
email success and notification cooldown. Matching events continuing into the next film extend a pending clip.
Clips finalize at event end, after the next-window duration plus 15 minutes without continuation, or in bounded
parts of about six hours at film boundaries. Camera recordings must remain available for the entire interval.
Combined evidence is retained with the exported clip for subsequent YouTube title/description generation.

Manual tests retain the current-view behavior and do not reset or split a collecting film. Manual clip playback
and exports from a completed film use the observed event bounds. Original rolling-mode behavior remains available.

### Fixed source length and exact clip corrections

AI-video settings can use the event duration or a fixed total source duration of 1–120 minutes, including the
before-event margin (the after-margin is ignored in fixed mode). Continuing events use subsequent adjacent parts.
Detection details provide device-local OD–DO datetimes and a duration control for previewing or creating a new
corrected clip while retaining the original. Future endpoints queue creation until recordings finish. Manual
ranges over 120 minutes, reversed/invalid dates and nonexistent/ambiguous daylight-saving times are rejected.
The duration describes source time: 120 minutes at normal speed remains 120 minutes, while 25× timelapse is 4:48.


### Frame limits for completed AI films (5.3)

Timing settings include a maximum frame count. A film ends at the earlier of its requested
duration or frame limit. The 5-minute / 40-minute / 9-frame preset includes both endpoints;
the boundary snapshot starts the next film. Existing in-progress films retain their schedule.
Sheets with up to 9 frames use photo areas up to 720×405 pixels; larger sheets use 480×270.
The provider may process images further, and subtle events can still be missed. The compatibility
default is 36 frames; very dense long films now end sooner to respect that limit.
