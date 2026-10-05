# CanaryAAC Local Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a reproducible localhost-only CanaryAAC stack that creates a normal account and one level 8 character in Thais for any of the five supported vocations, then authenticates that account through the existing login-server.

**Architecture:** Versioned PowerShell, SQL, tests, configuration templates, and downstream patches live under `tools/local-canaryaac/`; downloaded runtimes, the patched checkout, secrets, backups, logs, and PID files remain under ignored `.tools/`. The site uses a least-privilege MariaDB user, an adapted idempotent migration, and one shared PDO transaction for account plus character creation; the existing login-server remains the only game-client login endpoint.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, PHP 8.3.35 NTS x64, Composer 2.10.3, CanaryAAC at `d9333dcf33d3f55cee476e9ee8ebfe3f28113c19`, MariaDB 11.8.5, Twig, PDO MySQL, PHP built-in web server.

**Spec:** `docs/superpowers/specs/2026-10-05-canaryaac-local-integration-design.md`

## Global Constraints

- Work only on branch `codex/canary-localhost-setup`; preserve all unrelated modified and untracked files.
- Bind the AAC only to `127.0.0.1:8080`; keep game login at `http://127.0.0.1:8088/login` and Canary at `127.0.0.1:7172`.
- Pin PHP to `8.3.35` NTS x64, Composer to `2.10.3`, and CanaryAAC to commit `d9333dcf33d3f55cee476e9ee8ebfe3f28113c19`.
- Verify every downloaded artifact before extraction or execution; never fall back to an unpinned latest release.
- Never import upstream `canaryaac.sql` into `canary`; never drop `accounts_unique`, change `accounts.creation`, seed an administrator, or replace existing account/player data.
- Preserve legacy SHA-1 authentication for existing accounts and use compact Argon2id with memory `65536` KiB, time `2`, and parallelism `2` for new accounts.
- Keep binaries, checkouts, `.env`, secrets, dumps, logs, runtime evidence, and PID files below ignored `.tools/`; commit only automation, tests, templates, SQL, documentation, and downstream patches.
- The web database principal is `canaryaac_local@127.0.0.1` and receives `SELECT` on `canary.*` plus `INSERT` on `canary.accounts` and `canary.players`; it receives no DDL, `DELETE`, or broad mutation privilege.
- Account names are 3-32 ASCII alphanumeric characters; character names are 5-29 ASCII letters separated by single spaces; passwords are 12-128 characters; allowed vocations are exactly `1,2,3,4,9`.
- Created accounts have `type=1`; created characters have `group_id=1`, `main=1`, `world=1`, `level=8`, `experience=4200`, `town_id=8`, and position `32369,32241,7`.
- Payments, donations, SMTP, recovery, remote administration, public networking, and gameplay changes remain disabled and out of scope.
- Do not run a Canary C++ build for this integration; if a later change requires one, first follow `docs/building/local-validation.md`.

---

## File Structure

```text
tools/local-canaryaac/
|-- CanaryAAC.Local.psm1                  # Shared path, checksum, process, and readiness helpers
|-- runtime.lock.json                     # Exact upstream revisions, URLs, and SHA-256 values
|-- Install-CanaryAAC.ps1                 # Portable PHP/Composer/checkout/dependency installer
|-- Initialize-CanaryAACDatabase.ps1      # Backup, restore test, migration, grants, and .env writer
|-- Start-CanaryAAC.ps1                   # Guarded localhost PHP process startup
|-- Stop-CanaryAAC.ps1                    # Identity-checked AAC process shutdown
|-- Test-CanaryAACE2E.ps1                 # Five-vocation HTTP/database/login verification
|-- Remove-CanaryAACTestData.ps1          # Exact-manifest cleanup with FK-cascade verification
|-- README.md                              # Operator instructions and localhost boundary
|-- config/
|   |-- php.ini                           # Required local PHP extensions and safe defaults
|   `-- router.php                        # Static-file pass-through and index.php routing
|-- sql/
|   `-- 001-canaryaac-local.sql           # Canary-preserving idempotent schema and seed migration
|-- patches/
|   |-- 0001-safe-input-and-argon.patch    # Validator and safe compact Argon implementation
|   |-- 0002-atomic-account-character.patch# Shared PDO transaction and entity API
|   `-- 0003-local-account-flow.patch      # Controller, Twig, JS, and dependency-scope changes
`-- tests/
    |-- Tooling.Tests.ps1                  # Manifest, checksum, router, and installer contracts
    |-- Database.Tests.ps1                 # Migration safety/idempotence/privilege contracts
    |-- Lifecycle.Tests.ps1                # PID identity, loopback bind, start-twice, and stop checks
    |-- php/
    |   |-- bootstrap.php                  # Minimal assertion helpers and pinned app autoload
    |   |-- AccountCreationValidatorTest.php
    |   |-- ArgonCompatibilityTest.php
    |   `-- AccountTransactionTest.php
    `-- fixtures/
        `-- invalid-submissions.json       # Exact rejected HTTP cases
```

The three numbered patches are the reproducible source of all changes inside the ignored `.tools/canaryaac` checkout. Each patch must apply cleanly, in lexical order, to the pinned upstream commit.

---

### Task 1: Establish the portable runtime and tooling contracts

**Files:**
- Create: `tools/local-canaryaac/runtime.lock.json`
- Create: `tools/local-canaryaac/config/php.ini`
- Create: `tools/local-canaryaac/config/router.php`
- Create: `tools/local-canaryaac/CanaryAAC.Local.psm1`
- Create: `tools/local-canaryaac/tests/Tooling.Tests.ps1`

**Interfaces:**
- Consumes: repository root and official release metadata.
- Produces: `Get-CanaryAACLayout([string] $RepositoryRoot)`, `Assert-FileSha256([string] $Path, [string] $Expected)`, `Test-CanaryAACProcess([int] $ProcessId, [string] $PhpPath, [string] $RouterPath)`, and `Wait-CanaryAACHttp([uri] $Uri, [int] $TimeoutSeconds)`.

- [ ] **Step 1: Write the failing tooling tests**

Create `Tooling.Tests.ps1` with tests that import the module, require an absolute repository root, and assert the exact lock values:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $here
Import-Module (Join-Path $toolRoot 'CanaryAAC.Local.psm1') -Force

Describe 'CanaryAAC local tooling' {
    It 'maps all generated state below .tools' {
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $layout = Get-CanaryAACLayout -RepositoryRoot $repo
        $layout.RuntimeRoot | Should Be (Join-Path $repo '.tools')
        $layout.Checkout | Should Be (Join-Path $repo '.tools\canaryaac')
        $layout.PidFile | Should Be (Join-Path $repo '.tools\canaryaac.pid')
    }

    It 'pins the approved runtime and source' {
        $lock = Get-Content (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
        $lock.php.version | Should Be '8.3.35'
        $lock.php.sha256 | Should Be '25a8e2ac9ff30f1d768d1447c09a600617fa6e6082729f6e95f008b59c91fe45'
        $lock.composer.version | Should Be '2.10.3'
        $lock.composer.sha256 | Should Be '7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6'
        $lock.canaryaac.commit | Should Be 'd9333dcf33d3f55cee476e9ee8ebfe3f28113c19'
    }

    It 'rejects a checksum mismatch' {
        $sample = Join-Path $TestDrive 'sample.bin'
        Set-Content -LiteralPath $sample -Value 'different' -NoNewline
        { Assert-FileSha256 -Path $sample -Expected ('0' * 64) } | Should Throw
    }
}
```

