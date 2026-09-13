<?php
/**
 * Atmovio webhook receiver – configuration.
 * Copy this file next to webhook.php and index.php, then edit the values.
 */

// Shared secret. Generate a long random string (e.g. `openssl rand -hex 32`)
// and paste the SAME value into Atmovio → Nastavení → Upozornění → Token.
const ATMOVIO_TOKEN = 'change-me-to-a-long-random-string';

// Where received data is stored (must be writable by PHP, keep it outside the web root if you can).
const ATMOVIO_DATA_DIR = __DIR__ . '/data';

// Optional: forward every "sky" / "outage" / "recovery" event by e-mail (PHP mail()). Empty = off.
const ATMOVIO_MAIL_TO = '';
const ATMOVIO_MAIL_FROM = 'atmovio@example.com';

// Optional: protect index.php with HTTP Basic auth. Empty password = page is public.
const ATMOVIO_VIEW_USER = 'sky';
const ATMOVIO_VIEW_PASSWORD = '';

// How many events to keep.
const ATMOVIO_KEEP_EVENTS = 500;

date_default_timezone_set('Europe/Prague');
