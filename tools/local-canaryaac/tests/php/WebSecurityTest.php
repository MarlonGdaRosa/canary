<?php
require __DIR__ . '/HttpFixture.php';
$fixture = new HttpFixture();
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
try {
    $fixture->write('router.php', '<?php require __DIR__ . "/entry.php";');
    $source = <<<'PHP'
<?php
$runtime = RUNTIME;
if (!is_file($runtime . '/app/Utils/WebSecurity.php')) { http_response_code(500); echo 'Security helper missing'; return; }
require $runtime . '/app/Utils/SecurityFailure.php';
require $runtime . '/app/Utils/WebSecurity.php';
require $runtime . '/app/Utils/RateLimiter.php';
require $runtime . '/app/Session/Admin/Login.php';
use App\Utils\WebSecurity;
use App\Session\Admin\Login;
WebSecurity::installErrorBoundary();
$environment = ['SITE_NAME' => 'CanaryFixture', 'URL' => 'http://127.0.0.1',
    'SECURITY_STATE_DIR' => __DIR__ . '/state'];
if (isset($_GET['production'])) {
    $environment['APP_ENV'] = 'production';
    $environment['URL'] = $_GET['url'] ?? 'https://canary.test';
    $_SERVER['HTTPS'] = isset($_GET['insecure']) ? 'off' : 'on';
}
if (isset($_GET['badstate'])) $environment['SECURITY_STATE_DIR'] = __DIR__ . '/entry.php';
WebSecurity::boot($environment);
if (!defined('SITE_NAME')) define('SITE_NAME', 'CanaryFixture');
if (isset($_GET['view'])) {
    require_once $runtime . '/vendor/autoload.php';
    $_ENV['DEV_MODE'] = 'false';
    $twig = \App\Utils\View::getContentView('pages/account');
    $twig->load('index.html.twig');
    echo json_encode(['escaped' => $twig->createTemplate('{{ value }}')->render(['value' => '<script>bad</script>']), 'debug' => $twig->isDebug()]);
} elseif (isset($_GET['assets'])) {
    require_once $runtime . '/vendor/autoload.php';
    define('URL', 'http://127.0.0.1');
    define('OUTFITS_FOLDER', '/resources/images/charactertrade/outfits');
    echo json_encode([\App\Model\Functions\Player::getOutfitImage(129), \App\Model\Functions\Server::getMonsterImage(0, 129)]);
} elseif (isset($_GET['authenticate'])) {
    $before = session_id();
    Login::login((object) ['id' => 123, 'name' => 'Fixture', 'email' => 'fixture@example.invalid']);
    $after = session_id();
    Login::isLogged();
    echo json_encode(['changed' => $before !== $after, 'stable' => $after === session_id(), 'logged' => Login::isLogged()]);
} elseif (isset($_GET['throw'])) {
    throw new RuntimeException('FAKE_SECRET_SENTINEL', 1234);
} elseif (isset($_GET['warning'])) {
    trigger_error('FAKE_SECRET_SENTINEL', E_USER_WARNING);
    echo 'Unexpected continuation';
} elseif (str_starts_with($_SERVER['REQUEST_URI'], '/account/logout')) {
    Login::logout();
    echo json_encode(['logged' => isset($_SESSION['account']['user']), 'session' => session_status()]);
} else {
    echo json_encode(['token' => WebSecurity::csrfToken(), 'session' => session_id(), 'debug' => WebSecurity::debugEnabled('false')]);
}
PHP;
    $fixture->write('entry.php', str_replace('RUNTIME', var_export($runtime, true), $source));
    $fixture->start($fixture->root . '/router.php');
    $first = $fixture->request('/');
    expect($first['status'] === 200, 'Security boot missing: HTTP ' . $first['status']);
    $data = json_decode($first['body'], true);
    expect(strlen($data['token'] ?? '') === 64, 'CSRF token is not 256 random bits');
    expect($data['debug'] === false, 'Text false enabled development mode');
    $cookie = explode(';', $first['headers']['set-cookie'][0])[0];
    expect(str_contains($first['headers']['set-cookie'][0], 'HttpOnly') && str_contains($first['headers']['set-cookie'][0], 'SameSite=Lax'), 'Cookie flags absent');
    expect(!str_contains($first['headers']['set-cookie'][0], 'secure'), 'Local HTTP cookie is secure');
    $headers = ['Cookie' => $cookie];
    expect($fixture->request('/community/characters/Test%20Player?production=1')['status'] === 200, 'Encoded spaces broke read-only character URLs');
    $view = json_decode($fixture->request('/?view=1')['body'], true);
    expect($view['escaped'] === '&lt;script&gt;bad&lt;/script&gt;' && $view['debug'] === false, 'Twig false-mode disables escaping or enables debug');
    foreach (json_decode($fixture->request('/?assets=1')['body'], true) as $url)
        expect($url === 'http://127.0.0.1/resources/images/charactertrade/objects/transparent.svg', 'Outfit placeholder still executes PHP');
    foreach (['', 'csrf_token=invalid', 'csrf_token[]=array'] as $body) {
        $result = $fixture->request('/createaccount', 'POST', $body, $headers);
        expect($result['status'] === 403 && $result['body'] === 'Forbidden', 'Invalid CSRF allowed');
    }
    $token = http_build_query(['csrf_token' => $data['token']]);
    expect($fixture->request('/createaccount', 'POST', $token)['status'] === 403, 'Cross-session token allowed');
    expect($fixture->request('/createaccount', 'POST', str_repeat('x', 65537), $headers)['status'] === 400, 'Oversized body allowed');
    for ($i = 0; $i < 5; ++$i) expect($fixture->request('/createaccount', 'POST', $token, $headers)['status'] === 200, 'Signup limit too early');
    $limit = $fixture->request('/createaccount', 'POST', $token, $headers + ['X-Forwarded-For' => '192.0.2.1']);
    expect($limit['status'] === 429 && (int) ($limit['headers']['retry-after'][0] ?? 0) > 0, 'Persistent signup limit not enforced');
    for ($i = 0; $i < 10; ++$i) expect($fixture->request('/account/login', 'POST', $token, $headers)['status'] === 200, 'Login budget is not separate');
    expect($fixture->request('/account/login', 'POST', $token, $headers)['status'] === 429, 'Login limit absent');
    foreach (['/admin', '/api/login', '/account/changepassword', '/account/createcharacter', '/account/lostaccount', '/payment', '/account/logout'] as $path)
        expect($fixture->request($path . '?production=1')['status'] === 404, 'Unreviewed production route enabled: ' . $path);
    expect($fixture->request('/?production=1&url=http://canary.test')['status'] === 503, 'Production HTTP URL accepted');
    expect($fixture->request('/?production=1&insecure=1')['status'] === 503, 'Production HTTP request accepted');
    expect($fixture->request('/?production=1&url=https://localhost')['status'] === 503, 'Production loopback accepted');
    expect($fixture->request('/?badstate=1')['status'] === 503, 'Unsafe private state accepted');
    $production = $fixture->request('/?production=1');
    expect($production['status'] === 200 && stripos($production['headers']['set-cookie'][0] ?? '', 'secure') !== false, 'Production secure cookie missing');
    $auth = $fixture->request('/?authenticate=1', 'GET', '', $headers);
    $authData = json_decode($auth['body'], true);
    expect($authData['changed'] && $authData['stable'] && $authData['logged'], 'Authentication ID boundary broken');
    $authCookie = explode(';', $auth['headers']['set-cookie'][0])[0];
    $afterAuth = $fixture->request('/', 'GET', '', ['Cookie' => $authCookie]);
    $newToken = json_decode($afterAuth['body'], true)['token'];
    expect($fixture->request('/account/logout', 'POST', $token, ['Cookie' => $authCookie])['status'] === 403, 'Pre-login token survives auth boundary');
    $logout = $fixture->request('/account/logout', 'POST', http_build_query(['csrf_token' => $newToken]), ['Cookie' => $authCookie]);
    $logoutData = json_decode($logout['body'], true);
    expect($logout['status'] === 200 && !$logoutData['logged'] && $logoutData['session'] === PHP_SESSION_NONE, 'Logout did not destroy session');
    expect(str_contains($logout['headers']['set-cookie'][0] ?? '', 'Max-Age=0'), 'Logout cookie not expired');
    $error = $fixture->request('/?throw=1');
    expect($error['status'] === 500 && $error['body'] === 'Internal Server Error', 'Exception leaked or invalid status');
    $warning = $fixture->request('/?warning=1');
    expect($warning['status'] === 500 && $warning['body'] === 'Internal Server Error', 'Warning bypassed redacted error boundary');
    echo 'PASS WebSecurityTest (CSRF, budgets, cookies, production gates, authentication, redacted errors)' . PHP_EOL;
} finally { $fixture->close(); }
