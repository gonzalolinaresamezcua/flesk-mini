<?php
/** Imagen del captcha deslizante del login (SVG, sin caché). */
declare(strict_types=1);
require __DIR__ . '/auth.php';
require __DIR__ . '/includes/captcha.php';
$svg = fresk_captcha_svg((string)($_GET['t'] ?? ''));
header('Cache-Control: no-store, max-age=0');
header('X-Content-Type-Options: nosniff');
if ($svg === null) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'captcha expired';
    exit;
}
header('Content-Type: image/svg+xml; charset=utf-8');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox");
echo $svg;
