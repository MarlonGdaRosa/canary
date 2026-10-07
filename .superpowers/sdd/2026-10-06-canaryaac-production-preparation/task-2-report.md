# Task 2 — atomic signup and compatible authentication

Status: DONE_WITH_CONCERNS (one pre-existing Windows symlink-test capability skip; scanner's unused OpenPGP module notice, detailed below). Work completed 2026-10-06/07. Review base: `c572d0418`; intervening controller documentation commit `f2d32f70d` was preserved. No Task 3 implementation.

## Implemented

- Shared strict `AccountCreationValidator::validate(array): array`: account ASCII alphanumeric 3–32; character ASCII letters and single internal spaces 5–29; email syntax/254-byte limit and lowercase normalization; exact `true` rules string; allowed vocations 1/2/3/4/9; sex 2 maps to 0; fixed world 1. Raw UTF-8 passwords 12–128 code points, no NUL, matching confirmation, remain unchanged. Non-string fields, invalid encoding, oversized input, malformed world/vocation are rejected before hash/database work.
- Existing security boot now rejects ambiguous/duplicate raw URL-encoded fields before PHP's overwritten/normalized POST values reach validation. The existing CSRF/rate/body gates still precede expensive work. HTTP tests cover ordinary and percent-encoded duplicate keys, bracket syntax, duplicate password/world/CSRF, and dotted names. Unsupported content types fail with 400.
- Compact Argon2id generation: fixed m=65536 KiB, t=2, p=2, 16-byte salt and 32-byte digest; numeric configuration validation has no eval. SHA-1 remains readable using constant-time comparison. Authentication never changes, migrates, or downgrades stored hashes. Explicit password-change helper now generates Argon.
- One shared PDO connection, utf8mb4, native prepares and exception mode; no `die(PDO message)` paths. `Database::transaction` commits successful operations and rolls back every Throwable. `CreateAccount::createAccountWithCharacter` validates a permitted server sample before writes and commits account plus first character atomically. Unix creation timestamp and fixed ordinary account/player privileges, world 1, empty conditions, tutorial 0. Input privilege/stat fields cannot override these values.
- Duplicate email race: bounded MySQL/MariaDB `GET_LOCK` for 5 seconds on a <=64-byte key derived from normalized email, acquired on the same shared connection, rechecked inside the transaction and retained through commit/rollback, then released in `finally`. Account/character names also rechecked using parameters; existing unique constraints remain the final guard. No unique-index migration or core-row rewrite. This serializes the reviewed signup path; other future writers must follow the same contract (documented in nearest AGENTS).
- Controller uses validation/atomic entity and generic errors. Confirmation receives no password/hash. Form lengths, all five vocations and numeric world JS agree with backend; old password-bearing name-availability AJAX was removed. Twig normal escaping retained. Only a generated stale signup-template cache file was removed and regenerated; no source or user data was removed by that cache cleanup.
- Browser authentication bounds scalar input. Configured 2FA remains enforced through retained Google2FA: missing optional table (specific MySQL 42S02/1146) or absent record is legitimate absence; other DB failures propagate; invalid status, duplicate/ambiguous records, malformed/missing OTP deny login. The live optional table exists. Its upstream schema has no unique account_id constraint, so a focused RED/GREEN duplicate-record test was added. No authentication tables were migrated or populated.
- Removed disabled payment/SMTP/Discord packages; retained and updated Google2FA to 8.0.3 because browser verification needs it. Updated compatible retained Composer graph with pinned Composer 2.10.3; scripts/plugins disabled. `0004` touches only composer.json/lock.
- Login-server auth now selects stored password by parameterized email/name with LIMIT 1, verifies format in code, and returns sql.ErrNoRows for wrong/malformed credentials. SHA-1 and Argon comparisons are constant-time. Hash length/canonical base64/salt/digest and password UTF-8/length/NUL are bounded before Argon allocation. Wire protocol remains unchanged. Go tests contain only an explicitly synthetic PHP-generated hash fixture.
- Focused gRPC upgrade to maintained fixed 1.83.2 and x/crypto 0.57.0. Required module graph changes, including go directive 1.26.0, were resolved/tidied. No unrelated source rewrite or blanket upgrade. Build uses installed Go 1.27.0 windows/amd64.
- Reproducible `login-server/Build-CompatibleLoginServer.ps1` applies the scoped patch to exact base 2612930de4d97123a397f8f2cd0d5f784094af40 (or recognizes already applied), preserves conflicts, confines Go caches/temp under .tools, verifies module checksums, runs focused tests, stages a unique executable, installs pinned govulncheck 1.8.0, runs source/test/binary text-mode scans and emits a manifest. It does not deploy or stop services.

## TDD evidence

Commands below ran from `C:/Users/Marlon/Documents/OT/.worktrees/canaryaac-local-integration` unless stated otherwise. PHP invocation prefix: `& .tools/php/php.exe -c .tools/php/php.ini`.

| Test command suffix | RED observed before implementation | GREEN observed |
| --- | --- | --- |
| `tools/local-canaryaac/tests/php/AccountCreationValidatorTest.php` | `RuntimeException: Shared signup validator missing` | `PASS AccountCreationValidatorTest (five vocations, strict fields, raw UTF8 password, HTTP duplicates)` |
| `tools/local-canaryaac/tests/php/ArgonCompatibilityTest.php` | `RuntimeException: New password is not compact Argon2id` | `PASS ArgonCompatibilityTest (compact Argon2id, legacy SHA1, costs bounded, no auth writes)` |
| `tools/local-canaryaac/tests/php/AccountTransactionTest.php` | `RuntimeException: Atomic signup API missing` | `PASS AccountTransactionTest (real SQLite rollback, fields/sample, duplicate email, bounded lock, Throwable)` |
| `tools/local-canaryaac/tests/php/AccountAuthenticationTest.php` | `RuntimeException: Fail-closed optional 2FA boundary missing`; additional regression `Ambiguous duplicate 2FA records bypassed active factor` | `PASS AccountAuthenticationTest (absent table, active OTP, unknown status/storage fail closed)` |
| `tools/local-canaryaac/tests/php/SignupFormTest.php` | `RuntimeException: Wrong form length for accname` | `PASS SignupFormTest (lengths, vocations, escaping, no password AJAX or confirmation)` |
| `node tools/local-canaryaac/tests/SignupForm.Tests.js` | `AssertionError: Valid raw password rejected` (`undefined !== ''`) | `PASS SignupForm.Tests.js (raw passwords, UTF8 lengths, account rules, numeric world)` |

Transaction tests use real in-memory SQLite with a trigger forcing the second insert to fail; the test subprocess enables the bundled pdo_sqlite extension. Reflection supplies the test connection without adding test-only production APIs. SQLite functions stand in for advisory-lock acquisition/release, checking its bounded key/timeout and cleanup. The lock's real server semantics are used by the live signup. No disposable database schema was provisioned in the live DB.

Go RED, from `.tools/login-server`, with GOPATH/GOCACHE/GOMODCACHE/GOTMPDIR/TEMP/TMP under `.tools/go` and GOTOOLCHAIN=local:

```text
go test ./src/database -run '^TestCompatibleAccountAuthentication$' -count=1
--- FAIL: TestCompatibleAccountAuthentication
valid authentication failed: Query: could not match actual sql:
SELECT id, type, premdays, lastday FROM accounts WHERE (email = ? OR name = ?) AND password = ?
with expected SELECT id, type, premdays, lastday, password FROM accounts WHERE email = ? OR name = ? LIMIT 1
FAIL
```

Go GREEN including PHP compact hash, wrong password, legacy correct/incorrect/case, malformed/base64/oversized hashes, unbounded PHC, NUL/invalid UTF-8/oversized passwords and parameterized hostile identity:

```text
go test -mod=readonly ./src/database ./src/api ./src/grpc -run '^(TestCompatibleAccountAuthentication|Test_loginHandlerReturnsSessionFlowVariants|TestLogin|TestBuildLogin|TestBuildConfiguration)' -count=1
ok github.com/opentibiabr/login-server/src/database 0.184s
ok github.com/opentibiabr/login-server/src/api 0.103s
ok github.com/opentibiabr/login-server/src/grpc 0.097s
go mod verify
all modules verified
go build -mod=readonly -trimpath -buildvcs=false -o <unique stage>/login-server.exe ./src
exit 0
```

## Full final verification

The required full PHP suite ran once after implementation, 2026-10-07; no PHP implementation changed afterward:

```powershell
Get-ChildItem tools/local-canaryaac/tests/php/*Test.php | ForEach-Object {
  & .tools/php/php.exe -c .tools/php/php.ini $_.FullName
  if($LASTEXITCODE){throw 'PHP test failed'}
}
```

Output: PASS AccountAuthenticationTest, AccountCreationValidatorTest, AccountTransactionTest, ArgonCompatibilityTest, RouterSecurityTest, SignupFormTest and WebSecurityTest (7/7). Existing RouterSecurityTest emitted `SKIP symlink escape: Windows identity cannot create symlinks`; other 20 denied-path/asset checks passed. JS test also passed. All eight changed runtime PHP files passed `php -l`. The Task 1 CSRF-array assertion now explicitly expects 400 for invalid form syntax; missing/incorrect scalar CSRF still expects 403.

Clean upstream replay: exported only app/includes/index/resources/routes/composer files from website d9333dcf33d3f55cee476e9ee8ebfe3f28113c19, applied 0001–0004 in order using `git apply --check` then `git apply`. All 13 Task 2 changed files match runtime after CRLF/LF normalization. Exact-byte comparison first reported a line-ending mismatch; `git diff --ignore-space-at-eol` and normalized full-content comparison confirmed no source difference. Login base exported only src/go.mod/go.sum; its patch applied cleanly and all five changed files match runtime after line-ending normalization. No .env file was archived, diffed or hashed.

Patch SHA256:

- 0003 atomic signup: `1FF096E6CBA52DF1B1AC36791C70E5CA5CDEC46ADE831711ACD375CCA76E7A9E`
- 0004 Composer dependencies: `B5FAE02C136EFDCC29AC43DF7A70D6B589DF89AF50FFDB5929FC4D94A11A16C0`
- Login patch: `75CD4123A6FBFE070B4ED4C96EF7FD852152B3A1D7F1CD120C8F896F00DE5CC0`

## Dependency audits and build evidence

Composer 2.10.3 phar SHA256 `7A2D379D5B8FFDAA028580EF26494C36D2FEEF4B178D3DD1473A4DBC5E17C8D6`; PHP 8.3.35. COMPOSER_HOME/cache/TEMP/TMP confined to `.tools/composer`. Commands used `--no-plugins`; updates/install also `--no-scripts --no-dev --no-interaction --prefer-dist`. Initial restricted-network attempt failed curl 7; authorized owner/network retry resolved packages. Installation initially needed bundled zip enabled via `-d extension=zip`, then completed. No failed command was treated as a clean audit.

2026-10-06 final Composer commands/results, both exit 0:

```text
composer validate --strict --no-plugins
./composer.json is valid
composer audit --locked --no-dev --abandoned=report --no-plugins
No security vulnerability advisories found.
```

Lock SHA256 `AAA2641B6A46D358F0C6A24890D47F53FD2C5EB7412521D5D1C08B65903BDF80`; JSON SHA256 `579439A798724927C5FC396B3AFB4E2E736D9E85A4F7F5A70103D359864FCC42`. These files were unchanged after that audit. Final install confirmed `Nothing to install, update or remove`. Resolution: 2 installs, 20 compatible updates, 46 removals. Google2FA 8.0.3 is intentionally retained for configured verification, despite disabled management routes.

Go initial candidate gRPC 1.84.0 passed compatibility tests but official govulncheck reported GO-2026-6443 with a transport HandleStreams call trace. Its exploit description is xDS-conditional; this application does not configure xDS, but the release was not accepted as scanner-clean. Official fixed ranges include 1.83.2, so the final build uses that maintained fixed branch. Sources: https://pkg.go.dev/vuln/GO-2026-6443 and https://pkg.go.dev/vuln/GO-2026-6348. x/crypto 0.57.0 and scanner 1.8.0 were verified against official package/module metadata.

Final helper execution produced:

```text
source govulncheck exit=0
tests govulncheck exit=0
binary govulncheck exit=0
Build manifest: C:\Users\Marlon\Documents\OT\.tools\login-server-builds\3c1ca4622f5e44a1865c4d9c08a9b080\build-manifest.json
```

Manifest timestamp: 2026-10-07T03:18:45.1269568Z. It binds exact base revision, patch SHA, 56 source/module/proto file hashes, Go version/profile/flags, executable SHA, pinned scanner binary SHA and each audit output SHA/exit. Evidence snapshots alongside this report: `task-2-build-manifest.json`, `task-2-source-govulncheck.txt`, `task-2-tests-govulncheck.txt`, `task-2-binary-govulncheck.txt`. Normal text scans report zero affected symbols/packages. One module-only notice remains: GO-2026-5932 for unmaintained `golang.org/x/crypto/openpgp`; this application imports Argon2, not OpenPGP. This is documented, not suppressed. Scanner results are point-in-time reachability evidence, not a guarantee against all vulnerabilities.

## Runtime deployment, live validation and cleanup

Sequencing concern caught during implementation: the live Argon writer was edited before compatible login deployment. A temporary 503 gate was promptly placed at signup entry, read-only count showed **0 accounts created since the Argon edit (60-second margin)**, and no account hashes were rewritten. Runtime numeric Argon configuration was already supported. Gate removed immediately after tested login deployment; absent in final source/patch.

Old pidfile contained 30188, but actual loopback listener owner was 33184. Deployment ignored stale pidfile, verified exact executable path, no additional command arguments, process creation timestamp and exactly 127.0.0.1:8088/9090 listeners, then rechecked identity immediately before stopping only PID 33184. Preserved old executable at `.tools/login-server/login-server.pre-task2-20261006-191800.exe`. Started replacement hidden with identical working directory/configuration. New PID 46924, creation UTC **2026-10-06T22:18:00.9737780Z**, same two loopback binds. Refreshed login-server.pid to 46924. No Canary or website process stopped, no bind changed. Current read-only checks: Canary PID 35804 at 127.0.0.1:7172; website PID 29232 at 127.0.0.1:8080.

Active binary SHA256 and independent fresh helper rebuild both equal:
`DE8F32FB3BD934BFEFA1F3C7F41C7A0EEBCF7054B816D042ACF7AE7EE39F06AF`.

Explicit live integration command (admin credential only used for exact test cleanup):

```powershell
$task2Credential = Import-Clixml -LiteralPath C:/Users/Marlon/Documents/OT/.tools/canaryaac-admin.credential.xml
& tools/local-canaryaac/tests/Invoke-LiveSignupCheck.ps1 -CleanupCredential $task2Credential
```

Output, exit 0:

```text
Exact cleanup confirmed accountId=4 playerId=11 remaining=0
PASS LiveSignupCheck (real browser form, compact Argon, game HTTP/gRPC, browser session, account page, logout)
```

The check generated a unique random exact account/email/character identity, used the real website form/CSRF session, created a female Monk, asserted fixed privileges/world/tutorial/conditions, verified the compact hash without printing it, authenticated through real 8088 `/login` HTTP→gRPC and checked the returned character/session, then performed browser login (302), authenticated account page (200) and logout (200). Cleanup used a transaction, exact account name/email/id/creation-time and exact player id/name/account ownership checks, removed that disposable player's row/session rows/account, and verified remaining=0. No test identity was reused. No provisioner, migrations, broad deletion, ordinary account mutation, ACL weakening, credential/request-body/hash logging or bulk rate-limit exercise occurred. Session cookie was invalidated by the real logout.

## Files and self-review

Owned deliverables: ordered 0003/0004 website patches; login-server 0001 patch and build helper; six new PHP checks (five suite tests plus explicit LiveSignupCheck); invalid-submissions fixture; JS behavior test; opt-in live-check PowerShell wrapper; scoped WebSecurityTest assertion update; nearest AGENTS prevention rule and patch EOL attributes. Runtime source/vendor changes are represented by patches/locks; executables, credentials, .env, temporary exports and vendor trees are not committed.

Self-review corrected numeric world values in generated JS, selected the canonical world-list representation for signup, removed disabled password-bearing AJAX, treated duplicate 2FA records as ambiguous, and isolated the Twig stale-cache issue. The build helper recognizes an already applied patch and records source/binary scans without service actions. Clean apply paths were verified independently through scoped upstream exports. Existing symlink-capability skip and unused OpenPGP module notice are the remaining verification qualifications. No unresolved failed audit or incompatible live login remains.

All user gameplay/NPC/item/quest changes were left unmodified and unstaged. Private environment/admin/backups ACLs were preserved. The deployment gate is gone; no further service restart or live test was performed during final evidence capture.

## Review fix round 1 — 2026-10-07

All three review findings addressed without service restarts or live database work:

1. Build helper now saves/restores inherited `GOBIN`, sets it to the controlled `.tools/go/bin`, installs and executes that exact scanner path, and runs `go version -m` against the installed executable before any scan. It requires the govulncheck command path and `golang.org/x/vuln v1.8.0` main module, rejects replaced module metadata, and records observed version/checksum/build information plus `IdentityVerified=true` in the manifest. Version is no longer just a hardcoded claim.
2. Both password inputs allow 256 native UTF-16 code units, accommodating 128 supplementary Unicode code points. Existing JavaScript and server validation still enforce 12–128 code points. Added 12/128/129 rocket-character cases to JS and PHP boundary tests, plus checks that both rendered native input caps can hold the valid maximum. Refreshed 0003 and invalidated only the compiled signup-template cache.
3. SQLite test subprocess carries `--sqlite-retry`; if the driver is still unavailable, it exits 1 with a clear diagnostic instead of spawning again. The failure-path test disables passthru to make a regression fail immediately without creating an unbounded process chain.

RED commands/output before fixes:

```text
& tools/local-canaryaac/tests/LoginBuildScanner.Tests.ps1
Inherited alternate GOBIN received an install
php .../SignupFormTest.php
Wrong form length for password1
node tools/local-canaryaac/tests/SignupForm.Tests.js
Native maxlength truncates a valid 128-code-point password
php .../SqliteRetryTest.php
Unavailable SQLite did not fail clearly after one retry
```

GREEN focused checks:

```text
PASS LoginBuildScanner.Tests (alternate GOBIN confined/restored; stale scanner replaced/rejected before scans)
PASS SignupFormTest (lengths, vocations, escaping, no password AJAX or confirmation)
PASS SignupForm.Tests.js (raw passwords, UTF8 lengths, account rules, numeric world)
PASS SqliteRetryTest (unavailable extension stops after one retry)
PASS AccountTransactionTest (real SQLite rollback, fields/sample, duplicate email, bounded lock, Throwable)
PASS AccountCreationValidatorTest (five vocations, strict fields, raw UTF8 password, HTTP duplicates)
```

The scanner fixture executes the real helper with isolated fake Go/install/build boundaries and a compiled harmless scanner stub. It starts with an inherited alternate GOBIN and an old scanner in GOPATH/bin, verifies the alternate directory remains untouched and the stale binary is replaced, then simulates a successful install that still yields v1.7.0 and verifies rejection before any additional scans. GOBIN restoration is checked on success and failure. It does not write to the live source, scan real credentials, or deploy executables.

Real helper rerun (default pinned Go), exit 0:

```text
all modules verified
ok github.com/opentibiabr/login-server/src/database 0.192s
ok github.com/opentibiabr/login-server/src/api 0.097s
ok github.com/opentibiabr/login-server/src/grpc 0.091s
source govulncheck exit=0
tests govulncheck exit=0
binary govulncheck exit=0
Build manifest: C:\Users\Marlon\Documents\OT\.tools\login-server-builds\ca208b7eee41428297795128ebb069a3\build-manifest.json
```

Current evidence snapshot supersedes the earlier build manifest: created 2026-10-07T03:28:36.0181919Z, verified embedded scanner v1.8.0; executable hash unchanged (`DE8F32FB3BD934BFEFA1F3C7F41C7A0EEBCF7054B816D042ACF7AE7EE39F06AF`). Source/test/binary audit output snapshots refreshed; their findings remain zero affected symbols and the previously documented unused OpenPGP module notice. Current 0003 SHA256: `1995B688C41F98DDE52931AD2B0DB743734B9C581AA44027702DBD148EBED890`.

Finally reran the full required `Get-ChildItem tools/local-canaryaac/tests/php/*Test.php` loop using bundled PHP/config: **8/8 PASS**, including new SqliteRetryTest, with only the existing Windows symlink capability SKIP. No PHP implementation changed after this final suite. No ordinary account, service, gameplay/quest file, private ACL or existing Go source was changed in this fix round.
