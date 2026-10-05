<?php
$root = realpath(__DIR__);
$uriPath = rawurldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?? '/');
$candidate = realpath($root . DIRECTORY_SEPARATOR . ltrim($uriPath, '/'));
if ($candidate !== false && str_starts_with($candidate, $root . DIRECTORY_SEPARATOR) && is_file($candidate)) {
    return false;
}
require $root . DIRECTORY_SEPARATOR . 'index.php';
