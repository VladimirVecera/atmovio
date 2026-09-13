<?php
/**
 * SkyWatch webhook receiver (example, no database needed).
 * ---------------------------------------------------------------------
 * SkyWatch POSTs JSON here (see docs/webhook.md):
 *   {"type":"ping"}
 *   {"type":"heartbeat", "nvr":"…", "status":{…}, "cameras":[{…,"thumb":"<base64 jpeg>"}]}
 *   {"type":"event", "kind":"sky|outage|recovery|system|test", "camera":"…", "subject":"…",
 *    "message":"…", "score":8, "phenomena":["cervanky"], "ts":"2026-09-13T19:12:00", "image":"<base64 jpeg>", "link":"…"}
 * Authentication: header  Authorization: Bearer <token>  (also sent as X-Token).
 * Response: JSON {"ok":true, …}. Anything else makes SkyWatch show the error in its UI.
 *
 * Storage: data/state.json (last heartbeat), data/events.json (last N events),
 *          data/thumbs/<camera>.jpg, data/events/<id>.jpg
 */

declare(strict_types=1);
require_once __DIR__ . '/config.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function api_end(int $code, array $payload): never
{
    http_response_code($code);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE);
    exit;
}

function read_token(): string
{
    if (!empty($_SERVER['HTTP_X_TOKEN'])) {
        return trim((string) $_SERVER['HTTP_X_TOKEN']);
    }
    $auth = (string) ($_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
    if ($auth === '' && function_exists('apache_request_headers')) {
        $h = array_change_key_case((array) apache_request_headers(), CASE_LOWER);
        if (!empty($h['x-token'])) {
            return trim((string) $h['x-token']);
        }
        $auth = (string) ($h['authorization'] ?? '');
    }
    return preg_match('/^Bearer\s+(\S+)$/i', trim($auth), $m) ? $m[1] : '';
}

function safe_name(string $s): string
{
    $s = preg_replace('/[^a-zA-Z0-9_-]+/', '_', $s) ?? '';
    return substr($s, 0, 64) ?: 'camera';
}

function save_jpeg(?string $b64, string $path, int $maxBytes): bool
{
    if (!is_string($b64) || $b64 === '') {
        return false;
    }
    $bin = base64_decode($b64, true);
    if ($bin === false || strlen($bin) > $maxBytes || substr($bin, 0, 2) !== "\xFF\xD8") {
        return false;
    }
    return file_put_contents($path, $bin, LOCK_EX) !== false;
}

function load_json(string $file, $default)
{
    if (!is_file($file)) {
        return $default;
    }
    $v = json_decode((string) file_get_contents($file), true);
    return is_array($v) ? $v : $default;
}

function save_json(string $file, $value): void
{
    $tmp = $file . '.tmp';
    file_put_contents($tmp, json_encode($value, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), LOCK_EX);
    rename($tmp, $file);
}

// ---------------------------------------------------------------------
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'POST') {
    api_end(405, ['ok' => false, 'error' => 'POST JSON expected.']);
}
if (SKYWATCH_TOKEN === 'change-me-to-a-long-random-string') {
    api_end(500, ['ok' => false, 'error' => 'Receiver is not configured: set SKYWATCH_TOKEN in config.php.']);
}
$token = read_token();
if ($token === '' || !hash_equals(SKYWATCH_TOKEN, $token)) {
    usleep(300000);
    api_end(401, ['ok' => false, 'error' => 'Invalid token.']);
}

$raw = file_get_contents('php://input', false, null, 0, 3 * 1024 * 1024 + 1024);
if (!is_string($raw) || $raw === '' || strlen($raw) > 3 * 1024 * 1024) {
    api_end(413, ['ok' => false, 'error' => 'Empty or too large body (max 3 MB).']);
}
$data = json_decode($raw, true);
if (!is_array($data)) {
    api_end(400, ['ok' => false, 'error' => 'Invalid JSON.']);
}

