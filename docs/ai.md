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

## Filmstrip (since 4.7)

By default the AI does not see a single snapshot but one composite picture: the current frame on top (labelled
"teď") and a strip of older frames from the same camera below, each with its age ("−45 min"). The prompt asks the
model to judge the current sky *in the light of how it developed* and to return, besides score and phenomena, a
`trend` (nastupuje / vrcholí / odeznívá / beze změny) and a `timelapse` score 0–10 (how impressive a time-lapse of
the last minutes would be). Both are stored and shown in Historie and on the detection page ("Co AI viděla").
Alerts are still triggered by the score. Settings: Nastavení → AI → Kdy se dívat → Filmový pás (on/off, number of
frames, minutes back). The strip is built from thumbnails Atmovio keeps in memory from every check, so it fills up
during the first hour after a start.

