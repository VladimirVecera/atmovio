<?php
/**
 * detections.php – the latest AI sky detections as a small HTML gallery
 * (browser) or a text table (command line).
 *
 *   php detections.php               # last 10 alerts
 *   php detections.php 30 0          # last 30 evaluations incl. non-alerts (notified=0)
 *   http://your-pc/detections.php?limit=10&camera=zahrada&min_score=7
 *
 * Images are fetched through image.php so the API key never reaches the browser.
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
$cli = PHP_SAPI === 'cli';

$params = [
    'limit'     => (int) ($cli ? ($argv[1] ?? 10) : ($_GET['limit'] ?? 10)),
    'notified'  => (int) ($cli ? ($argv[2] ?? 1) : ($_GET['notified'] ?? 1)),
];
if (!$cli && !empty($_GET['camera']))    $params['camera'] = (string) $_GET['camera'];
if (!$cli && isset($_GET['min_score']))  $params['min_score'] = (int) $_GET['min_score'];

try {
    $rows = $api->detections($params);
} catch (AtmovioException $e) {
    http_response_code(502);
    echo "ERROR: {$e->getMessage()}\n";
    exit(1);
}

if ($cli) {
    printf("%-19s %-5s %-18s %-16s %s\n", 'time', 'score', 'camera', 'phenomenon', 'description');
    foreach ($rows as $d) {
        printf("%-19s %-5s %-18s %-16s %s\n", $d['ts'], $d['score'] . '/10', mb_strimwidth($d['camera_label'] ?? $d['camera'], 0, 18),
            mb_strimwidth($d['phenomenon'] ?? '', 0, 16), mb_strimwidth($d['description'] ?? '', 0, 60, '…'));
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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Atmovio – sky detections</title>
<style>
  body { font: 15px/1.5 system-ui, sans-serif; margin: 2rem; background: #0f172a; color: #e2e8f0; }
  h1 { font-weight: 600; } a { color: #7dd3fc; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
  .card { background: #1e293b; border-radius: 12px; overflow: hidden; }
  .card img { width: 100%; aspect-ratio: 16/9; object-fit: cover; display: block; }
  .card div { padding: .7rem .9rem; } .score { font-weight: 700; color: #fbbf24; }
  small { color: #94a3b8; }
</style>
</head>
<body>
<h1>Sky detections <small>(<?= count($rows) ?>)</small></h1>
<?php if (!$rows): ?><p>No detections yet.</p><?php endif; ?>
<div class="grid">
<?php foreach ($rows as $d): ?>
  <article class="card">
    <a href="image.php?detection=<?= (int) $d['id'] ?>" target="_blank"><img src="image.php?detection=<?= (int) $d['id'] ?>" alt="" loading="lazy"></a>
    <div>
      <span class="score"><?= $e($d['score']) ?>/10</span> · <strong><?= $e($d['phenomenon'] ?? '') ?></strong><br>
      <small><?= $e($d['ts']) ?> · <?= $e($d['camera_label'] ?? $d['camera']) ?></small>
      <p><?= $e($d['description'] ?? '') ?></p>
      <small>phenomena: <?= $e(implode(', ', $d['phenomena'] ?? [])) ?><?= !empty($d['exported']) ? ' · video exported' : '' ?></small>
    </div>
  </article>
<?php endforeach; ?>
</div>
</body>
</html>