$dir = rtrim(SKYWATCH_DATA_DIR, '/');
foreach ([$dir, "$dir/thumbs", "$dir/events"] as $d) {
    if (!is_dir($d) && !mkdir($d, 0750, true)) {
        api_end(500, ['ok' => false, 'error' => "Cannot create $d"]);
    }
}
if (!is_file("$dir/.htaccess")) {
    file_put_contents("$dir/.htaccess", "Require all denied\n"); // keep raw data private on Apache
}

switch ((string) ($data['type'] ?? '')) {
    case 'ping':
        api_end(200, ['ok' => true, 'nvr' => (string) ($data['nvr'] ?? 'SkyWatch'), 'server_time' => date('c')]);

    case 'heartbeat':
        $cams = [];
        foreach ((array) ($data['cameras'] ?? []) as $c) {
            if (!is_array($c) || empty($c['name'])) {
                continue;
            }
            $name = safe_name((string) $c['name']);
            $hasThumb = save_jpeg($c['thumb'] ?? null, "$dir/thumbs/$name.jpg", 200 * 1024);
            $cams[] = [
                'name' => $name, 'label' => (string) ($c['label'] ?? $name), 'ip' => (string) ($c['ip'] ?? ''),
                'via' => (string) ($c['via'] ?? ''), 'online' => !empty($c['online']), 'fps' => (float) ($c['fps'] ?? 0),
                'ai' => !empty($c['ai']), 'thumb' => $hasThumb || is_file("$dir/thumbs/$name.jpg"),
            ];
        }
        save_json("$dir/state.json", [
            'received' => date('c'), 'nvr' => (string) ($data['nvr'] ?? ''), 'version' => (string) ($data['version'] ?? ''),
            'skywatch_url' => (string) ($data['skywatch_url'] ?? ''), 'frigate_url' => (string) ($data['frigate_url'] ?? ''),
            'status' => (array) ($data['status'] ?? []), 'cameras' => $cams,
        ]);
        api_end(200, ['ok' => true]);

    case 'event':
        $events = load_json("$dir/events.json", []);
        $id = (int) (($events[0]['id'] ?? 0) + 1);
        $hasImage = save_jpeg($data['image'] ?? null, "$dir/events/$id.jpg", 2 * 1024 * 1024);
        $event = [
            'id' => $id, 'received' => date('c'), 'ts' => (string) ($data['ts'] ?? date('c')),
            'kind' => (string) ($data['kind'] ?? 'system'), 'camera' => (string) ($data['camera'] ?? ''),
            'camera_label' => (string) ($data['camera_label'] ?? ($data['camera'] ?? '')),
            'subject' => (string) ($data['subject'] ?? ''), 'message' => (string) ($data['message'] ?? ''),
            'score' => isset($data['score']) ? (int) $data['score'] : null,
            'phenomena' => array_values(array_map('strval', (array) ($data['phenomena'] ?? []))),
            'link' => (string) ($data['link'] ?? ''), 'image' => $hasImage,
        ];
        array_unshift($events, $event);
        foreach (array_slice($events, SKYWATCH_KEEP_EVENTS) as $old) {
            @unlink("$dir/events/{$old['id']}.jpg");
        }
        save_json("$dir/events.json", array_slice($events, 0, SKYWATCH_KEEP_EVENTS));

        $emailed = false;
        if (SKYWATCH_MAIL_TO !== '' && in_array($event['kind'], ['sky', 'outage', 'recovery'], true)) {
            $headers = 'From: ' . SKYWATCH_MAIL_FROM . "\r\nContent-Type: text/plain; charset=utf-8";
            $body = $event['message'] . ($event['link'] !== '' ? "\n\n" . $event['link'] : '');
            $emailed = @mail(SKYWATCH_MAIL_TO, '=?UTF-8?B?' . base64_encode($event['subject']) . '?=', $body, $headers);
        }
        api_end(200, ['ok' => true, 'id' => $id, 'emailed' => $emailed]);

    default:
        api_end(400, ['ok' => false, 'error' => 'Unknown type (ping | heartbeat | event).']);
}
