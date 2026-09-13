<?php
/**
 * SkyWatch – simple public status page for data received by webhook.php.
 * Shows NVR status, camera thumbnails and the latest sky alerts with images.
 */

declare(strict_types=1);
require_once __DIR__ . '/config.php';

if (SKYWATCH_VIEW_PASSWORD !== '') {
    $u = $_SERVER['PHP_AUTH_USER'] ?? '';
    $p = $_SERVER['PHP_AUTH_PW'] ?? '';
    if (!hash_equals(SKYWATCH_VIEW_USER, $u) || !hash_equals(SKYWATCH_VIEW_PASSWORD, $p)) {
        header('WWW-Authenticate: Basic realm="SkyWatch"');
        http_response_code(401);
        exit('Login required');
    }
}

$dir = rtrim(SKYWATCH_DATA_DIR, '/');

// Serve images through PHP so the data directory can stay private.
if (isset($_GET['img'])) {
    $img = (string) $_GET['img'];
    $file = preg_match('/^thumb:([a-zA-Z0-9_-]{1,64})$/', $img, $m) ? "$dir/thumbs/{$m[1]}.jpg"
        : (preg_match('/^event:(\d{1,9})$/', $img, $m) ? "$dir/events/{$m[1]}.jpg" : '');
    if ($file === '' || !is_file($file)) {
        http_response_code(404);
        exit;
    }
    header('Content-Type: image/jpeg');
    header('Cache-Control: private, max-age=60');
    readfile($file);
    exit;
}

