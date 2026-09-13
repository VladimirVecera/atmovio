<?php
/**
 * SkyWatch webhook receiver – configuration.
 * Copy this file next to webhook.php and index.php, then edit the values.
 */

// Shared secret. Generate a long random string (e.g. `openssl rand -hex 32`)
// and paste the SAME value into SkyWatch → Nastavení → Upozornění → Token.
const SKYWATCH_TOKEN = 'change-me-to-a-long-random-string';

// Where received data is stored (must be writable by PHP, keep it outside the web root if you can).
const SKYWATCH_DATA_DIR = __DIR__ . '/data';

// Optional: forward every "sky" / "outage" / "recovery" event by e-mail (PHP mail()). Empty = off.
const SKYWATCH_MAIL_TO = '';
const SKYWATCH_MAIL_FROM = 'skywatch@example.com';

// Optional: protect index.php with HTTP Basic auth. Empty password = page is public.
const SKYWATCH_VIEW_USER = 'sky';
const SKYWATCH_VIEW_PASSWORD = '';

// How many events to keep.
const SKYWATCH_KEEP_EVENTS = 500;

date_default_timezone_set('Europe/Prague');
