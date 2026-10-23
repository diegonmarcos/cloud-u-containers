<?php
/**
 * Matomo Tracking Payload Receiver
 *
 * Captures tracking requests when Matomo is sleeping and saves them as JSON
 * to /inbox/ for later bulk import via import-inbox.sh.
 *
 * Handles: matomo.php, piwik.php, collect.php, api.php, track.php
 */

// Capture request data
$payload = [
    'timestamp' => date('Y-m-d H:i:s'),
    'unix_ts'   => time(),
    'method'    => $_SERVER['REQUEST_METHOD'] ?? 'GET',
    'query'     => $_SERVER['QUERY_STRING'] ?? '',
    'post_body' => '',
    'ip'        => '',
    'ua'        => $_SERVER['HTTP_USER_AGENT'] ?? '',
    'referer'   => $_SERVER['HTTP_REFERER'] ?? '',
];

// Read POST body if present
if ($payload['method'] === 'POST') {
    $payload['post_body'] = file_get_contents('php://input') ?: '';
}

// Get client IP from proxy headers (NPM sets X-Forwarded-For)
if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
    // Take the first IP (original client) from the chain
    $ips = explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']);
    $payload['ip'] = trim($ips[0]);
} elseif (!empty($_SERVER['HTTP_X_REAL_IP'])) {
    $payload['ip'] = $_SERVER['HTTP_X_REAL_IP'];
} else {
    $payload['ip'] = $_SERVER['REMOTE_ADDR'] ?? '127.0.0.1';
}

// Generate unique filename: {timestamp}_{uniqid}.json
$filename = sprintf(
    '%d_%s.json',
    $payload['unix_ts'],
    substr(uniqid('', true), -10)
);

$filepath = '/inbox/' . $filename;

// Save payload as JSON
$json = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
file_put_contents($filepath, $json);

// Return 1x1 transparent GIF (standard Matomo tracking pixel response)
header('Content-Type: image/gif');
header('Cache-Control: no-cache, no-store, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');
header('Access-Control-Allow-Origin: *');

// 1x1 transparent GIF (43 bytes)
echo base64_decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
