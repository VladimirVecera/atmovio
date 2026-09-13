<?php
/**
 * cameras.php – live overview of all cameras (auto-refreshes every 30 s).
 * Command line: prints a status table instead.
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
try {
    $cams = $api->cameras();
} catch (AtmovioException $e) {
    http_response_code(502);
    exit("ERROR: {$e->getMessage()}\n");
}

if (PHP_SAPI === 'cli') {
    printf("%-14s %-20s %-8s %-6s %-15s %s\n", 'name', 'label', 'online', 'fps', 'ip', 'AI');
    foreach ($cams as $c) {
        printf("%-14s %-20s %-8s %-6s %-15s %s\n", $c['name'], mb_strimwidth($c['label'] ?? '', 0, 20), !empty($c['online']) ? 'yes' : 'NO',
            $c['fps'] ?? '-', $c['ip'] ?? '-', !empty($c['ai']) ? 'on' : 'off');
    }
    exit;
}

$e = static fn($v) => htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Atmovio – cameras</title>
<style>
  body { font: 15px/1.5 system-ui, sans-serif; margin: 2rem; background: #0f172a; color: #e2e8f0; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 1rem; }
  .cam { background: #1e293b; border-radius: 12px; overflow: hidden; }
  .cam img { width: 100%; aspect-ratio: 16/9; object-fit: cover; display: block; background: #000; }
  .cam div { padding: .6rem .9rem; display: flex; justify-content: space-between; }
  .off { color: #f87171; } .on { color: #4ade80; }
</style>
</head>
<body>
<h1>Cameras</h1>
<div class="grid">
<?php foreach ($cams as $c): ?>
  <article class="cam">
    <img src="image.php?camera=<?= $e(rawurlencode($c['name'])) ?>&h=480&t=<?= time() ?>" alt="<?= $e($c['label'] ?? $c['name']) ?>">
    <div>
      <strong><?= $e($c['label'] ?? $c['name']) ?></strong>
      <span class="<?= !empty($c['online']) ? 'on' : 'off' ?>"><?= !empty($c['online']) ? 'online · ' . $e($c['fps'] ?? '?') . ' fps' : 'offline' ?></span>
    </div>
  </article>
<?php endforeach; ?>
</div>
</body>
</html>
