<?php
require __DIR__ . '/HttpFixture.php';

final class AdminRouteCollector
{
    public array $routes = [];

    public function get(string $path, array $definition): void
    {
        $this->routes[] = 'GET ' . $path;
    }

    public function post(string $path, array $definition): void
    {
        $this->routes[] = 'POST ' . $path;
    }
}

function collectAdminRoutes(string $root, string $environment): array
{
    $_ENV['APP_ENV'] = $environment;
    $obRouter = new AdminRouteCollector();
    require $root . '/routes/local-admin.php';
    return $obRouter->routes;
}

function expectAdminRoute(array $routes, string $route): void
{
    expect(in_array($route, $routes, true), "Expected local admin route missing: {$route}");
}

$root = getenv('CANARYAAC_TEST_ROOT') ?: dirname(__DIR__, 4) . '/.tools/canaryaac';
$localRoutes = collectAdminRoutes($root, 'local');
foreach (['GET /admin', 'GET /admin/login', 'POST /admin/login', 'POST /admin/settings',
    'GET /admin/players', 'POST /admin/groups/import', 'POST /admin/items/import'] as $route) {
    expectAdminRoute($localRoutes, $route);
}
expect(collectAdminRoutes($root, 'production') === [], 'Production registered local admin routes');

$fixture = new HttpFixture();
try {
    $fixture->write('router.php', '<?php require __DIR__ . "/entry.php";');
    $source = <<<'PHP'
<?php
require RUNTIME . '/app/Utils/SecurityFailure.php';
require RUNTIME . '/app/Utils/RateLimiter.php';
require RUNTIME . '/app/Utils/WebSecurity.php';
\App\Utils\WebSecurity::installErrorBoundary();
$environment = ['SITE_NAME' => 'CanaryFixture', 'URL' => 'http://127.0.0.1', 'SECURITY_STATE_DIR' => __DIR__ . '/state'];
if (isset($_GET['production'])) {
    $environment['APP_ENV'] = 'production';
    $environment['URL'] = 'https://canary.example';
    $_SERVER['HTTPS'] = 'on';
}
\App\Utils\WebSecurity::boot($environment);
echo json_encode(['token' => \App\Utils\WebSecurity::csrfToken()]);
PHP;
    $fixture->write('entry.php', str_replace('RUNTIME', var_export($root, true), $source));
    $fixture->start($fixture->root . '/router.php');
    $local = $fixture->request('/admin');
    expect($local['status'] === 200, 'Local admin GET was blocked');
    $cookie = explode(';', $local['headers']['set-cookie'][0])[0];
    expect($fixture->request('/admin/login', 'POST', 'csrf_token=invalid', ['Cookie' => $cookie])['status'] === 403,
        'Local admin POST accepted an invalid CSRF token');
    $token = http_build_query(['csrf_token' => json_decode($local['body'], true)['token']]);
    for ($attempt = 0; $attempt < 10; ++$attempt) {
        expect($fixture->request('/admin/login', 'POST', $token, ['Cookie' => $cookie])['status'] === 200,
            'Local admin login budget was unavailable before exhaustion');
    }
    expect($fixture->request('/admin/login', 'POST', $token, ['Cookie' => $cookie])['status'] === 429,
        'Local admin login limit was not enforced');
    expect($fixture->request('/admin?production=1')['status'] === 404, 'Production admin GET was enabled');
    echo "PASS AdminRoutesTest (local admin routes, production boundary, CSRF)\n";
} finally {
    $fixture->close();
}
