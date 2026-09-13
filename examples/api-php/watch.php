<?php
/**
 * watch.php – poll for new alerts and react (cron / systemd timer / a loop on your PC).
 * Remembers the last seen detection id in last_id.txt and runs your code for each new one.
 *
 *   * * * * *  php /path/to/watch.php     (crontab, every minute)
 *
 * This is the "pull" alternative to the webhook: it works when your script can reach
 * the Pi (LAN/VPN). If your server is on the internet, use the webhook instead.
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

const MIN_SCORE = 7;                                   // react from this score
$stateFile = __DIR__ . '/last_id.txt';
$lastId = is_file($stateFile) ? (int) file_get_contents($stateFile) : 0;

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
try {
    $rows = $api->detections(['limit' => 20, 'notified' => 1, 'min_score' => MIN_SCORE]);
} catch (AtmovioException $e) {
    fwrite(STDERR, "ERROR: {$e->getMessage()}\n");
    exit(1);
}

$new = array_filter($rows, static fn($d) => (int) $d['id'] > $lastId);
usort($new, static fn($a, $b) => $a['id'] <=> $b['id']);     // oldest first

foreach ($new as $d) {
    // ---- your reaction goes here -------------------------------------------------
    // e.g. send a Telegram message, switch a light, save the picture:
    $jpg = __DIR__ . '/alert-' . $d['id'] . '.jpg';
    file_put_contents($jpg, $api->detectionImage((int) $d['id']));
    printf("[%s] %s %d/10 on %s – %s (saved %s)\n", $d['ts'], $d['phenomenon'], $d['score'], $d['camera_label'], $d['description'], basename($jpg));
    // ------------------------------------------------------------------------------
    $lastId = (int) $d['id'];
    file_put_contents($stateFile, (string) $lastId);
}
if (!$new) echo "nothing new\n";
