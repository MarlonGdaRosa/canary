<?php
require __DIR__ . '/HttpFixture.php';
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
use App\Utils\Argon;
Argon::configArgon('65536', '2', '2');
$password = 'Valid<&Pass12';
$hash = Argon::generateArgonPassword($password);
expect(preg_match('/^\$[A-Za-z0-9+\/]{22}\$[A-Za-z0-9+\/]{43}$/D', $hash) === 1, 'New password is not compact Argon2id');
expect(password_verify($password, '$argon2id$v=19$m=65536,t=2,p=2' . $hash), 'Compact hash cannot reconstruct');
expect(Argon::checkPassword($password, $hash, 123), 'Correct compact password denied / authentication tried DB migration');
expect(!Argon::checkPassword('wrong', $hash), 'Wrong compact password accepted');
expect(Argon::checkPassword($password, sha1($password), 123), 'Legacy SHA1 denied');
expect(!Argon::checkPassword('wrong', sha1($password)), 'Wrong SHA1 accepted');
foreach (['', str_repeat('a', 1000), '$x$y', '$argon2id$v=19$m=999999999,t=999999,p=999999$bad$bad'] as $bad)
    expect(!Argon::checkPassword($password, $bad), 'Malformed/unbounded hash accepted');
foreach ([['1 << 16', 2, 2], [0, 2, 2], [999999999, 2, 2], [65536, 1000, 2], [65536, 2, 1000], [[], 2, 2]] as $costs) {
    try { Argon::configArgon(...$costs); throw new RuntimeException('Invalid costs accepted'); }
    catch (InvalidArgumentException $expected) {}
}
Argon::configArgon(65536, 2, 2);
echo "PASS ArgonCompatibilityTest (compact Argon2id, legacy SHA1, costs bounded, no auth writes)\n";
