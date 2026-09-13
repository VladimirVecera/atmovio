<?php
/**
 * status.php – print NVR status. Works from the command line and in a browser.
 *
 *   php status.php            # text summary
 *   php status.php --json     # raw JSON
 */
declare(strict_types=1);
require __DIR__ . '/config.php';
require __DIR__ . '/atmovio.php';

$api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY, ATMOVIO_TIMEOUT);
$cli = PHP_SAPI === 'cli';
if (!$cli) header('Content-Type: text/plain; charset=utf-8');

try {
    $s = $api->status();
} catch (AtmovioException $e) {
    fwrite($cli ? STDERR : fopen('php://output', 'w'), "ERROR: {$e->getMessage()}\n");
    exit(1);
}

if (in_array('--json', $argv ?? [], true) || isset($_GET['json'])) {
    echo json_encode($s, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
    exit;
}

$st  = $s['storage'] ?? [];
$ai  = $s['ai'] ?? [];
$sys = $s['system'] ?? [];
$fr  = $s['frigate'] ?? [];
$up  = $s['update'] ?? [];

printf("Atmovio %s on %s (%s)\n", $s['version'] ?? '?', $sys['hostname'] ?? '?', $sys['ip'] ?? '?');
printf("Time:      %s\n", $s['time'] ?? '?');
printf("Frigate:   %s%s\n", !empty($fr['online']) ? 'online' : 'OFFLINE', isset($fr['version']) ? " ({$fr['version']})" : '');
printf("Storage:   %s – %s%% used, %s free of %s, retention %s days\n",
    $st['mode'] ?? '?', $st['disk_pct'] ?? '?', $st['disk_free'] ?? '?', $st['disk_total'] ?? '?', $st['retain_days'] ?? '?');
printf("AI:        %s – %s/%s requests today, threshold %s, %s\n",
    !empty($ai['enabled']) ? 'enabled' : 'disabled', $ai['used_today'] ?? 0, $ai['daily_limit'] ?? '?',
    $ai['threshold'] ?? '?', !empty($ai['daytime']) ? 'daytime (watching)' : 'night (sleeping)');
if (!empty($s['sun'])) printf("Sun:       dawn %s · sunrise %s · sunset %s · dusk %s\n", ...array_values(array_map(fn($k) => $s['sun'][$k] ?? '?', ['dawn', 'sunrise', 'sunset', 'dusk'])));
printf("System:    %s, load %s, mem %s, up %s\n", $sys['temp'] ?? '?', $sys['load'] ?? '?', $sys['mem'] ?? '?', $sys['uptime'] ?? '?');
if (!empty($s['outages'])) {
    echo "Outages:\n";
    foreach ($s['outages'] as $what => $seconds) printf("  - %s for %d min\n", $what, intdiv((int) $seconds, 60));
}
if (!empty($up['available'])) printf("Update:    version %s is available\n", $up['latest'] ?? '?');
