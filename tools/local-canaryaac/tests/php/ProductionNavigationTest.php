<?php
$root = getenv('CANARYAAC_TEST_ROOT') ?: dirname(__DIR__, 4) . '/.tools/canaryaac';
require $root . '/vendor/autoload.php';
$allowed = ['latestnews','newsarchive','library/creatures','library/boostablebosses','library/achievements','library/experiencetable',
    'community/characters','community/worlds','community/highscores','community/lastdeaths','account','createaccount','downloads','support/rules','support/team'];
foreach (\App\Controller\Pages\Base::getMenu('latestnews') as $item) {
    if (!in_array($item['link'], $allowed, true)) throw new RuntimeException('Menu offers disabled route: ' . $item['link']);
}
$pagination = new \App\DatabaseManager\Pagination(200, '0.5', 10);
if ($pagination->getLimit() !== '0,10') throw new RuntimeException('Fractional page produces invalid SQL LIMIT');
foreach (['-1', '1e3', 'NaN', [], '999999999999999999999999999999'] as $value) {
    if ((new \App\DatabaseManager\Pagination(200, $value, 10))->getLimit() !== '0,10') throw new RuntimeException('Invalid page accepted');
}
if ((new \App\DatabaseManager\Pagination(200, '3', 10))->getLimit() !== '20,10') throw new RuntimeException('Valid pagination changed');
if (!method_exists(\App\Utils\WebSecurity::class, 'productionCacheDirectory')) throw new RuntimeException('Private production cache missing');
foreach ([$root . '/public/cache', $root . '/resources/view/cache', 'relative'] as $path) {
    try { \App\Utils\WebSecurity::productionCacheDirectory($path); }
    catch (\App\Utils\SecurityFailure $expected) { continue; }
    throw new RuntimeException('Unsafe cache accepted');
}
echo "PASS ProductionNavigationTest (enabled menu, integer pagination, private cache boundary)\n";
