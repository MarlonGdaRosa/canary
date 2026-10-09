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
    $token = json_decode($local['body'], true)['token'];
    $adminLogin = http_build_query([
        'csrf_token' => $token,
        'login-email' => 'admin@example.invalid',
        'login-password' => 'not-a-password',
    ]);
    expect($fixture->request('/account/login', 'POST', $adminLogin, ['Cookie' => $cookie])['status'] === 400,
        'Hyphenated admin fields were accepted by the account login');
    expect($fixture->request('/admin/settings', 'POST', $adminLogin, ['Cookie' => $cookie])['status'] === 400,
        'Hyphenated admin login fields were accepted by another admin route');
    expect($fixture->request('/admin/login', 'POST', $adminLogin, ['Cookie' => $cookie])['status'] === 200,
        'The admin login form fields were rejected before authentication');
    $token = http_build_query(['csrf_token' => $token]);
    for ($attempt = 0; $attempt < 9; ++$attempt) {
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

$renderFixture = new HttpFixture();
try {
    $renderFixture->write('router.php', '<?php require __DIR__ . "/entry.php";');
    $renderSource = <<<'PHP'
<?php
require RUNTIME . '/vendor/autoload.php';
require RUNTIME . '/app/Utils/SecurityFailure.php';
require RUNTIME . '/app/Utils/RateLimiter.php';
require RUNTIME . '/app/Utils/WebSecurity.php';
require RUNTIME . '/app/Utils/View.php';
\App\Utils\WebSecurity::installErrorBoundary();
\App\Utils\WebSecurity::boot([
    'SITE_NAME' => 'CanaryFixture',
    'URL' => 'http://127.0.0.1',
    'SECURITY_STATE_DIR' => __DIR__ . '/state',
]);
define('SITE_NAME', 'CanaryFixture');
\App\Utils\View::init(['URL' => 'http://127.0.0.1']);
echo \App\Utils\View::render('admin/login', ['title' => 'Login', 'status' => '']);
PHP;
    $renderFixture->write('entry.php', str_replace('RUNTIME', var_export($root, true), $renderSource));
    $renderFixture->start($renderFixture->root . '/router.php');
    $rendered = $renderFixture->request('/admin/login');
    expect($rendered['status'] === 200, 'Admin login form did not render');
    expect(preg_match('/<input[^>]+name="csrf_token"[^>]+value="[a-f0-9]{64}"/i', $rendered['body']) === 1,
        'Admin login form did not render a CSRF token');
    expect(str_contains($rendered['body'], 'name="login-email"'), 'Admin login email field changed unexpectedly');
    expect(str_contains($rendered['body'], 'name="login-password"'), 'Admin login password field changed unexpectedly');
    echo "PASS AdminRoutesTest (rendered admin login CSRF form)\n";
} finally {
    $renderFixture->close();
}
