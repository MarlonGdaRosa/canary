<?php
require __DIR__ . '/HttpFixture.php';
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
use App\Utils\AccountAuthentication;
use App\DatabaseManager\Database;
expect(class_exists(AccountAuthentication::class), 'Fail-closed optional 2FA boundary missing');
class AuthenticationPDO extends PDO {
    public $record = false;
    public ?PDOException $failure = null;
    public function __construct() {}
    public function prepare(string $query, array $options = []): PDOStatement|false { return new AuthenticationStatement($this); }
}
class AuthenticationStatement extends PDOStatement {
    public function __construct(private AuthenticationPDO $pdo) {}
    public function execute(?array $params = null): bool { if ($this->pdo->failure) throw $this->pdo->failure; return true; }
    public function fetchObject(?string $class = 'stdClass', array $constructorArgs = []): object|false { return is_array($this->pdo->record) ? $this->pdo->record[0] : $this->pdo->record; }
    public function fetchAll(int $mode = PDO::FETCH_DEFAULT, mixed ...$args): array { return is_array($this->pdo->record) ? $this->pdo->record : ($this->pdo->record === false ? [] : [$this->pdo->record]); }
}
$pdo = new AuthenticationPDO();
(new ReflectionProperty(Database::class, 'sharedConnection'))->setValue(null, $pdo);
expect(AccountAuthentication::verify(1, ''), 'Absent optional record rejected');
$pdo->failure = new PDOException(); $pdo->failure->errorInfo = ['42S02', 1146, 'test missing table'];
expect(AccountAuthentication::verify(1, ''), 'Legitimate absent optional table rejected');
$pdo->failure->errorInfo = ['HY000', 2006, 'test storage error'];
try { AccountAuthentication::verify(1, ''); throw new RuntimeException('Storage failure bypassed 2FA'); } catch (PDOException $expected) {}
$pdo->failure = null;
$pdo->record = (object)['status'=>null];
expect(!AccountAuthentication::verify(1, ''), 'Unknown status bypassed 2FA');
$secret = 'JBSWY3DPEHPK3PXP';
$pdo->record = (object)['status'=>1, 'secret'=>$secret];
expect(!AccountAuthentication::verify(1, '') && !AccountAuthentication::verify(1, ['123456']), 'Active 2FA accepts missing/array token');
$google = new PragmaRX\Google2FA\Google2FA();
expect(AccountAuthentication::verify(1, $google->getCurrentOtp($secret)), 'Valid active 2FA rejected');
expect(!AccountAuthentication::verify(1, 'bad'), 'Malformed token accepted');
$pdo->record = [(object)['status'=>0], (object)['status'=>1, 'secret'=>$secret]];
expect(!AccountAuthentication::verify(1, ''), 'Ambiguous duplicate 2FA records bypassed active factor');
echo "PASS AccountAuthenticationTest (absent table, active OTP, unknown status/storage fail closed)\n";
