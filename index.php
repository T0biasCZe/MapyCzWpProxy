<?php

const ALLOWED_HOST_SUFFIXES = ['mapy.cz', 'mapy.com'];
const CACHE_TTL_SECONDS = 604800;
const CACHE_DIR = __DIR__ . '/cache';
const CONNECT_TIMEOUT = 10;
const TOTAL_TIMEOUT   = 30;

function fail(int $status, string $message): void {
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    header('Cache-Control: no-store');
    echo $message . "\n";
    exit;
}

function host_allowed(string $host): bool {
    $host = strtolower(rtrim($host, '.'));
    foreach (ALLOWED_HOST_SUFFIXES as $allowed) {
        if ($host === $allowed) return true;
        if (substr($host, -(strlen($allowed) + 1)) === '.' . $allowed) return true;
    }
    return false;
}

$url = isset($_GET['url']) ? (string)$_GET['url'] : '';
if ($url === '') {
    fail(400, 'Missing ?url= parameter.');
}
if (strlen($url) > 2048) {
    fail(414, 'URL too long.');
}

$parts = parse_url($url);
if ($parts === false || empty($parts['scheme']) || empty($parts['host'])) {
    fail(400, 'Malformed URL.');
}
$scheme = strtolower($parts['scheme']);
if ($scheme !== 'http' && $scheme !== 'https') {
    fail(400, 'Only http/https URLs are allowed.');
}
if (!host_allowed($parts['host'])) {
    fail(403, 'Host not allowed: ' . $parts['host']);
}

$cacheEnabled = CACHE_TTL_SECONDS > 0;
$cacheFile = null;
$metaFile  = null;

if ($cacheEnabled) {
    if (!is_dir(CACHE_DIR)) {
        @mkdir(CACHE_DIR, 0775, true);
    }
    if (is_dir(CACHE_DIR) && is_writable(CACHE_DIR)) {
        $key = sha1($url);
        $cacheFile = CACHE_DIR . '/' . $key . '.bin';
        $metaFile  = CACHE_DIR . '/' . $key . '.type';
    } else {
        $cacheEnabled = false;
    }
}

if ($cacheEnabled && is_file($cacheFile) && (time() - filemtime($cacheFile)) < CACHE_TTL_SECONDS) {
    $contentType = is_file($metaFile) ? trim((string)file_get_contents($metaFile)) : 'application/octet-stream';
    header('Content-Type: ' . $contentType);
    header('Content-Length: ' . filesize($cacheFile));
    header('Cache-Control: public, max-age=' . CACHE_TTL_SECONDS);
    header('X-Proxy-Cache: HIT');
    readfile($cacheFile);
    exit;
}

$ch = curl_init($url);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_FOLLOWLOCATION => false,
    CURLOPT_CONNECTTIMEOUT => CONNECT_TIMEOUT,
    CURLOPT_TIMEOUT        => TOTAL_TIMEOUT,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
    CURLOPT_USERAGENT      => 'Mozilla/5.0 (compatible; MapyCzWpClientRT-proxy/1.0)',
    CURLOPT_REFERER        => 'https://mapy.com/',
    CURLOPT_ENCODING       => '',
]);

$body = curl_exec($ch);
if ($body === false) {
    $err = curl_error($ch);
    curl_close($ch);
    fail(502, 'Upstream fetch failed: ' . $err);
}
$status      = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
$contentType = (string)curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
curl_close($ch);

if ($status < 200 || $status >= 300) {
    fail($status ?: 502, 'Upstream returned HTTP ' . $status);
}
if ($contentType === '') {
    $contentType = 'application/octet-stream';
}

if ($cacheEnabled) {
    $tmp = $cacheFile . '.' . getmypid() . '.tmp';
    if (@file_put_contents($tmp, $body) !== false) {
        @rename($tmp, $cacheFile);
        @file_put_contents($metaFile, $contentType);
    } else {
        @unlink($tmp);
    }
}

header('Content-Type: ' . $contentType);
header('Content-Length: ' . strlen($body));
header('Cache-Control: public, max-age=' . CACHE_TTL_SECONDS);
header('X-Proxy-Cache: MISS');
echo $body;
