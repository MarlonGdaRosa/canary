<?php
// Installed in the application root. Never delegate existing files to php -S.
clearstatcache(true);
$root = realpath(__DIR__);
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: strict-origin-when-cross-origin');
header("Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://code.jquery.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; font-src 'self' data: https:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'");
$deny = static function (): never {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'HEAD') echo 'Not Found';
    exit;
};
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (!is_string($path) || !str_starts_with($path, '/')) $deny();
$path = rawurldecode($path);
$safeSegments = static function (string $relativePath): bool {
    if (preg_match('/[\\\\:%\x00-\x1f\x7f]/', $relativePath)) return false;
    foreach (explode('/', $relativePath) as $segment) {
        if (str_starts_with($segment, '.') || preg_match('/\.(?:php\d*|phtml|phar|sql|env|ini|lock|twig|bak|old|log)(?:\.|$)/i', $segment)) return false;
    }
    return true;
};
if (!$safeSegments($path)) $deny();
$allowedDirectories = ['base', 'bootstrap', 'canary', 'icons', 'images', 'javascripts', 'styles'];
$types = ['css' => 'text/css', 'js' => 'text/javascript', 'png' => 'image/png', 'jpg' => 'image/jpeg',
    'jpeg' => 'image/jpeg', 'gif' => 'image/gif', 'svg' => 'image/svg+xml', 'webp' => 'image/webp',
    'ico' => 'image/x-icon', 'woff' => 'font/woff', 'woff2' => 'font/woff2', 'ttf' => 'font/ttf', 'eot' => 'application/vnd.ms-fontobject'];
$within = static function (string $file, string $directory): bool {
    // Case-insensitive Windows filesystem; separator boundary prevents prefix collisions.
    $prefix = rtrim($directory, '/\\') . DIRECTORY_SEPARATOR;
    return PHP_OS_FAMILY === 'Windows' ? str_starts_with(strtolower($file), strtolower($prefix)) : str_starts_with($file, $prefix);
};
$allowedTarget = static function (string $file, string $directory) use ($within, $safeSegments, $types): bool {
    if (!is_file($file) || !$within($file, $directory)) return false;
    $relativePath = str_replace(DIRECTORY_SEPARATOR, '/', substr($file, strlen(rtrim($directory, '/\\')) + 1));
    return $safeSegments($relativePath) && isset($types[strtolower(pathinfo($file, PATHINFO_EXTENSION))]);
};
$serve = static function (string $file, string $type): never {
    header('Content-Type: ' . $type);
    header('Content-Length: ' . filesize($file));
    header('Cache-Control: public, max-age=86400');
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'HEAD') readfile($file);
    exit;
};
if (str_starts_with(strtolower($path), '/resources/')) {
    if (!in_array($_SERVER['REQUEST_METHOD'] ?? '', ['GET', 'HEAD'], true)) $deny();
    if ($path === '/resources/images/' || $path === '/resources/images') {
        header('Content-Type: image/png');
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'HEAD') echo base64_decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');
        exit;
    }
    $parts = explode('/', $path);
    if (!in_array($parts[2] ?? '', $allowedDirectories, true)) $deny();
    $directory = realpath($root . '/resources/' . $parts[2]);
    $file = realpath($root . $path);
    $extension = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if (!isset($types[$extension]) || !$directory || !$within($directory, $root)) $deny();
    $expectedDirectory = $root . DIRECTORY_SEPARATOR . 'resources' . DIRECTORY_SEPARATOR . $parts[2];
    if ((PHP_OS_FAMILY === 'Windows' ? strcasecmp($directory, $expectedDirectory) : strcmp($directory, $expectedDirectory)) !== 0) $deny();
    if ($file !== false) {
        if (!$allowedTarget($file, $directory)) $deny();
        $serve($file, $types[$extension]);
    }
    // Retain only the two known image fallbacks, subject to the same containment.
    if (preg_match('#^/resources/images/charactertrade/items/[0-9]+\.gif$#', $path)) {
        $fallback = realpath($root . '/resources/images/charactertrade/objects/empty.gif');
        if ($fallback && $allowedTarget($fallback, $directory)) $serve($fallback, $types[strtolower(pathinfo($fallback, PATHINFO_EXTENSION))]);
    }
    $deny();
}
// A URL resembling a file outside the asset surface never reaches application code.
if (preg_match('/\.[a-z0-9]+(?:\/|$)/i', $path)) $deny();
require $root . '/public/index.php';
