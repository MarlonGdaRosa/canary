<?php
require __DIR__ . '/HttpFixture.php';
if (!in_array('sqlite', PDO::getAvailableDrivers(), true)) {
    if (in_array('--sqlite-retry', $argv, true)) {
        fwrite(STDERR, "SQLite unavailable after one extension retry; enable pdo_sqlite for this test.\n");
        exit(1);
    }
    passthru(escapeshellarg(PHP_BINARY) . ' -c ' . escapeshellarg(php_ini_loaded_file()) . ' -d extension=pdo_sqlite ' . escapeshellarg(__FILE__) . ' --sqlite-retry', $status);
    exit($status);
}
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
use App\DatabaseManager\Database;
use App\Model\Entity\CreateAccount;
expect(method_exists(Database::class, 'transaction') && method_exists(CreateAccount::class, 'createAccountWithCharacter'), 'Atomic signup API missing');
$pdo = new PDO('sqlite::memory:', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$shared = new ReflectionProperty(Database::class, 'sharedConnection');
$shared->setValue(null, $pdo);
$locks = 0;
$allowLock = true;
$pdo->sqliteCreateFunction('GET_LOCK', function ($key, $seconds) use (&$locks, &$allowLock) { expect(strlen($key) <= 64 && $seconds <= 5, 'Unbounded advisory lock'); if (!$allowLock) return 0; ++$locks; return 1; });
$pdo->sqliteCreateFunction('RELEASE_LOCK', function ($key) use (&$locks) { --$locks; return 1; });
$pdo->exec('CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT UNIQUE, email TEXT, password TEXT, page_access INT, premdays INT, type INT, coins INT, recruiter INT, creation INT)');
$sample = ['vocation'=>9, 'level'=>8, 'health'=>185, 'healthmax'=>185, 'experience'=>4200, 'lookbody'=>113, 'lookfeet'=>115,
    'lookhead'=>95, 'looklegs'=>39, 'looktype'=>129, 'lookaddons'=>0, 'maglevel'=>0, 'mana'=>90, 'manamax'=>90, 'manaspent'=>0,
    'soul'=>0, 'town_id'=>8, 'posx'=>32369, 'posy'=>32241, 'posz'=>7, 'cap'=>470, 'balance'=>0];
$columns = implode(', ', array_map(fn ($name) => "$name INT", array_keys($sample)));
$pdo->exec("CREATE TABLE canary_samples ($columns)");
(new Database('canary_samples'))->insert($sample);
$pdo->exec("CREATE TABLE players (id INTEGER PRIMARY KEY, name TEXT UNIQUE, account_id INT, group_id INT, main INT, world INT, sex INT, istutorial INT, conditions TEXT NOT NULL, $columns)");
$account = ['name'=>'TestAccount', 'email'=>'TEST@example.invalid', 'password'=>'fixturehash', 'type'=>6, 'coins'=>999];
$character = ['name'=>'Test Player', 'vocation'=>9, 'sex'=>0, 'group_id'=>6, 'world'=>99, 'level'=>999, 'account_id'=>999];
$pdo->exec("CREATE TRIGGER fail_player BEFORE INSERT ON players BEGIN SELECT RAISE(ABORT, 'forced second insert failure'); END");
try { CreateAccount::createAccountWithCharacter($account, $character); throw new RuntimeException('Failure not propagated'); }
catch (PDOException $expected) {}
expect((int)$pdo->query('SELECT COUNT(*) FROM accounts')->fetchColumn() === 0 && $locks === 0, 'Second insert left an orphan or lock');
$pdo->exec('DROP TRIGGER fail_player');
$id = CreateAccount::createAccountWithCharacter($account, $character);
$saved = $pdo->query('SELECT * FROM accounts')->fetch(PDO::FETCH_ASSOC);
$player = $pdo->query('SELECT * FROM players')->fetch(PDO::FETCH_ASSOC);
expect($id > 0 && $player['account_id'] === $id && $saved['creation'] > time()-10 && $saved['creation'] <= time(), 'Account ID/timestamp wrong');
expect($saved['type'] === 1 && $saved['page_access'] === 0 && $saved['coins'] === 0 && $saved['email'] === 'test@example.invalid', 'Privilege/email fields not fixed');
expect($player['world'] === 1 && $player['group_id'] === 1 && $player['level'] === 8 && $player['istutorial'] === 0 && $player['conditions'] === '' && $locks === 0, 'Player sample/fixed fields not respected');
try { CreateAccount::createAccountWithCharacter(array_replace($account, ['name'=>'OtherAccount']), array_replace($character, ['name'=>'Other Player'])); throw new RuntimeException('Duplicate email accepted'); }
catch (DomainException $expected) {}
expect((int)$pdo->query('SELECT COUNT(*) FROM accounts')->fetchColumn() === 1 && $locks === 0, 'Duplicate email mutated rows or retained lock');
$allowLock = false;
try { CreateAccount::createAccountWithCharacter(array_replace($account, ['email'=>'other@example.invalid']), $character); throw new RuntimeException('Busy lock accepted'); }
catch (RuntimeException $expected) { expect($expected->getMessage() !== 'Busy lock accepted', 'Busy lock accepted'); }
$allowLock = true;
$pdo->exec('DELETE FROM canary_samples');
try { CreateAccount::createAccountWithCharacter(array_replace($account, ['email'=>'other@example.invalid']), $character); throw new RuntimeException('Missing sample accepted'); }
catch (UnexpectedValueException $expected) {}
expect((int)$pdo->query('SELECT COUNT(*) FROM accounts')->fetchColumn() === 1 && $locks === 0, 'Missing sample wrote rows');
try { Database::transaction(function () { (new Database('accounts'))->insert(['name'=>'ThrowableAccount']); throw new Error('forced Throwable'); }); }
catch (Error $expected) {}
expect((int)$pdo->query('SELECT COUNT(*) FROM accounts')->fetchColumn() === 1 && !$pdo->inTransaction(), 'Throwable did not rollback');
echo "PASS AccountTransactionTest (real SQLite rollback, fields/sample, duplicate email, bounded lock, Throwable)\n";
