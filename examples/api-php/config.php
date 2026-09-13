<?php
/**
 * Atmovio REST API – example configuration.
 * Copy to config.local.php (ignored by git) or edit in place.
 */
declare(strict_types=1);

// Address of your Raspberry Pi with Atmovio (LAN or VPN address, plain http)
const ATMOVIO_URL = 'http://192.168.1.20';

// API key: Atmovio → Nastavení → Systém → API pro jiné systémy → Vytvořit klíč
const ATMOVIO_KEY = 'at_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

// Request timeout in seconds
const ATMOVIO_TIMEOUT = 8;

if (is_file(__DIR__ . '/config.local.php')) {
    require __DIR__ . '/config.local.php';
}
