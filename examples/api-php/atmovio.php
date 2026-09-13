<?php
/**
 * Minimal Atmovio REST API client (PHP 8.0+, ext-curl, no dependencies).
 *
 *   require 'atmovio.php';
 *   $api = new Atmovio(ATMOVIO_URL, ATMOVIO_KEY);
 *   $status = $api->status();                 // array
 *   $det    = $api->detections(['limit' => 5]);
 *   $jpeg   = $api->snapshot('zahrada', 720);  // binary JPEG
 *
 * All methods throw AtmovioException on network/HTTP errors.
 * Endpoints: https://github.com/VladimirVecera/atmovio/blob/main/docs/api.md
 */
declare(strict_types=1);

final class AtmovioException extends RuntimeException
{
    public function __construct(string $message, public readonly int $httpCode = 0)
    {
        parent::__construct($message);
    }
}

final class Atmovio
{
    public function __construct(
        private string $baseUrl,
        private string $apiKey,
        private int $timeout = 8,
    ) {
        $this->baseUrl = rtrim($baseUrl, '/');
    }

    /** GET /api/v1/status – NVR status: version, Frigate, storage, AI usage, sun, system, outages, update */
    public function status(): array
    {
        return $this->getJson('/api/v1/status');
    }

    /** GET /api/health – no authentication, for monitoring */
    public function health(): array
    {
        return $this->getJson('/api/health', [], false);
    }

    /** GET /api/v1/cameras – cameras with online/fps/ip, AI flags, snapshot_url */
    public function cameras(): array
    {
        return $this->getJson('/api/v1/cameras')['cameras'] ?? [];
    }

    /** GET /api/v1/cameras/{name}/snapshot.jpg – current frame as binary JPEG (height 120–1080) */
    public function snapshot(string $camera, int $height = 720): string
    {
        return $this->getRaw('/api/v1/cameras/' . rawurlencode($camera) . '/snapshot.jpg', ['h' => $height]);
    }

    /**
     * GET /api/v1/detections – latest AI detections.
     * $params: limit (1–200), camera, notified (1 = alerts only, default; 0 = every evaluation), min_score (0–10)
     */
    public function detections(array $params = []): array
    {
        return $this->getJson('/api/v1/detections', $params)['detections'] ?? [];
    }

    /** GET /api/v1/detections/{id} */
    public function detection(int $id): array
    {
        return $this->getJson('/api/v1/detections/' . $id);
    }

    /** GET /api/v1/detections/{id}/image.jpg – the AI snapshot as binary JPEG */
    public function detectionImage(int $id): string
    {
        return $this->getRaw('/api/v1/detections/' . $id . '/image.jpg');
    }

    /** GET /api/v1/videos – exported clips with download URLs */
    public function videos(): array
    {
        return $this->getJson('/api/v1/videos')['videos'] ?? [];
    }

    /** GET /api/v1/videos/{id}/download – MP4 written to $toFile; returns bytes written */
    public function downloadVideo(int $id, string $toFile): int
    {
        $data = $this->getRaw('/api/v1/videos/' . $id . '/download');
        $n = file_put_contents($toFile, $data);
        if ($n === false) throw new AtmovioException("cannot write $toFile");
        return $n;
    }

    /** GET /api/v1/events – outage / recovery / sky events log */
    public function events(int $limit = 20): array
    {
        return $this->getJson('/api/v1/events', ['limit' => $limit])['events'] ?? [];
    }

    // ---------------------------------------------------------------- internals

    private function getJson(string $path, array $params = [], bool $auth = true): array
    {
        $body = $this->getRaw($path, $params, $auth);
        $data = json_decode($body, true);
        if (!is_array($data)) throw new AtmovioException("invalid JSON from $path");
        return $data;
    }

    private function getRaw(string $path, array $params = [], bool $auth = true): string
    {
        $url = $this->baseUrl . $path . ($params ? '?' . http_build_query($params) : '');
        $ch = curl_init($url);
        $headers = ['Accept: application/json, image/jpeg'];
        if ($auth) $headers[] = 'Authorization: Bearer ' . $this->apiKey;
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_TIMEOUT        => $this->timeout,
            CURLOPT_CONNECTTIMEOUT => min(4, $this->timeout),
        ]);
        $body = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $err  = curl_error($ch);
        curl_close($ch);

        if ($body === false) throw new AtmovioException("Atmovio unreachable at {$this->baseUrl}: $err");
        if ($code === 401 || $code === 403) throw new AtmovioException('API key rejected (401/403) – create one in Nastavení → Systém → API', $code);
        if ($code === 404) throw new AtmovioException("not found: $path", $code);
        if ($code >= 400) throw new AtmovioException("HTTP $code from $path", $code);
        return (string) $body;
    }
}
