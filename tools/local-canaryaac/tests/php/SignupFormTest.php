<?php
require __DIR__ . '/HttpFixture.php';
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
$_ENV['DEV_MODE'] = 'false';
$twig = App\Utils\View::getContentView('pages/account');
$twig->setCache(false);
$html = $twig->render('createaccount.html.twig', ['worlds'=>[], 'activevoc'=>1]);
foreach (['accname'=>32, 'email'=>254, 'password1'=>128, 'password2'=>128, 'name'=>29] as $field=>$length) {
    preg_match('/<input[^>]*name="'.preg_quote($field, '/').'"[^>]*>/', $html, $match);
    expect(isset($match[0]) && str_contains($match[0], 'maxlength="'.$length.'"'), 'Wrong form length for '.$field);
}
foreach ([1,2,3,4,9] as $vocation) expect(str_contains($html, 'name="vocation" value="'.$vocation.'"'), 'Missing vocation');
expect(!str_contains($html, '/api/v1/check_charactername'), 'Signup JavaScript sends password to disabled availability endpoint');
$confirm = $twig->render('createaccount_confirm.html.twig', ['account'=>['email'=>'<danger>@example.invalid','password'=>'PRIVATE_SENTINEL'], 'character'=>[]]);
expect(!str_contains($confirm, 'PRIVATE_SENTINEL') && str_contains($confirm, '&lt;danger&gt;'), 'Confirmation exposes hash or fails escaping');
echo "PASS SignupFormTest (lengths, vocations, escaping, no password AJAX or confirmation)\n";
