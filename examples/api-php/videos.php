<?php
/**
 * videos.php – list exported video clips; optionally download one.
 *
 *   php videos.php                   # list
 *   php videos.php 42 clip.mp4       # download clip id 42 to clip.mp4
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
if (PHP_SAPI !== 'cli') header('Content-Type: text/plain; charset=utf-8');

try {
    if (PHP_SAPI === 'cli' && isset($argv[1])) {
        $to = $argv[2] ?? ('atmovio-' . (int) $argv[1] . '.mp4');
        $n = $api->downloadVideo((int) $argv[1], $to);
        printf("saved %s (%.1f MB)\n", $to, $n / 1048576);
        exit;
    }
    $videos = $api->videos();
} catch (AtmovioException $e) {
    exit("ERROR: {$e->getMessage()}\n");
}

printf("%-5s %-19s %-16s %-9s %-7s %s\n", 'id', 'created', 'camera', 'length', 'size', 'name');
foreach ($videos as $v) {
    printf("%-5s %-19s %-16s %-9s %-7s %s\n", $v['id'], $v['created'] ?? $v['ts'] ?? '', mb_strimwidth($v['camera_label'] ?? $v['camera'] ?? '', 0, 16),
        $v['duration'] ?? '', $v['size'] ?? '', ($v['name'] ?? '') . (!empty($v['ready']) ? '' : '  (not ready)'));
}
echo "\nDownload: php videos.php <id> [file.mp4]  – or open the download_url of each item with the API key header.\n";
