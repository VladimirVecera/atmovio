<?php
/**
 * image.php – image proxy: fetches a JPEG from Atmovio with the API key and
 * streams it to the browser, so the key stays on the server.
 *
 *   image.php?camera=zahrada&h=720   → live snapshot of a camera
 *   image.php?detection=123          → AI snapshot of a detection
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
try {
    if (isset($_GET['detection'])) {
        $jpeg = $api->detectionImage((int) $_GET['detection']);
        header('Cache-Control: public, max-age=86400');          // AI snapshots never change
    } elseif (isset($_GET['camera'])) {
        $h = max(120, min(1080, (int) ($_GET['h'] ?? 720)));
        $jpeg = $api->snapshot((string) $_GET['camera'], $h);
        header('Cache-Control: no-store');                       // live frame
    } else {
        http_response_code(400);
        exit('use ?camera=<name> or ?detection=<id>');
    }
} catch (AtmovioException $e) {
    http_response_code($e->httpCode === 404 ? 404 : 502);
    header('Content-Type: text/plain; charset=utf-8');
    exit($e->getMessage());
}
header('Content-Type: image/jpeg');
header('Content-Length: ' . strlen($jpeg));
echo $jpeg;