- [ ] **Step 2: Run the test and confirm the missing module/manifest failure**

Run:

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Tooling.Tests.ps1'
if ($LASTEXITCODE -eq 0) { throw 'The red test unexpectedly passed' }
```

Expected: FAIL because the module and lock manifest do not exist.

- [ ] **Step 3: Add the exact lock manifest and local configuration**

Create `runtime.lock.json` with:

```json
{
  "php": {
    "version": "8.3.35",
    "url": "https://downloads.php.net/~windows/releases/php-8.3.35-nts-Win32-vs16-x64.zip",
    "sha256": "25a8e2ac9ff30f1d768d1447c09a600617fa6e6082729f6e95f008b59c91fe45"
  },
  "composer": {
    "version": "2.10.3",
    "url": "https://getcomposer.org/download/2.10.3/composer.phar",
    "sha256": "7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6"
  },
  "canaryaac": {
    "repository": "https://github.com/opentibiabr/canaryaac.git",
    "commit": "d9333dcf33d3f55cee476e9ee8ebfe3f28113c19"
  }
}
```

Configure `php.ini` with `extension_dir="ext"`, timezone `America/Sao_Paulo`, `display_errors=On`, `log_errors=On`, `expose_php=Off`, `session.cookie_httponly=1`, `session.use_strict_mode=1`, and these extensions:

```ini
extension=curl
extension=dom
extension=fileinfo
extension=gd
extension=mbstring
extension=mysqli
extension=openssl
extension=pdo_mysql
extension=simplexml
extension=sodium
extension=xml
extension=xmlwriter
```

Create `router.php` so only a real file under the checkout bypasses the front controller:

```php
<?php
$root = realpath(__DIR__);
$uriPath = rawurldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?? '/');
$candidate = realpath($root . DIRECTORY_SEPARATOR . ltrim($uriPath, '/'));
if ($candidate !== false && str_starts_with($candidate, $root . DIRECTORY_SEPARATOR) && is_file($candidate)) {
    return false;
}
require $root . DIRECTORY_SEPARATOR . 'index.php';
```

- [ ] **Step 4: Implement the shared PowerShell module**

Use `[System.IO.Path]::GetFullPath()` for layout paths, `Get-FileHash -Algorithm SHA256` for checksum enforcement, `Get-CimInstance Win32_Process` for PID/executable/command-line identity, and a 250 ms bounded loop around `Invoke-WebRequest -UseBasicParsing` for readiness. `Test-CanaryAACProcess` returns true only when all three conditions hold: the PID exists, `ExecutablePath` equals the pinned `.tools\php\php.exe`, and `CommandLine` contains both `-S 127.0.0.1:8080` and the resolved router path.

```powershell
function Assert-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path. Expected $Expected; got $actual"
    }
}
```

Export only the four named functions.

- [ ] **Step 5: Run the tooling tests**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Tooling.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: all tooling tests PASS.

- [ ] **Step 6: Commit the runtime contracts**

```powershell
git add tools/local-canaryaac/runtime.lock.json tools/local-canaryaac/config tools/local-canaryaac/CanaryAAC.Local.psm1 tools/local-canaryaac/tests/Tooling.Tests.ps1
git commit -m "build: define portable CanaryAAC runtime"
```

---

### Task 2: Install PHP, Composer, and the pinned CanaryAAC checkout

**Files:**
- Create: `tools/local-canaryaac/Install-CanaryAAC.ps1`
- Modify: `tools/local-canaryaac/tests/Tooling.Tests.ps1`
- Produce: `.tools/php/`, `.tools/composer/composer.phar`, `.tools/canaryaac/` (ignored)

**Interfaces:**
- Consumes: `runtime.lock.json`, `Assert-FileSha256`, `config/php.ini`, `config/router.php`, and all `patches/*.patch` in lexical order.
- Produces: `Install-CanaryAAC.ps1 [-Plan]`, a PHP runtime with required modules, Composer 2.10.3, and a checkout whose base commit and patch set are recorded in `.tools/canaryaac/.local-install.json`.

- [ ] **Step 1: Add a failing dry-run contract**

Append this Pester case:

```powershell
It 'plans a pinned install without writing runtime state' {
    $plan = & (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | ConvertFrom-Json
    $plan.PhpVersion | Should Be '8.3.35'
    $plan.ComposerVersion | Should Be '2.10.3'
    $plan.CanaryAACCommit | Should Be 'd9333dcf33d3f55cee476e9ee8ebfe3f28113c19'
    $plan.Checkout | Should Match '\\.tools\\canaryaac$'
}
```

- [ ] **Step 2: Run the focused test and confirm the missing script failure**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Tooling.Tests.ps1' -TestName 'plans a pinned install without writing runtime state'
```

Expected: FAIL because `Install-CanaryAAC.ps1` does not exist.

- [ ] **Step 3: Implement deterministic provisioning**

The script must:

1. Resolve the repository root from `$PSScriptRoot\..\..` rather than hard-coding a user path.
2. Return the four-field JSON plan and exit before creating directories when `-Plan` is set.
3. Download into `.tools/downloads` only when the verified archive is absent.
4. Verify PHP and Composer hashes before extraction/execution.
5. Extract PHP to a temporary sibling directory, verify `php.exe`, then move it to `.tools/php`.
6. Copy the tracked `php.ini` to `.tools/php/php.ini` and `router.php` to `.tools/canaryaac/router.php`.
7. Clone CanaryAAC if absent; otherwise require its `origin` URL to match and refuse unrelated local modifications.
8. Fetch and detach exactly at the pinned commit.
9. Apply every numbered patch with `git apply --check` followed by `git apply`; record each patch SHA-256.
10. Run Composer with the local PHP executable and `--no-interaction --no-progress --prefer-dist --no-dev --no-scripts --no-plugins`.
11. Run `composer validate --strict`, then PHP syntax checks for every changed `.php` file.

Use this argument shape, keeping global Windows `PATH` unchanged:

```powershell
& $layout.PhpExe -c $layout.PhpIni $layout.Composer --working-dir=$($layout.Checkout) install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-plugins
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

When no patch exists yet, record an empty patch list. On rerun, require the pinned
base commit, process patches in lexical order, and use `git apply --check` to
apply an absent patch or `git apply --reverse --check` to recognize an already
applied patch. Derive the allowed changed-file set from `git apply --numstat`
for all tracked patches and refuse any checkout change outside that set. Update
`.local-install.json` only after all patch hashes and allowed paths verify; add
that machine-local manifest to `.git/info/exclude`. Never reset or delete a
checkout that contains an unaccounted change.

- [ ] **Step 4: Run tests and install the unmodified pinned base**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Tooling.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& '.\tools\local-canaryaac\Install-CanaryAAC.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: PHP reports `8.3.35`, Composer reports `2.10.3`, CanaryAAC `HEAD` equals the pinned commit, required PHP modules include `curl`, `dom`, `gd`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `sodium`, and `xml`, and no global PHP installation is created.

- [ ] **Step 5: Commit the installer**

```powershell
git add tools/local-canaryaac/Install-CanaryAAC.ps1 tools/local-canaryaac/tests/Tooling.Tests.ps1
git commit -m "build: provision pinned CanaryAAC dependencies"
```

---

### Task 3: Back up and migrate the live database without altering existing rows

**Files:**
- Create: `tools/local-canaryaac/sql/001-canaryaac-local.sql`
- Create: `tools/local-canaryaac/Initialize-CanaryAACDatabase.ps1`
- Create: `tools/local-canaryaac/tests/Database.Tests.ps1`
- Produce: `.tools/backups/canaryaac-preinstall-<timestamp>.sql` and matching evidence JSON (ignored)
- Produce: `.tools/canaryaac/.env` (ignored)

**Interfaces:**
- Consumes: a `PSCredential` for a MariaDB schema administrator, `.tools/mariadb/bin/mariadb.exe`, `.tools/mariadb/bin/mariadb-dump.exe`, and the installed checkout.
- Produces: `accounts.page_access`, `players.main`, `players.world`, the six local AAC tables, deterministic local seed rows, `canaryaac_local@127.0.0.1`, and the local `.env`.

- [ ] **Step 1: Write static migration safety tests**

Create Pester tests that read the SQL as one string and reject destructive core-table patterns:

```powershell
Describe 'CanaryAAC database migration' {
    $sql = Get-Content (Join-Path $PSScriptRoot '..\sql\001-canaryaac-local.sql') -Raw

    It 'never imports destructive upstream statements' {
        $sql | Should Not Match '(?i)DROP\s+(INDEX|TABLE)'
        $sql | Should Not Match '(?i)(DELETE|INSERT|UPDATE)\s+(FROM\s+|INTO\s+)?`?(accounts|players)`?'
        $sql | Should Not Match '(?i)MODIFY\s+(COLUMN\s+)?`?creation`?'
    }

    It 'contains all five vocation seeds and Thais coordinates' {
        foreach ($vocation in 1,2,3,4,9) { $sql | Should Match "(?s)\\($vocation,\\s*$vocation," }
        $sql | Should Match '32369,\s*32241,\s*7'
    }
}
```

- [ ] **Step 2: Run the database tests and confirm the missing migration failure**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Database.Tests.ps1'
```

Expected: FAIL because the SQL file is absent.

- [ ] **Step 3: Write the adapted idempotent migration**

The SQL must use `ADD COLUMN IF NOT EXISTS` and `CREATE TABLE IF NOT EXISTS` for:

```sql
ALTER TABLE `accounts` ADD COLUMN IF NOT EXISTS `page_access` INT NOT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `main` INT NOT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `world` INT NOT NULL DEFAULT 0;
```

Create exactly these AAC-owned tables required by `/createaccount` and the shared base layout: `canary_website`, `canary_worlds`, `canary_samples`, `canary_countdowns`, `canary_polls`, and `canary_polls_questions`. Use `utf8mb4`, InnoDB, upstream-compatible column names, primary keys, and no foreign key into a core table.

Seed these deterministic rows with `INSERT ... ON DUPLICATE KEY UPDATE` keyed by the stated IDs:

```text
canary_website id=1: America/Sao_Paulo, Canary Local, player_voc=1,
  player_max=10, player_guild=100, donates=0, all payment flags=0
canary_worlds id=1: Canary Local, location=7, pvp_type=0, ip=127.0.0.1, port=7172
canary_samples ids/vocations=1/1,2/2,3/3,4/4,9/9:
  experience=4200, level=8, health=185, healthmax=185, maglevel=0,
  mana=90, manamax=90, manaspent=0, soul=0, town_id=8,
  posx=32369, posy=32241, posz=7, cap=470, balance=0,
  lookbody=113, lookfeet=115, lookhead=95, looklegs=39,
  looktype=129, lookaddons=0
```

- [ ] **Step 4: Implement guarded backup, restore test, migration, and grants**

`Initialize-CanaryAACDatabase.ps1` accepts mandatory `-AdminCredential`, uses `MYSQL_PWD` only inside a `try/finally`, and performs this order:

1. Confirm `CanaryMariaDB` is running and `SELECT VERSION()` succeeds.
2. Export `canary` with `--single-transaction --routines --events --triggers --default-character-set=utf8mb4` using `Start-Process -RedirectStandardOutput`.
3. Reject an empty dump or one missing both `CREATE TABLE \`accounts\`` and `CREATE TABLE \`players\``.
4. Create an explicitly generated database matching `^canaryaac_restore_[0-9]{14}_[a-f0-9]{8}$`, import the dump there with `-RedirectStandardInput`, verify both core tables and their row counts, and drop only that validated name in `finally`.
5. Capture `SHOW CREATE TABLE` for `accounts` and `players`, their complete ordered row exports, the GOD row, and all names ending in ` Sample` before migration.
6. Apply `001-canaryaac-local.sql` to `canary`.
7. Assert `accounts.creation` is still unsigned integer, `accounts_unique` and `players_unique` exist, `players_account_fk` still cascades, and every captured preexisting row is byte-for-byte unchanged.
8. Run the migration a second time and repeat the invariants.
9. Generate a 32-byte cryptographic password when `.env` does not exist; on rerun, read the existing `DB_PASS` and reuse it.
10. Feed SQL through standard input to create or alter `canaryaac_local@127.0.0.1`, revoke prior privileges, grant only the approved `SELECT` and table `INSERT` privileges, and flush privileges.
11. Write `.tools/canaryaac/.env` with `URL=http://127.0.0.1:8080`, database settings, `M_COST=65536`, `T_COST=2`, `PARALLELISM=2`, `MAINTENANCE=false`, `DEV_MODE=true`, `MULTI_WORLD=false`, blank payment/mail values, and `OUTFITS_FOLDER=/resources/images/charactertrade/outfits`.

Do not print either database password. Restore the caller's prior `MYSQL_PWD` value in `finally`.

- [ ] **Step 5: Run static tests, then execute and verify the live migration**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Database.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$admin = Get-Credential -UserName 'root' -Message 'MariaDB schema administrator for the local Canary database'
& '.\tools\local-canaryaac\Initialize-CanaryAACDatabase.ps1' -AdminCredential $admin
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: a verified dump and evidence JSON exist under `.tools/backups`; the live migration passes twice; GOD and all preexisting samples match their baseline; `SHOW GRANTS FOR 'canaryaac_local'@'127.0.0.1'` contains only the approved privileges.

- [ ] **Step 6: Commit the migration**

```powershell
git add tools/local-canaryaac/sql/001-canaryaac-local.sql tools/local-canaryaac/Initialize-CanaryAACDatabase.ps1 tools/local-canaryaac/tests/Database.Tests.ps1
git commit -m "feat: add safe CanaryAAC database migration"
```

---

### Task 4: Add authoritative input validation and safe Argon configuration

**Files:**
- Create in checkout: `.tools/canaryaac/app/Utils/AccountCreationValidator.php`
- Modify in checkout: `.tools/canaryaac/app/Utils/Argon.php`
- Create: `tools/local-canaryaac/tests/php/bootstrap.php`
- Create: `tools/local-canaryaac/tests/php/AccountCreationValidatorTest.php`
- Create: `tools/local-canaryaac/tests/php/ArgonCompatibilityTest.php`
- Create: `tools/local-canaryaac/patches/0001-safe-input-and-argon.patch`

**Interfaces:**
- Consumes: raw POST fields and numeric Argon parameters from `.env`.
- Produces: `AccountCreationValidator::validate(array $input): array` and unchanged compact hash format from `Argon::generateArgonPassword(string $password): string`.

- [ ] **Step 1: Write failing PHP tests**

`bootstrap.php` must load `.tools/canaryaac/vendor/autoload.php` and define `assertSameValue`, `assertTrueValue`, and `assertDomainError` helpers that throw `RuntimeException` and never echo secrets.

The validator test must prove one valid input normalizes sex `2` to `0`, preserves the password `Valid<&Pass12` exactly, accepts every vocation in `[1,2,3,4,9]`, and rejects these exact cases:

```php
$invalid = [
    ['accname' => 'ab', 'message' => 'Account name'],
    ['accname' => 'bad-name', 'message' => 'Account name'],
    ['email' => 'not-an-email', 'message' => 'email'],
    ['password1' => 'short', 'password2' => 'short', 'message' => '12'],
    ['password2' => 'DifferentPassword12', 'message' => 'match'],
    ['name' => ' Bad Name', 'message' => 'Character name'],
    ['name' => 'Bad  Name', 'message' => 'Character name'],
    ['vocation' => '5', 'message' => 'vocation'],
    ['sex' => '3', 'message' => 'sex'],
    ['agreeagreements' => 'false', 'message' => 'rules'],
];
```

The Argon test configures `65536,2,2`, generates a compact hash, requires it to match `^\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$`, reconstructs `$argon2id$v=19$m=65536,t=2,p=2<compact>`, and verifies the original password with `password_verify`.

- [ ] **Step 2: Run the PHP tests and confirm the validator failure**

```powershell
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\tools\local-canaryaac\tests\php\AccountCreationValidatorTest.php'
```

Expected: nonzero exit because `App\Utils\AccountCreationValidator` does not exist.

- [ ] **Step 3: Implement the validator**

Use `DomainException` with fixed user-safe messages and this contract:

```php
final class AccountCreationValidator
{
    private const ALLOWED_VOCATIONS = [1, 2, 3, 4, 9];

    public static function validate(array $input): array
    {
        $accountName = trim((string)($input['accname'] ?? ''));
        $email = trim((string)($input['email'] ?? ''));
        $password = (string)($input['password1'] ?? '');
        $confirmation = (string)($input['password2'] ?? '');
        $characterName = trim((string)($input['name'] ?? ''));

        if (!preg_match('/\A[A-Za-z0-9]{3,32}\z/D', $accountName)) {
            throw new \DomainException('Account name must contain 3 to 32 ASCII letters or digits.');
        }
        if (strlen($email) > 255 || filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
            throw new \DomainException('Enter a valid email address.');
        }
        $passwordLength = mb_strlen($password, 'UTF-8');
        if ($passwordLength < 12 || $passwordLength > 128) {
            throw new \DomainException('Password must contain 12 to 128 characters.');
        }
        if (!hash_equals($password, $confirmation)) {
            throw new \DomainException('Password confirmation must match.');
        }
        if (strlen($characterName) < 5 || strlen($characterName) > 29 ||
            !preg_match('/\A[A-Za-z]+(?: [A-Za-z]+)*\z/D', $characterName)) {
            throw new \DomainException('Character name must contain 5 to 29 ASCII letters separated by single spaces.');
        }
        $vocation = filter_var($input['vocation'] ?? null, FILTER_VALIDATE_INT);
        if (!in_array($vocation, self::ALLOWED_VOCATIONS, true)) {
            throw new \DomainException('Select a valid vocation.');
        }
        $sex = match ((string)($input['sex'] ?? '')) {
            '1' => 1,
            '2' => 0,
            default => throw new \DomainException('Select a valid sex.'),
        };
        if (($input['agreeagreements'] ?? '') !== 'true') {
            throw new \DomainException('You must accept the rules.');
        }

        return compact('accountName', 'email', 'password', 'characterName', 'vocation', 'sex');
    }
}
```

In `Argon.php`, remove both `eval` calls, store integer properties, validate positive parameters in `configArgon`, and pass `self::$m_cost` directly to `password_hash`. Preserve the compact `$salt$hash` representation and SHA-1 fallback behavior.

- [ ] **Step 4: Run validation and Argon tests**

```powershell
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\tools\local-canaryaac\tests\php\AccountCreationValidatorTest.php'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\tools\local-canaryaac\tests\php\ArgonCompatibilityTest.php'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: both scripts print one PASS line and exit zero.

- [ ] **Step 5: Capture and verify the first downstream patch**

Use `git -C .tools/canaryaac diff -- app/Utils/AccountCreationValidator.php app/Utils/Argon.php` to inspect the exact diff. Create `0001-safe-input-and-argon.patch` with `apply_patch` from that diff, then verify it against a clean detached worktree at the pinned commit:

```powershell
$check = Join-Path (Resolve-Path '.tools').Path 'canaryaac-patch-check'
$patch = (Resolve-Path 'tools\local-canaryaac\patches\0001-safe-input-and-argon.patch').Path
git -C '.tools\canaryaac' worktree add --detach $check d9333dcf33d3f55cee476e9ee8ebfe3f28113c19
git -C $check apply --check $patch
git -C '.tools\canaryaac' worktree remove $check
```

Expected: `git apply --check` exits zero. The worktree command removes only the explicitly named check worktree.

- [ ] **Step 6: Commit validator, tests, and patch**

```powershell
git add tools/local-canaryaac/tests/php tools/local-canaryaac/patches/0001-safe-input-and-argon.patch
git commit -m "feat: validate CanaryAAC registration input"
```

---

### Task 5: Make account and character insertion atomic

**Files:**
- Modify in checkout: `.tools/canaryaac/app/DatabaseManager/Database.php`
- Modify in checkout: `.tools/canaryaac/app/Model/Entity/CreateAccount.php`
- Create: `tools/local-canaryaac/tests/php/AccountTransactionTest.php`
- Create: `tools/local-canaryaac/patches/0002-atomic-account-character.patch`

**Interfaces:**
- Consumes: validated account and character arrays.
- Produces: `Database::transaction(callable $operation): mixed` and `CreateAccount::createAccountWithCharacter(array $account, array $character): int`.

- [ ] **Step 1: Write the failing transaction integration test**

The test loads `.env`, configures `Database`, generates a unique valid account name, and deliberately uses existing character name `GOD`:

```php
$account = [
    'name' => $uniqueAccount,
    'password' => '$testsalt$testhash',
    'email' => $uniqueAccount . '@example.test',
    'page_access' => 0,
    'premdays' => 0,
    'type' => 1,
    'coins' => 0,
    'creation' => time(),
    'recruiter' => 0,
];
$character = [
    'name' => 'GOD', 'group_id' => 1, 'main' => 1, 'world' => 1,
    'level' => 8, 'vocation' => 1, 'health' => 185, 'healthmax' => 185,
    'experience' => 4200, 'mana' => 90, 'manamax' => 90,
    'town_id' => 8, 'posx' => 32369, 'posy' => 32241, 'posz' => 7,
    'cap' => 470, 'conditions' => '', 'istutorial' => 0,
];
```

It must catch `PDOException`, then select `accounts.name=$uniqueAccount` and assert zero rows. It prints the unique account name only after proving rollback, never the password/hash.

- [ ] **Step 2: Run the transaction test and confirm the missing method failure**

```powershell
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\tools\local-canaryaac\tests\php\AccountTransactionTest.php'
```

Expected: nonzero exit because `createAccountWithCharacter` is undefined.

- [ ] **Step 3: Refactor Database to one shared PDO connection**

Replace per-instance connections with `private static ?PDO $connection = null`. `config()` must clear a previous connection, `getConnection()` must lazily construct PDO with UTF-8 and exception mode, and `execute()` must allow `PDOException` to propagate instead of calling `die()`.

Implement the exact transaction boundary:

```php
public static function transaction(callable $operation): mixed
{
    $connection = self::getConnection();
    $connection->beginTransaction();
    try {
        $result = $operation();
        $connection->commit();
        return $result;
    } catch (\Throwable $exception) {
        if ($connection->inTransaction()) {
            $connection->rollBack();
        }
        throw $exception;
    }
}
```

All existing instance methods must call the same `self::getConnection()`. `insert()` returns `(int) self::getConnection()->lastInsertId()`.

- [ ] **Step 4: Add the atomic entity API**

```php
public static function createAccountWithCharacter(array $account, array $character): int
{
    return Database::transaction(static function () use ($account, $character): int {
        $accountId = (new Database('accounts'))->insert($account);
        $character['account_id'] = $accountId;
        (new Database('players'))->insert($character);
        return $accountId;
    });
}
```

Keep `getPlayerSamples()` for controller reads. Remove the two public split-create methods so new controller code cannot accidentally bypass the transaction.

- [ ] **Step 5: Run the rollback and existing PHP tests**

```powershell
Get-ChildItem '.\tools\local-canaryaac\tests\php\*Test.php' | ForEach-Object {
    & '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' $_.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: the duplicate `GOD` insert throws, the transaction test finds no account row, and all PHP tests PASS.

- [ ] **Step 6: Capture, clean-apply, and commit the transaction patch**

Create `0002-atomic-account-character.patch` from only `Database.php` and `CreateAccount.php` using `apply_patch`. In a clean check worktree, apply patch 0001, then run `git apply --check` for patch 0002. Commit:

```powershell
git add tools/local-canaryaac/tests/php/AccountTransactionTest.php tools/local-canaryaac/patches/0002-atomic-account-character.patch
git commit -m "feat: create CanaryAAC account atomically"
```

---

### Task 6: Wire the safe five-vocation web flow and reduce unused integrations

**Files:**
- Modify in checkout: `.tools/canaryaac/app/Controller/Pages/Account/Create.php`
- Modify in checkout: `.tools/canaryaac/resources/view/pages/account/createaccount.html.twig`
- Modify in checkout: `.tools/canaryaac/resources/javascripts/create_character.js` only where its password checks conflict with 12-128 characters
- Modify in checkout: `.tools/canaryaac/composer.json`
- Modify in checkout: `.tools/canaryaac/composer.lock`
- Create: `tools/local-canaryaac/tests/fixtures/invalid-submissions.json`
- Create: `tools/local-canaryaac/patches/0003-local-account-flow.patch`

**Interfaces:**
- Consumes: `AccountCreationValidator::validate`, server-side sample/world rows, `Argon::generateArgonPassword`, and `CreateAccount::createAccountWithCharacter`.
- Produces: GET/POST `/createaccount` supporting vocations `1,2,3,4,9` and fixed safe browser messages.

- [ ] **Step 1: Add the rejected-submission fixture**

Create JSON cases for invalid email, mismatched passwords, vocation `5`, duplicate account, duplicate character, and `agreeagreements=false`. Each case includes `expectedText` and `expectedRowDelta: 0`; use valid values for every field not under test.

- [ ] **Step 2: Record the failing current form behavior**

Start PHP temporarily from the checkout and request the form:

```powershell
$php = Start-Process -FilePath '.\.tools\php\php.exe' -ArgumentList @('-c','.tools\php\php.ini','-S','127.0.0.1:8080','-t','.tools\canaryaac','.tools\canaryaac\router.php') -PassThru -WindowStyle Hidden
try {
    $html = (Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8080/createaccount').Content
    if ($html -match 'value="9"') { throw 'The red check unexpectedly found Monk' }
} finally {
    Stop-Process -Id $php.Id -Force -ErrorAction SilentlyContinue
}
```

Expected: the page renders but has no `value="9"` vocation choice.

- [ ] **Step 3: Replace controller trust and split inserts**

The POST method must:

1. Call `AccountCreationValidator::validate($request->getPostVars())` before queries or hashing.
2. Check account name, email, and character name uniqueness with parameterized existing entity selectors.
3. Fetch the sample by the validated vocation and the world by fixed server-side `id=1`; ignore client-supplied world identity.
4. Hash the untouched validated password.
5. Build the account with `page_access=0`, `premdays=0`, `type=1`, `coins=0`, `creation=time()`, and `recruiter=0`.
6. Build the character with `group_id=1`, `main=1`, `world=1`, `conditions=''`, `istutorial=0`, validated name/sex, and every stat/appearance/position field from the selected sample.
7. Call `createAccountWithCharacter()` exactly once.
8. Catch `DomainException` and render its fixed message; translate SQLSTATE `23000` to a generic duplicate message; log other exceptions with class, numeric code, message, and trace but never request data, plaintext password, or hash.
9. Pass only email/premdays/coins and character display fields to the confirmation view.

Use this account/character core:

```php
$account = [
    'name' => $data['accountName'],
    'password' => Argon::generateArgonPassword($data['password']),
    'email' => $data['email'],
    'page_access' => 0, 'premdays' => 0, 'type' => 1,
    'coins' => 0, 'creation' => time(), 'recruiter' => 0,
];
$character = [
    'name' => $data['characterName'], 'group_id' => 1,
    'main' => 1, 'world' => 1, 'sex' => $data['sex'],
    'conditions' => '', 'istutorial' => 0,
    'level' => (int)$sample->level, 'vocation' => (int)$sample->vocation,
    'health' => (int)$sample->health, 'healthmax' => (int)$sample->healthmax,
    'experience' => (int)$sample->experience,
    'mana' => (int)$sample->mana, 'manamax' => (int)$sample->manamax,
    'manaspent' => (int)$sample->manaspent, 'maglevel' => (int)$sample->maglevel,
    'soul' => (int)$sample->soul, 'town_id' => (int)$sample->town_id,
    'posx' => (int)$sample->posx, 'posy' => (int)$sample->posy,
    'posz' => (int)$sample->posz, 'cap' => (int)$sample->cap,
    'balance' => (int)$sample->balance, 'lookbody' => (int)$sample->lookbody,
    'lookfeet' => (int)$sample->lookfeet, 'lookhead' => (int)$sample->lookhead,
    'looklegs' => (int)$sample->looklegs, 'looktype' => (int)$sample->looktype,
    'lookaddons' => (int)$sample->lookaddons,
];
```

- [ ] **Step 4: Update the form and local dependency scope**

In Twig, escape `status` normally instead of using `|raw`, set account maxlength 32, set both password maxlength values to 128, state the 12-128 rule, and add:

```html
<span class="OptionContainer">
  <input id="vocation_monk" type="radio" name="vocation" value="9">
  <label for="vocation_monk">Monk</label>
</span>
```

Align any JavaScript length gate with `12 <= length <= 128`; server validation remains authoritative.

Remove the disabled integration packages from the local downstream dependency graph and update the lock with pinned Composer:

```powershell
Push-Location '.tools\canaryaac'
try {
    & '..\php\php.exe' -c '..\php\php.ini' '..\composer\composer.phar' remove pagseguro/pagseguro-php-sdk mercadopago/dx-php paypal/rest-api-sdk-php symfony/mailer pragmarx/google2fa team-reflex/discord-php --no-interaction --no-scripts --no-plugins
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally { Pop-Location }
```

- [ ] **Step 5: Verify form, syntax, dependencies, and one Monk creation**

Run PHP syntax checks on all patched PHP files, `composer validate --strict`, and:

```powershell
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\.tools\composer\composer.phar' --working-dir='.tools\canaryaac' audit --locked --no-dev --abandoned=report
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Start the temporary server, require a 200 response, assert the HTML contains each vocation value, submit a unique Monk registration, and query MariaDB to assert one type-1 account plus one group-1, vocation-9, level-8, town-8 character at `32369,32241,7`. Delete only that exact temporary account with the administrator credential after the assertion.

- [ ] **Step 6: Capture, clean-apply, and commit the web-flow patch**

Create patch 0003 from the six listed checkout files using `apply_patch`. Apply 0001 and 0002 in a clean check worktree, then require `git apply --check` for 0003. Commit:

```powershell
git add tools/local-canaryaac/tests/fixtures/invalid-submissions.json tools/local-canaryaac/patches/0003-local-account-flow.patch
git commit -m "feat: add five-vocation CanaryAAC signup flow"
```

---

### Task 7: Integrate identity-safe startup and shutdown

**Files:**
- Create: `tools/local-canaryaac/Start-CanaryAAC.ps1`
- Create: `tools/local-canaryaac/Stop-CanaryAAC.ps1`
- Create: `tools/local-canaryaac/tests/Lifecycle.Tests.ps1`
- Modify: `iniciar-servidor.bat`
- Modify: `parar-servidor.bat`

**Interfaces:**
- Consumes: installed runtime/checkout, `.env`, shared process helpers, and existing `.tools/start-local.ps1` / `.tools/stop-local.ps1`.
- Produces: one loopback PHP listener, `.tools/canaryaac.pid`, `.tools/logs/canaryaac.log`, and integrated batch UX.

- [ ] **Step 1: Write failing lifecycle tests**

Pester must stop only a previously verified test AAC process, then prove:

```powershell
$first = & (Join-Path $toolRoot 'Start-CanaryAAC.ps1') -PassThru
$second = & (Join-Path $toolRoot 'Start-CanaryAAC.ps1') -PassThru
$first.Id | Should Be $second.Id
(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 8080 -State Listen).Count | Should Be 1
(Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8080/createaccount').StatusCode | Should Be 200
& (Join-Path $toolRoot 'Stop-CanaryAAC.ps1')
(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
```

Add a mocked identity test showing `Stop-CanaryAAC.ps1` refuses a PID whose executable or command line does not match.

- [ ] **Step 2: Run the lifecycle test and confirm the missing scripts failure**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Lifecycle.Tests.ps1'
```

Expected: FAIL because start/stop scripts do not exist.

- [ ] **Step 3: Implement guarded startup**

`Start-CanaryAAC.ps1 -PassThru` must:

- require `.env`, `vendor/autoload.php`, PHP, router, and successful `pdo_mysql`/`sodium` module checks;
- if the PID file names a verified expected process and `/createaccount` is ready, return that process without starting another;
- if port 8080 is occupied by anything else, throw without terminating it;
- remove a stale PID file only after proving its PID is absent;
- create `.tools/logs`, set PHP `error_log` to `.tools/logs/canaryaac.log`, start hidden with explicit `-c`, `-S 127.0.0.1:8080`, `-t`, and router arguments;
- write the PID only after `Start-Process -PassThru` succeeds;
- poll `/createaccount` for at most 30 seconds, and on failure identity-check then stop its own process and report the three AAC log paths.

- [ ] **Step 4: Implement identity-checked shutdown**

`Stop-CanaryAAC.ps1` must return successfully when no PID file exists. If the PID is absent, remove only the stale PID file. If the PID exists but `Test-CanaryAACProcess` is false, throw and preserve the file/process. Only a verified process may receive `Stop-Process`; wait up to 10 seconds, then remove its PID file.

- [ ] **Step 5: Integrate the existing batch entry points**

After `.tools\start-local.ps1` succeeds, `iniciar-servidor.bat` calls the tracked AAC start script and prints:

```text
Site/ACC:       http://127.0.0.1:8080
Login do jogo:  http://127.0.0.1:8088/login
Jogo:           127.0.0.1:7172
```

`parar-servidor.bat` invokes `Stop-CanaryAAC.ps1` before `.tools\stop-local.ps1`; it propagates a nonzero AAC stop result and does not claim success if identity verification failed.

- [ ] **Step 6: Run lifecycle tests twice**

```powershell
Invoke-Pester '.\tools\local-canaryaac\tests\Lifecycle.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Invoke-Pester '.\tools\local-canaryaac\tests\Lifecycle.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: both passes start exactly one AAC process, receive HTTP 200, stop it safely, and release port 8080.

- [ ] **Step 7: Commit lifecycle integration**

```powershell
git add tools/local-canaryaac/Start-CanaryAAC.ps1 tools/local-canaryaac/Stop-CanaryAAC.ps1 tools/local-canaryaac/tests/Lifecycle.Tests.ps1 iniciar-servidor.bat parar-servidor.bat
git commit -m "feat: integrate CanaryAAC local lifecycle"
```

---

### Task 8: Run the full five-vocation acceptance suite and document operation

**Files:**
- Create: `tools/local-canaryaac/Test-CanaryAACE2E.ps1`
- Create: `tools/local-canaryaac/Remove-CanaryAACTestData.ps1`
- Create: `tools/local-canaryaac/README.md`
- Produce: `.tools/test-artifacts/canaryaac-e2e.json` (ignored, temporary)

**Interfaces:**
- Consumes: running ports 8080, 8088, 7172, the invalid fixture, and a MariaDB administrator credential.
- Produces: evidence for five valid registrations, all invalid cases, login-server authentication, one client world entry, safe cleanup, and operator instructions.

- [ ] **Step 1: Write the failing acceptance preflight**

`Test-CanaryAACE2E.ps1` accepts mandatory `-AdminCredential` and `-KeepAccounts`. Its preflight must fail unless all are true: MariaDB service running; listeners on 7172, 8088, and loopback-only 8080; `/createaccount` returns 200; the pinned checkout/patch manifest matches; the backup evidence from Task 3 exists; and Composer audit exits zero.

Run it before implementation:

```powershell
& '.\tools\local-canaryaac\Test-CanaryAACE2E.ps1' -AdminCredential (Get-Credential -UserName root)
```

Expected: FAIL because the script is absent.

- [ ] **Step 2: Implement unique, reversible test identity generation**

Use account names `aacz` plus a UTC timestamp and vocation digit. Generate character suffixes from letters `a` through `f` only, producing names such as `Aac Verify Monk abefca`; keep every character name at most 29 characters. Before submission, assert no generated account, email, or character exists. Save exact account IDs/names, character IDs/names, vocation, and the generated plaintext password only to `.tools/test-artifacts/canaryaac-e2e.json`; never log the password or commit the artifact.

- [ ] **Step 3: Submit and verify all five vocations**

For each mapping `1=Sorcerer`, `2=Druid`, `3=Paladin`, `4=Knight`, `9=Monk`, create a fresh `WebRequestSession` and POST:

```powershell
$form = @{
    accname = $accountName
    email = "$accountName@example.test"
    password1 = $password
    password2 = $password
    name = $characterName
    sex = '1'
    vocation = [string]$vocation
    world = 'server_Canary Local'
    agreeagreements = 'true'
}
$response = Invoke-WebRequest -UseBasicParsing -WebSession $session -Method Post -Uri 'http://127.0.0.1:8080/createaccount' -Body $form
if ($response.StatusCode -ne 200 -or $response.Content -notmatch 'Account Created') { throw "Creation failed for vocation $vocation" }
```

Query by exact generated names and require: one account, one player, matching FK, account `type=1`, player `group_id=1`, `main=1`, `world=1`, requested vocation, level 8, experience 4200, health 185, mana 90, capacity 470, town 8, and `32369,32241,7`. Reconstruct each stored compact Argon hash and verify it locally; assert the stored hash is neither plaintext nor SHA-1.

- [ ] **Step 4: Authenticate each account through login-server**

POST the exact existing login protocol:

```powershell
$body = @{
    type = 'login'; email = $accountName; password = $password
    clientversion = '15.25.0a00a0'; clienttype = 5
    devicecookie = 'canaryaac-local-verification'; stayloggedin = $false
} | ConvertTo-Json
$login = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8088/login' -ContentType 'application/json' -Body $body
if ($login.playdata.characters.name -notcontains $characterName) { throw "Character missing from login response: $characterName" }
$world = $login.playdata.worlds | Where-Object id -eq 1 | Select-Object -First 1
if ($world.externaladdressunprotected -ne '127.0.0.1' -or $world.externalportunprotected -ne 7172) { throw 'Login response is not local Canary :7172' }
```

- [ ] **Step 5: Exercise all invalid and rollback cases**

For each JSON fixture, record exact account/player counts, submit, assert its fixed message is HTML-escaped, and require unchanged counts. Then run `AccountTransactionTest.php` again to prove the post-account character failure leaves neither row. Confirm the GOD SHA-1 value and every baseline row recorded by Task 3 still match.

- [ ] **Step 6: Verify one real client world entry**

Run with `-KeepAccounts`, open `.tools\tibia-client-15.25\bin\client.exe`, and use one generated account from the ignored evidence file. Select its character, enter the world, and confirm both that the client displays the level 8 character in Thais and that Canary records the exact player ID in `players_online` during the session. Record the account/character ID and timestamp in the evidence JSON, without a screenshot containing the password.

- [ ] **Step 7: Implement and run exact-manifest cleanup**

`Remove-CanaryAACTestData.ps1` reads the ignored evidence manifest, verifies every recorded account still has the recorded name/email and every player belongs to that account, refuses any unrecorded row, then deletes only the recorded account IDs through the administrator connection. Rely on `players_account_fk ON DELETE CASCADE`, assert all recorded players disappeared, and assert GOD plus the Task 3 baseline still match. Delete the evidence file only after all cleanup assertions pass.

```powershell
& '.\tools\local-canaryaac\Remove-CanaryAACTestData.ps1' -AdminCredential $admin
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

- [ ] **Step 8: Document install, start, use, stop, restore, and scope**

`README.md` must include exact commands for:

- installing runtime/source;
- prompting for the database administrator and running the migration;
- starting with `iniciar-servidor.bat` and stopping with `parar-servidor.bat`;
- opening `http://127.0.0.1:8080/createaccount`;
- explaining that `8088/login`, not the AAC, is the Tibia client endpoint;
- locating logs/PID/backup evidence without revealing secrets;
- restoring the selected dump into a newly named recovery database first, never directly over live `canary`;
- rerunning Pester, PHP, Composer audit, lifecycle, and end-to-end checks;
- stating clearly that LAN/internet exposure is unsupported until a separate security design is approved.

- [ ] **Step 9: Run the final verification matrix**

```powershell
git diff --check
Invoke-Pester '.\tools\local-canaryaac\tests\*.Tests.ps1'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Get-ChildItem '.\tools\local-canaryaac\tests\php\*Test.php' | ForEach-Object {
    & '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' $_.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\.tools\composer\composer.phar' --working-dir='.tools\canaryaac' validate --strict
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& '.\.tools\php\php.exe' -c '.\.tools\php\php.ini' '.\.tools\composer\composer.phar' --working-dir='.tools\canaryaac' audit --locked --no-dev --abandoned=report
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& '.\tools\local-canaryaac\Test-CanaryAACE2E.ps1' -AdminCredential $admin -KeepAccounts
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

After the manual client check, run cleanup, start twice to prove a single AAC PID, stop through the normal batch flow, and confirm port 8080 is released. Review `.tools/logs/canaryaac.log` for warnings, SQL errors, plaintext passwords, or compact hashes; any match blocks completion.

- [ ] **Step 10: Commit acceptance automation and documentation**

```powershell
git add tools/local-canaryaac/Test-CanaryAACE2E.ps1 tools/local-canaryaac/Remove-CanaryAACTestData.ps1 tools/local-canaryaac/README.md
git commit -m "test: verify CanaryAAC local account flow"
```

---

## Completion Gate

Before declaring the integration complete, record fresh evidence for all of these:

- exact PHP, Composer, MariaDB, CanaryAAC, and parent repository revisions;
- matching archive and patch checksums;
- clean Composer validation/audit and PHP syntax/test results;
- verified pre-migration dump restore into a temporary database;
- unchanged preexisting accounts/players, core column types, indexes, and FK;
- idempotent second migration;
- loopback-only port 8080 and one identity-verified AAC process after repeated start;
- five successful website registrations and five successful login-server responses;
- invalid/duplicate/forced-failure cases with zero row delta;
- one generated character entering Canary at level 8 in Thais;
- exact-manifest cleanup with GOD and sample rows unchanged;
- normal stop releasing port 8080 without touching unrelated processes.