$state = is_file("$dir/state.json") ? json_decode((string) file_get_contents("$dir/state.json"), true) : null;
$events = is_file("$dir/events.json") ? (array) json_decode((string) file_get_contents("$dir/events.json"), true) : [];
$stale = !$state || (time() - strtotime((string) $state['received']) > 180);
$h = static fn($v): string => htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
$when = static function (string $iso): string {
    $t = strtotime($iso);
    return $t ? date('j. n. Y H:i', $t) : $iso;
};
$labels = [
    'cervanky' => 'červánky', 'shelf_cloud' => 'shelf cloud', 'mammatus' => 'mammatus', 'beranky' => 'beránky',
    'bourkovy_mrak' => 'bouřkový mrak', 'blesk' => 'blesk', 'duha' => 'duha', 'halo' => 'halo',
    'krepuskularni' => 'krepuskulární paprsky', 'lentikularni' => 'lentikulární mraky', 'mlha' => 'mlha', 'jine' => 'jiná zajímavá obloha',
];
?>
<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SkyWatch – <?= $h($state['nvr'] ?? 'kamery') ?></title>
<style>
:root{color-scheme:light dark;font-family:system-ui,sans-serif}
body{margin:0;background:#f3f5f9;color:#0f172a}
@media (prefers-color-scheme:dark){body{background:#0b1220;color:#e2e8f0}.card{background:#111a2e!important;border-color:#1e293b!important}}
main{max-width:1100px;margin:0 auto;padding:1.2rem}
h1{font-size:1.5rem;margin:.2rem 0}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:.8rem;padding:1rem;margin:.9rem 0}
.badge{display:inline-block;padding:.1rem .6rem;border-radius:999px;font-size:.75rem;font-weight:700}
.ok{background:#dcfce7;color:#166534}.err{background:#fee2e2;color:#991b1b}.warn{background:#fef3c7;color:#92400e}.info{background:#dbeafe;color:#1e40af}
.cams{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:.8rem}
.cam img{width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:.6rem;background:#0b1220;display:block}
.cam .n{display:flex;justify-content:space-between;align-items:center;font-weight:700;margin-top:.4rem}
.ev{display:grid;grid-template-columns:220px 1fr;gap:.9rem;border-top:1px solid #e2e8f0;padding:.8rem 0}
.ev img{width:100%;border-radius:.5rem;display:block;cursor:zoom-in}
.ev .t{font-size:1.1rem;font-weight:800}.hint{color:#64748b;font-size:.85rem}
@media (max-width:640px){.ev{grid-template-columns:1fr}}
.lb{position:fixed;inset:0;background:rgba(0,0,0,.9);display:none;align-items:center;justify-content:center;cursor:zoom-out}
.lb img{max-width:96vw;max-height:92vh}.lb.open{display:flex}
</style>
</head>
<body>
<main>
<h1>☁️ <?= $h($state['nvr'] ?? 'SkyWatch') ?></h1>
<?php if (!$state): ?>
  <div class="card">Zatím nepřišla žádná data. V SkyWatch nastav adresu tohoto přijímače a token (Nastavení → Upozornění) a klikni <b>Uložit a otestovat spojení</b>.</div>
<?php else: $s = $state['status']; ?>
  <div class="card">
    <?= $stale ? '<span class="badge err">záznamník se neozývá</span>' : '<span class="badge ok">online</span>' ?>
    <span class="hint">poslední zpráva <?= $h($when($state['received'])) ?> · SkyWatch <?= $h($state['version']) ?></span>
    <div style="margin-top:.5rem">
      Nahrávání: <?= !empty($s['frigate_online']) && $s['frigate_online'] !== '0' ? '<span class="badge ok">běží</span>' : '<span class="badge err">neběží</span>' ?>
      · Disk: <?= $h($s['disk_pct'] ?? '?') ?> % plný (volné <?= $h($s['disk_free'] ?? '?') ?>)
      · AI: <?= (($s['ai_enabled'] ?? '0') !== '0') ? '<span class="badge ok">zapnuto</span>' : '<span class="badge warn">vypnuto</span>' ?>
      <span class="hint"><?= $h($s['ai_status'] ?? '') ?></span>
      · Teplota <?= $h($s['temp'] ?? '?') ?> · běží <?= $h($s['uptime'] ?? '?') ?>
    </div>
  </div>
  <div class="cams">
  <?php foreach ((array) $state['cameras'] as $c): ?>
    <div class="card cam">
      <?php if (!empty($c['thumb'])): ?><img src="?img=thumb:<?= $h($c['name']) ?>&t=<?= time() ?>" alt=""><?php else: ?><div style="aspect-ratio:16/9;background:#0b1220;border-radius:.6rem"></div><?php endif; ?>
      <div class="n"><span><?= $h($c['label']) ?></span><?= !empty($c['online']) && !$stale ? '<span class="badge ok">' . $h($c['fps']) . ' fps</span>' : '<span class="badge err">bez obrazu</span>' ?></div>
      <div class="hint"><?= $h($c['ip']) ?> · <?= $h($c['via']) ?><?= !empty($c['ai']) ? ' · <span class="badge info">AI hlídá</span>' : '' ?></div>
    </div>
  <?php endforeach; ?>
  </div>
<?php endif; ?>

<div class="card">
  <h2 style="margin:0 0 .3rem">Upozornění na oblohu</h2>
  <?php $shown = 0; foreach ($events as $e): if ($e['kind'] !== 'sky') continue; $shown++; ?>
  <div class="ev">
    <div><?php if (!empty($e['image'])): ?><img src="?img=event:<?= (int) $e['id'] ?>" alt="" onclick="lb(this.src)"><?php endif; ?></div>
    <div>
      <div class="t"><?= $h($when($e['ts'])) ?> · <?= $h($e['camera_label']) ?><?= $e['score'] !== null ? ' · <span class="badge info">' . (int) $e['score'] . '/10</span>' : '' ?></div>
      <div><?php foreach ($e['phenomena'] as $ph): ?><span class="badge warn"><?= $h($labels[$ph] ?? $ph) ?></span> <?php endforeach; ?></div>
      <p style="margin:.4rem 0;white-space:pre-line"><?= $h($e['message']) ?></p>
      <?php if ($e['link'] !== ''): ?><a class="hint" href="<?= $h($e['link']) ?>">detail v SkyWatch (jen z domácí sítě / VPN)</a><?php endif; ?>
    </div>
  </div>
  <?php if ($shown >= 30) break; endforeach; if ($shown === 0): ?><p class="hint">Zatím žádné.</p><?php endif; ?>
</div>

<div class="card">
  <h2 style="margin:0 0 .3rem">Provozní události</h2>
  <?php $shown = 0; foreach ($events as $e): if ($e['kind'] === 'sky') continue; $shown++; ?>
    <div style="padding:.3rem 0;border-top:1px solid #e2e8f0"><span class="hint"><?= $h($when($e['ts'])) ?></span>
      <span class="badge <?= $e['kind'] === 'outage' ? 'err' : ($e['kind'] === 'recovery' ? 'ok' : 'info') ?>"><?= $h($e['kind']) ?></span>
      <b><?= $h($e['subject']) ?></b> <span class="hint"><?= $h($e['message']) ?></span></div>
  <?php if ($shown >= 20) break; endforeach; if ($shown === 0): ?><p class="hint">Zatím žádné.</p><?php endif; ?>
</div>
<p class="hint">Stránku generuje ukázkový přijímač z projektu <a href="https://github.com/">SkyWatch</a>. Obnovuje se ručně; záznamník posílá stav každou minutu.</p>
</main>
<div class="lb" id="lb" onclick="this.classList.remove('open')"><img id="lbi" alt=""></div>
<script>function lb(s){document.getElementById('lbi').src=s;document.getElementById('lb').classList.add('open')}</script>
</body>
</html>
