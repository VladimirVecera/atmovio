# YouTube upload (Video studio → YouTube)

Atmovio can upload a finished studio video (sped-up clip with intro, text and music) to your YouTube channel –
by hand from the video page, or automatically for every alert video. Videos can go into a playlist, and you
choose the visibility (unlisted by default, so you check first and publish on YouTube when happy).

Google does not allow an app to upload to your channel without an *application key* that belongs to you.
Creating one is free and takes about ten minutes, once. The steps below are also shown inside Atmovio
(Nastavení → Video studio → YouTube).

## 1. Create a Google Cloud project

1. Open <https://console.cloud.google.com/projectcreate> – signed in with the Google account that owns the
   YouTube channel.
2. Name the project e.g. **Atmovio** and click **Create**.

## 2. Enable the YouTube Data API

Open <https://console.cloud.google.com/apis/library/youtube.googleapis.com> (make sure the *Atmovio* project is
selected at the top) and click **Enable**.

## 3. Consent screen

1. Open <https://console.cloud.google.com/auth/overview> → **Get started**.
2. App name **Atmovio**, your e-mail as support e-mail, audience **External**, contact e-mail, agree → **Create**.
3. Open **Branding** and fill in everything marked as required (app name, user support e-mail, developer
   contact e-mail), then **Save**. The *Publish app* button stays greyed out until this is done.
4. In **Audience** click **Publish app** (confirm). Without this Google treats the app as "testing" and
   expires the link after 7 days. (Fallback: add your own e-mail under *Test users* – works, but the link must
   be renewed every 7 days.)
   You will see an "unverified app" warning when linking – that is expected for a private app; verification is
   only needed for public apps.

## 4. OAuth client

1. Open <https://console.cloud.google.com/auth/clients/create>.
2. Application type **TVs and Limited Input devices**, name **Atmovio** → **Create**.
3. Copy the **Client ID** and **Client secret** into Atmovio (Nastavení → Video studio → YouTube) and click
   **Uložit klíče**.

## 5. Link the channel

Click **Propojit YouTube**. Atmovio shows a short code; open <https://www.google.com/device>, enter the code,
pick the channel (or brand account) and click **Allow**. The page switches to "propojeno" by itself and loads
your playlists. To link a different channel, click **Propojit znovu / jiný kanál**.

## Uploading

* **By hand**: Videa → open a studio video → **YouTube** card: visibility, playlist (or a new one), *Nahrát na
  YouTube*. The title and description from the video page are used; the music credit is already in the
  description. Progress is shown; when done, the link appears on the video and in the Videa list.
* **Automatically**: Nastavení → Video studio → YouTube → "Automatická videa po upozornění rovnou nahrát".
  Requires *Automatické video* (Nastavení → AI) and *Automatika* in the studio to be on. Default visibility and
  playlist apply.

## Limits and notes

* YouTube API quota: 10 000 units per day per project; one upload costs 1 600, so about **6 uploads per day**.
  The quota resets at midnight Pacific time (about 9:00 CEST).
* Use only music you have rights to – tracks found through Atmovio (Openverse, CC0 / CC BY) are fine and the
  author credit is added to the description automatically.
* If uploads start failing with *invalid_grant*, the link expired (usually the consent screen was left in
  "testing" mode) – publish the app (step 3) and link again.
* The refresh token is stored only in Atmovio's `config.json` on the Pi.
