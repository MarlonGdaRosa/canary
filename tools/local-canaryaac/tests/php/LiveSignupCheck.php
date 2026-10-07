<?php
// Explicit opt-in integration check. Admin credential arrives only over stdin and is used only for exact cleanup.
$runtime = getenv('CANARYAAC_TEST_ROOT') ?: 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
require $runtime . '/vendor/autoload.php';
Dotenv\Dotenv::createImmutable($runtime)->load();
$admin = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
$dsn = 'mysql:host='.$_ENV['DB_HOST'].';port='.$_ENV['DB_PORT'].';dbname='.$_ENV['DB_NAME'].';charset=utf8mb4';
$pdo = new PDO($dsn, $_ENV['DB_USER'], $_ENV['DB_PASS'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES=>false]);
$tag = bin2hex(random_bytes(8));
$name = 'Task2'.$tag;
$email = strtolower($name).'@example.invalid';
$playerName = 'Task '.strtr($tag, '0123456789abcdef', 'abcdefghijklmnop');
$password = 'Task2<&'.bin2hex(random_bytes(16));
$start = time();
$stage = 'precheck';
$curl = curl_init();
curl_setopt_array($curl, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_COOKIEFILE=>'', CURLOPT_FOLLOWLOCATION=>false, CURLOPT_TIMEOUT=>15]);
function request($curl, string $url, ?array $form = null, bool $json = false): array {
    curl_setopt($curl, CURLOPT_URL, $url);
    curl_setopt($curl, CURLOPT_POST, $form !== null);
    curl_setopt($curl, CURLOPT_HTTPHEADER, $json ? ['Content-Type: application/json'] : ['Content-Type: application/x-www-form-urlencoded']);
    if ($form !== null) curl_setopt($curl, CURLOPT_POSTFIELDS, $json ? json_encode($form, JSON_THROW_ON_ERROR) : http_build_query($form));
    $body = curl_exec($curl);
    if ($body === false) throw new RuntimeException('HTTP transport failed');
    return [(int)curl_getinfo($curl, CURLINFO_RESPONSE_CODE), $body];
}
function check(bool $condition): void { if (!$condition) throw new RuntimeException('Integration assertion failed'); }
function token(string $body): string {
    preg_match('/name="csrf_token" value="([a-f0-9]{64})"/', $body, $match);
    if (!isset($match[1])) throw new RuntimeException('CSRF token missing');
    return $match[1];
}
$id = null; $playerId = null; $passed = false;
try {
    $q=$pdo->prepare('SELECT COUNT(*) FROM accounts WHERE name = ? OR email = ?'); $q->execute([$name,$email]); check((int)$q->fetchColumn()===0);
    [$code,$body] = request($curl, 'http://127.0.0.1:8080/createaccount'); check($code===200);
    $stage='browser signup';
    [$code,$body] = request($curl, 'http://127.0.0.1:8080/createaccount', ['accname'=>$name,'email'=>$email,'password1'=>$password,'password2'=>$password,
        'name'=>$playerName,'sex'=>'2','vocation'=>'9','world'=>'1','agreeagreements'=>'true','csrf_token'=>token($body)]);
    $q=$pdo->prepare('SELECT id, password, type, page_access, creation FROM accounts WHERE name = ? AND email = ?'); $q->execute([$name,$email]); $account=$q->fetch(PDO::FETCH_ASSOC);
    if ($account) $id=(int)$account['id'];
    check($code===200 && str_contains($body, 'Your account has been successfully created.') && $id!==null);
    check(!str_contains($body,$password) && !str_contains($body,$account['password']) && strlen($account['password'])===67
        && App\Utils\Argon::checkPassword($password,$account['password']) && (int)$account['type']===1 && (int)$account['page_access']===0 && (int)$account['creation'] >= $start);
    $q=$pdo->prepare('SELECT id, vocation, sex, group_id, world, conditions, istutorial FROM players WHERE account_id = ? AND name = ?'); $q->execute([$id,$playerName]); $player=$q->fetch(PDO::FETCH_ASSOC);
    check($player!==false); $playerId=(int)$player['id'];
    check((int)$player['vocation']===9 && (int)$player['sex']===0 && (int)$player['group_id']===1 && (int)$player['world']===1 && $player['conditions']==='' && (int)$player['istutorial']===0);
    $stage='game login';
    [$code,$body]=request($curl,'http://127.0.0.1:8088/login',['type'=>'login','email'=>$email,'password'=>$password],true);
    $login=json_decode($body,true,512,JSON_THROW_ON_ERROR);
    check($code===200 && !isset($login['errorCode']) && !empty($login['session']['sessionkey']) && ($login['playdata']['characters'][0]['name'] ?? '')===$playerName);
    $stage='browser login';
    [$code,$body]=request($curl,'http://127.0.0.1:8080/account/login'); check($code===200);
    [$code,$body]=request($curl,'http://127.0.0.1:8080/account/login',['loginemail'=>$email,'loginpassword'=>$password,'csrf_token'=>token($body)]); check($code===302);
    $stage='account page';
    [$code,$body]=request($curl,'http://127.0.0.1:8080/account'); check($code===200 && str_contains($body,$playerName));
    $stage='logout';
    [$code,$body]=request($curl,'http://127.0.0.1:8080/account/logout',['csrf_token'=>token($body)]); check($code===200);
    $passed=true;
} catch (Throwable $error) { echo 'FAIL LiveSignupCheck stage='.$stage.' type='.get_class($error)."\n"; }
finally {
    curl_close($curl);
    try {
        $cleanup = new PDO($dsn,$admin['user'],$admin['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_EMULATE_PREPARES=>false]);
        unset($admin);
        $cleanup->beginTransaction();
        $q=$cleanup->prepare('SELECT id, creation FROM accounts WHERE name = ? AND email = ? FOR UPDATE'); $q->execute([$name,$email]); $owned=$q->fetch(PDO::FETCH_ASSOC);
        if ($owned) {
            check((int)$owned['creation'] >= $start && (int)$owned['creation'] <= time() && ($id===null || (int)$owned['id']===$id));
            $id=(int)$owned['id'];
            $q=$cleanup->prepare('SELECT id, name FROM players WHERE account_id = ? FOR UPDATE'); $q->execute([$id]); $ownedPlayers=$q->fetchAll(PDO::FETCH_ASSOC);
            check(count($ownedPlayers)===1 && $ownedPlayers[0]['name']===$playerName && ($playerId===null || (int)$ownedPlayers[0]['id']===$playerId));
            $playerId=(int)$ownedPlayers[0]['id'];
            $q=$cleanup->prepare('DELETE FROM players WHERE id = ? AND account_id = ? AND name = ?'); $q->execute([$playerId,$id,$playerName]); check($q->rowCount()===1);
            $q=$cleanup->prepare('DELETE FROM account_sessions WHERE account_id = ?'); $q->execute([$id]);
            $q=$cleanup->prepare('DELETE FROM accounts WHERE id = ? AND name = ? AND email = ? AND creation = ?'); $q->execute([$id,$name,$email,$owned['creation']]); check($q->rowCount()===1);
        }
        $cleanup->commit();
        $q=$pdo->prepare('SELECT COUNT(*) FROM accounts WHERE name = ? OR email = ?'); $q->execute([$name,$email]); check((int)$q->fetchColumn()===0);
        echo 'Exact cleanup confirmed accountId='.($id ?? 'none').' playerId='.($playerId ?? 'none')." remaining=0\n";
    } catch (Throwable $error) { if (isset($cleanup) && $cleanup->inTransaction()) $cleanup->rollBack(); echo 'CLEANUP FAILED exact identity='.$name.' accountId='.($id ?? 'unknown')."\n"; exit(2); }
}
if (!$passed) exit(1);
echo "PASS LiveSignupCheck (real browser form, compact Argon, game HTTP/gRPC, browser session, account page, logout)\n";
