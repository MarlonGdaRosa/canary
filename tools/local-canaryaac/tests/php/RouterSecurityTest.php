<?php
require __DIR__ . '/HttpFixture.php';
$fixture = new HttpFixture();
try {
    $fixture->write('router.php', file_get_contents(__DIR__ . '/../../config/router.php'));
    $fixture->write('index.php', '<?php echo "APPLICATION";');
    $fixture->write('public/index.php', '<?php echo "APPLICATION";');
    foreach (['.env', '.git/HEAD', 'composer.lock', 'canaryaac.sql', 'vendor/composer/installed.json',
        'resources/images/evil.php', 'resources/images/evil.php.gif', 'resources/view/private.html.twig',
        'resources/upload/avatar.png', 'resources/images/.private.png'] as $path) $fixture->write($path, 'FAKE_PRIVATE_SENTINEL');
    $fixture->write('resources/styles/site.css', 'body{color:red}');
    $fixture->write('resources/images/charactertrade/objects/empty.gif', 'GIF89a');
    $fixture->write('outside.png', 'FAKE_PRIVATE_SENTINEL');
    $hasLink = @symlink($fixture->root . '/outside.png', $fixture->root . '/resources/images/escape.png');
    // Junctions need no Windows symlink privilege and exercise the same realpath boundary.
    $fixture->write('private/secret.png', 'FAKE_PRIVATE_SENTINEL');
    $hasDirectoryLink = @symlink($fixture->root . '/private', $fixture->root . '/resources/images/junction');
    if (!$hasDirectoryLink && PHP_OS_FAMILY === 'Windows') {
        $process = proc_open(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            'New-Item -ItemType Junction -Path $env:CANARYAAC_FIXTURE_LINK -Target $env:CANARYAAC_FIXTURE_TARGET -ErrorAction Stop | Out-Null'],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, array_merge(getenv(), [
                'CANARYAAC_FIXTURE_LINK' => $fixture->root . '/resources/images/junction',
                'CANARYAAC_FIXTURE_TARGET' => $fixture->root . '/private']));
        foreach ($pipes as $pipe) { stream_get_contents($pipe); fclose($pipe); }
        $hasDirectoryLink = proc_close($process) === 0;
    }
    $hasRootLink = false;
    if ($hasDirectoryLink && PHP_OS_FAMILY === 'Windows') {
        $process = proc_open(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            'New-Item -ItemType Junction -Path $env:CANARYAAC_FIXTURE_LINK -Target $env:CANARYAAC_FIXTURE_TARGET -ErrorAction Stop | Out-Null'],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, array_merge(getenv(), [
                'CANARYAAC_FIXTURE_LINK' => $fixture->root . '/resources/icons',
                'CANARYAAC_FIXTURE_TARGET' => $fixture->root . '/private']));
        foreach ($pipes as $pipe) { stream_get_contents($pipe); fclose($pipe); }
        $hasRootLink = proc_close($process) === 0;
    }
    $fixture->write('resources/images/.private/secret.png', 'FAKE_PRIVATE_SENTINEL');
    $fixture->write('resources/images/.private/empty.gif', 'FAKE_PRIVATE_SENTINEL');
    $hasHiddenLink = $fixture->directoryLink('resources/images/hidden-alias', 'resources/images/.private');
    $hasHiddenFileLink = @symlink($fixture->root . '/resources/images/.private.png', $fixture->root . '/resources/images/hidden-file.png');
    $fixture->start($fixture->root . '/router.php');
    $denied = ['/.env', '/.git/HEAD', '/composer.lock', '/canaryaac.sql', '/vendor/composer/installed.json',
        '/%2eenv', '/%252eenv', '/.ENV', '/.GIT/HEAD', '/resources/images/../view/private.html.twig',
        '/resources/images/%2e%2e/%2e%2e/.env', '/resources/images/evil.php', '/resources/images/evil.php.gif',
        '/resources/images/.private.png', '/resources/upload/avatar.png', '/resources/images/%00.png', '/index.php'];
    if ($hasLink) $denied[] = '/resources/images/escape.png';
    if ($hasDirectoryLink) $denied[] = '/resources/images/junction/secret.png';
    if ($hasRootLink) $denied[] = '/resources/icons/secret.png';
    if ($hasHiddenLink) $denied[] = '/resources/images/hidden-alias/secret.png';
    if ($hasHiddenFileLink) $denied[] = '/resources/images/hidden-file.png';
    foreach ($denied as $path) {
        $result = $fixture->request($path, 'HEAD');
        expect(in_array($result['status'], [403, 404], true), "$path leaked HTTP " . $result['status']);
        expect($result['body'] === '', "$path returned a HEAD body");
    }
    $asset = $fixture->request('/resources/styles/site.css');
    expect($asset['status'] === 200 && $asset['body'] === 'body{color:red}', 'Allowed asset lost');
    expect(($asset['headers']['x-content-type-options'][0] ?? '') === 'nosniff', 'Static response lacks nosniff');
    expect($fixture->request('/')['body'] === 'APPLICATION', 'Application route lost');
    expect($fixture->request('/resources/images/charactertrade/items/123.gif')['body'] === 'GIF89a', 'Item fallback lost');
    expect($fixture->request('/resources/images/')['status'] === 200, 'Empty image fallback lost');
    unlink($fixture->root . '/resources/images/charactertrade/objects/empty.gif');
    rmdir($fixture->root . '/resources/images/charactertrade/objects');
    if ($fixture->directoryLink('resources/images/charactertrade/objects', 'resources/images/.private')) {
        expect($fixture->request('/resources/images/charactertrade/items/123.gif', 'HEAD')['status'] === 404,
            'Item fallback leaked hidden resolved directory');
    }
    echo 'PASS RouterSecurityTest (' . count($denied) . ' denied paths; allowed assets/fallbacks)' . PHP_EOL;
    if (!$hasLink) echo 'SKIP symlink escape: Windows identity cannot create symlinks' . PHP_EOL;
    if (!$hasDirectoryLink) echo 'SKIP junction escape: fixture identity cannot create junctions' . PHP_EOL;
} finally { $fixture->close(); }
