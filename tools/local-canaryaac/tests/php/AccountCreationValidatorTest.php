<?php
require __DIR__ . '/HttpFixture.php';
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
use App\Utils\AccountCreationValidator;
expect(class_exists(AccountCreationValidator::class), 'Shared signup validator missing');
$valid = ['accname' => 'Alice123', 'email' => 'Alice@example.invalid', 'password1' => 'Valid<&Pass12',
    'password2' => 'Valid<&Pass12', 'name' => 'Alice Knight', 'sex' => '2', 'vocation' => '9', 'world' => '1', 'agreeagreements' => 'true'];
foreach (['1', '2', '3', '4', '9'] as $vocation) {
    $data = AccountCreationValidator::validate(array_replace($valid, ['vocation' => $vocation]));
    expect($data === ['accountName' => 'Alice123', 'email' => 'alice@example.invalid', 'password' => 'Valid<&Pass12',
        'characterName' => 'Alice Knight', 'sex' => 0, 'vocation' => (int) $vocation], 'Validated values changed');
}
foreach (json_decode(file_get_contents(__DIR__ . '/../fixtures/invalid-submissions.json'), true, 512, JSON_THROW_ON_ERROR) as $case) {
    try { AccountCreationValidator::validate(array_replace($valid, $case)); throw new RuntimeException('Invalid signup accepted'); }
    catch (InvalidArgumentException $expected) {}
}
foreach (['password1', 'accname', 'name', 'email', 'world', 'sex', 'vocation', 'agreeagreements'] as $key) {
    try { AccountCreationValidator::validate(array_replace($valid, [$key => ['injected']])); throw new RuntimeException('Array accepted'); }
    catch (InvalidArgumentException $expected) {}
}
foreach (["bad\xFFpassword123", "Valid\0Pass123", str_repeat('x', 129), str_repeat('é', 129)] as $password) {
    try { AccountCreationValidator::validate(array_replace($valid, ['password1' => $password, 'password2' => $password])); throw new RuntimeException('Invalid password accepted'); }
    catch (InvalidArgumentException $expected) {}
}
foreach ([str_repeat('x', 12), str_repeat('é', 128), 'a password with spaces'] as $password)
    expect(AccountCreationValidator::validate(array_replace($valid, ['password1' => $password, 'password2' => $password]))['password'] === $password, 'Valid UTF8 password changed');
foreach ([12, 128, 129] as $count) {
    $password = str_repeat("\u{1F680}", $count);
    try {
        $actual = AccountCreationValidator::validate(array_replace($valid, ['password1'=>$password, 'password2'=>$password]));
        expect($count <= 128 && $actual['password'] === $password, 'Supplementary password boundary failed');
    } catch (InvalidArgumentException $error) { expect($count === 129, 'Valid supplementary password rejected'); }
}
$fixture = new HttpFixture();
try {
    $fixture->write('router.php', '<?php require __DIR__ . "/entry.php";');
    $fixture->write('entry.php', '<?php require ' . var_export($runtime . '/vendor/autoload.php', true) . '; App\Utils\WebSecurity::installErrorBoundary(); App\Utils\WebSecurity::boot(["SITE_NAME"=>"SignupFixture","SECURITY_STATE_DIR"=>__DIR__."/state"]); echo json_encode(["token"=>App\Utils\WebSecurity::csrfToken()]);');
    $fixture->start($fixture->root . '/router.php');
    $first = $fixture->request('/');
    $headers = ['Cookie' => explode(';', $first['headers']['set-cookie'][0])[0]];
    $body = http_build_query($valid + ['csrf_token' => json_decode($first['body'], true)['token']]);
    foreach (['&accname=other', '&%61ccname=other', '&password1=other', '&world[]=2', '&csrf_token=other', '&accname.x=other'] as $duplicate)
        expect($fixture->request('/createaccount', 'POST', $body . $duplicate, $headers)['status'] === 400, 'Raw duplicate/ambiguous form field accepted');
} finally { $fixture->close(); }
echo "PASS AccountCreationValidatorTest (five vocations, strict fields, raw UTF8 password, HTTP duplicates)\n";
