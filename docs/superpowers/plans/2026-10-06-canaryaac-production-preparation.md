# CanaryAAC Production Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the working local signup and deliver a reproducible, secured application and deployment package with explicit production launch gates.

**Architecture:** Ordered downstream patches preserve current application edits and add shared web security and atomic signup. An isolated public entry point is served by PHP-FPM/IIS in future production. Versioned templates, release export and read-only readiness checks distinguish local verification from public deployment.

**Tech Stack:** PHP 8.3.35, Composer 2.10.3, CanaryAAC d9333dcf33d3f55cee476e9ee8ebfe3f28113c19, MariaDB 11.8.5, PowerShell 5.1/Pester 3.4, Nginx/PHP-FPM or IIS FastCGI.

**Spec:** docs/superpowers/specs/2026-10-06-canaryaac-production-preparation-design.md

## Global Constraints

- Work in the existing isolated worktree; preserve all user gameplay edits and existing accounts/players.
- Keep the active website at 127.0.0.1:8080, game at 127.0.0.1:7172 and login at 127.0.0.1:8088/login. Do not publish, change DNS/firewall/public binds or register a server.
- Preserve the pinned PHP/Composer/upstream source. Remaining PHP dependencies may be updated and locked after verifying compatibility/advisories.
- Runtime/credentials/dumps/logs/state are ignored under .tools. Never print secret values, tokens, request bodies or password hashes.
- Never weaken private .env/backup ACLs, reinitialize/import raw upstream SQL, modify existing core rows or run C++ build.
- Allowed vocations are 1,2,3,4,9; new account type=1, player group_id=1, main=1, world=1, level=8, experience=4200, town_id=8, position 32369,32241,7.
- New passwords use compact Argon2id 65536/2/2; existing SHA-1 accounts remain readable and unchanged.
- Production uses HTTPS with Nginx/PHP-FPM or IIS FastCGI, not php -S. Missing external launch inputs remain explicit failing gates.

## File structure

- `tools/local-canaryaac/patches/0001-current-local-baseline.patch`: existing app/UI drift, no .env/vendor/router/generated state.
- `tools/local-canaryaac/patches/0002-web-security.patch`: PHP web-security helper, public entry point, app bootstrap, CSRF forms/session and view boolean handling.
- `tools/local-canaryaac/patches/0003-atomic-signup.patch`: validation, Argon, PDO transaction, controller/forms.
- `tools/local-canaryaac/patches/0004-production-dependencies.patch`: dependency json/lock changes only.
- `tools/local-canaryaac/config/router.php`: canonical secure local router, copied to runtime preserving image fallbacks.
- `tools/local-canaryaac/tests/php/*Test.php`: focused self-contained PHP regression tests.
- `tools/local-canaryaac/production/`: Nginx, IIS, PHP, env and deployment settings examples.
- `tools/local-canaryaac/Export-CanaryAACRelease.ps1`: secret-free validated release staging under .tools/releases.
- `tools/local-canaryaac/Test-CanaryAACReadiness.ps1`: read-only local/production gate report.
- `tools/local-canaryaac/README.md`: local operation and production handoff.
- `docs/operations/canaryaac-production.md`: launch/backup/rollback/otservlist runbook.

### Task 1: Preserve local application and close web exposure

**Files:** baseline/security patches; canonical/runtime router; runtime App/Utils/WebSecurity.php, public/index.php, includes/app.php, index.php, session login classes, relevant Twig login/signup forms, View.php; tests/php/WebSecurityTest.php and RouterSecurityTest.php.

**Interfaces:** WebSecurity::boot(array $environment): void configures one session, profile and private state; WebSecurity::csrfToken(): string; WebSecurity::requireCsrf(array $post): void; WebSecurity::checkRateLimit(string $action, string $remoteAddress): void. Profile defaults local, production validates HTTPS URL and disables unreviewed endpoints. public/index.php delegates to the single audited application entry. Subsequent signup task consumes these methods.

- [ ] Step 1: inspect exact current runtime diff and capture baseline patch excluding .env, vendor, router, caches/generated files. Include untracked hand-written PHP only when genuinely required. Validate apply in a clean temporary index/tree. Preserve original edits and image fallbacks.
- [ ] Step 2: RED HTTP/router cases: HEAD /.env, /.git/HEAD, /composer.lock, /canaryaac.sql, /vendor/composer/installed.json, encoded dot paths, mixed case, resources traversal/PHP, symlink escape; no response body retrieval for real secrets. Fixtures may use fake secret sentinel files.
- [ ] Step 3: replace router with realpath-contained static allowlist, hidden-segment/internal-extension rejection, security headers and safe fallback. Production `public` includes only index plus public asset placement/link strategy compatible with Windows/Linux and release exporter; never symlink private dirs into public. Production runtime must route through public/index.php, not bypass guard by arbitrary PHP execution.
- [ ] Step 4: implement shared boot/CSRF/limiter/session helper and call after env load before routing. POST body <=64 KiB; scalar csrf token with hash_equals; random_bytes token; per-IP signup 5/600 seconds and login 10/900 seconds persisted with flock outside public; reject exhausted with429/Retry-After and unsafe state with503. Ignore client forwarded IP headers. Cookie HttpOnly/Lax/Secure on verified production HTTPS, strict mode and regeneration on successful login. Add tokens to all enabled POST forms; handle logout safely. Production rejects admin, API, payment, uploads and unreviewed state-changing routes. Responses400/403/404/429/503 have fixed generic bodies.
- [ ] Step 5: preserve local URL and session compatibility. Fix DEV_MODE truthiness with strict parsing and always HTML autoescape. Disable browser error display via bootstrap; log only redacted exception type/code. Validate local GET home/createaccount/login and asset coverage against current HTML. Run:
```powershell
& .tools/php/php.exe -c .tools/php/php.ini tools/local-canaryaac/tests/php/WebSecurityTest.php
& .tools/php/php.exe -c .tools/php/php.ini tools/local-canaryaac/tests/php/RouterSecurityTest.php
```
- [ ] Step 6: capture security patch relative to baseline; apply/check baseline then security in fixture. Use meaningful behavior tests, PHP lint, git diff --check; commit owned tracked files and detailed task report. Do not stop the working PHP service; router/app are loaded per request.

### Task 2: Atomic validated signup, compatible authentication and audited dependencies

**Files:** runtime validator/Argon/Database/CreateAccount/Create controller; signup/confirmation templates and JS length rules; atomic-signup/dependencies patches; tests/php/AccountCreationValidatorTest.php, ArgonCompatibilityTest.php, AccountTransactionTest.php; fixtures/invalid-submissions.json.

**Interfaces:** AccountCreationValidator::validate(array $input): array returns accountName/email/password/characterName/sex/vocation; Database::transaction(callable $operation): mixed; CreateAccount::createAccountWithCharacter(array $account,array $character): int. Consume Task1 security boot/CSRF/rate gate.

**Additional confirmed integration interface:** local login-server revision2612930de4d97123a397f8f2cd0d5f784094af40 authenticates only SHA-1. Create `tools/local-canaryaac/login-server/0001-compatible-passwords.patch` and a reproducible build/apply helper, preserving current login source edits. Add focused Go tests verifying PHP-generated compact Argon hash, wrong password, SHA1, invalid/malformed/bounded hashes and parameterized identity lookup. SQL lookup selects stored password by name/email (LIMIT1), verifies format in code, returns sql.ErrNoRows for invalid auth without logging password/hash; constant-time comparison for SHA1 and Argon. Costs fixed65536/2/2, salt16bytes and hash32bytes bounded before decoding/hash allocation. Use supported `golang.org/x/crypto/argon2` with pinned module checksums, Go caches/temp within .tools. Run focused Go package tests, build new exe to unique stage; preserve prior exe, identity-check only login-server PID/listener before controlled swap/restart with same local bind; do not stop Canary/game/website. Test browser signup Argon through actual login-server once patch deployed, with exact disposable identity/account IDs and cleanup. This narrow auth extension does not change wire protocol or website/game boundaries.

- [ ] Step 1: RED validation cases: every vocation valid, sex2→0, raw password `Valid<&Pass12` preserved, short/mismatch/non-scalar/invalid UTF8/invalid vocation/world injection/duplicate fields rejected. Account ASCII alnum3–32; character ASCII letters single spaces5–29 (leading/trailing whitespace rejected); email syntax/length; rules exact true; UTF8 password12–128 with no NUL.
- [ ] Step 2: RED Argon compact reconstruction/password_verify and legacy SHA1 correct/incorrect passwords. Config accepts bounded numeric costs, has no eval, does not write/downgrade during authentication. Existing SHA1 hashes are not migrated automatically.
- [ ] Step 3: implement shared PDO utf8mb4 exception connection with native prepared statements and transaction rollback on Throwable. Remove die-with-PDO-message paths. Atomic creation requires both rows committed or neither; account creation Unix timestamp; fixed account/player privilege/world fields; server sample validated before writes; conditions empty string; istutorial0. Tests can use PDO-compatible fake/local fixture connection to force second insert failure without touching live accounts.
- [ ] Step 4: wire controller validation before query/hash and CSRF/rate checks before expensive work; bounded input; uniqueness queries parameterized; generic duplicate/error messages; no password/hash confirmation fields. Update form five vocation values/max lengths, JS and normal escaping. Sample fetched vocation allowed, world fixedid1, ignore user-controlled privilege/world/stats.
- [ ] Step 5: remove disabled payment/SMTP/Discord/2FA packages from composer graph. Update retained dependencies compatibly with pinned Composer, confine HOME/cache/temp under .tools, disable scripts/plugins. Network access requires relevant tool escalation if blocked. Never treat network failure as clean audit. Run validate --strict and audit --locked --no-dev --abandoned=report; preserve the actual output/result in report without request secrets.
```powershell
Get-ChildItem tools/local-canaryaac/tests/php/*Test.php | ForEach-Object { & .tools/php/php.exe -c .tools/php/php.ini $_.FullName; if($LASTEXITCODE){throw 'PHP test failed'} }
```
- [ ] Step 6: capture atomic/dependency patches in lexical order; verify all patches against clean upstream and PHP lint; commit only patches/tests. Document exact runtime verification possible; no bulk deletion/test account removal. Live DB tests use separately identified test accounts/transactional rollback only when credentials are safely available; a sandbox restriction is reported, never bypassed by weakening ACL.

### Task 3: Deployment package, read-only release gates and operator runbook

**Files:** production configs/templates; Export-CanaryAACRelease.ps1; Test-CanaryAACReadiness.ps1; README; docs/operations/canaryaac-production.md; tests/Production.Tests.ps1.

**Interfaces:** `Test-CanaryAACReadiness.ps1 -Mode Local|Production [-SiteUrl] [-GameHost] [-StatusPort] [-Backend PhpFpm|IisFastCgi|Builtin] [-AuditEvidencePath] [-SkipHttp] [-ReportPath]` outputs nonsecret structured checks and nonzero on failing required gates. `Export-CanaryAACRelease.ps1 -OutputRoot <absolute .tools/releases path>` verifies complete patch/source identity and creates a new GUID release only, no clobber.

- [ ] Step 1: write readiness/export cases proving no secrets/source dirs in public, source/patch mismatch refused, malicious output/reparse targets refused and production HTTP/loopback/placeholders/Builtin/missing audit rejected. Local report can succeed with production blockers explicitly listed; modes cannot conflate local readiness with public launch.
- [ ] Step 2: templates use `example.invalid`, explicit replacement keys and no real secrets. Nginx Linux uses public docroot, exact index.php execution, fixed private FPM socket, allowed resource extensions only, encoded/hidden/php/internal deny, HTTP→HTTPS, HTTP body/timeout/security headers, login `/login` proxy to8088 preserving URI, per-IP limits and no logs of bodies. IIS template equivalent docroot/FastCGI/rewrite/hidden segments/request restrictions; explain URL Rewrite prerequisite. PHP settings debug off, expose off, strict HttpOnly/Secure/Lax sessions, external private logs/session/cache and OPcache. Environment example production, HTTPS URL, unique secret placeholders and feature flags, no enabled external integrations.
- [ ] Step 3: release reconstructs expected app tree from base+patches, verifies source drift, excludes .env/.git/vendor/generated state. Include locked dependencies only through verified Composer install or explicit packaging with audit evidence; no false clean build. Place resources safely under public and include LICENSE/lock/patch SHA256 manifest. Secrets supplied after release export; export does not configure/launch production. Current runtime is preserved.
- [ ] Step 4: read-only live HTTP gate requests safe pages, uses HEAD/blocked fixed responses for sensitive paths and parses cookie/security headers without storing secret values. Detect existing php -S only as local backend. Audit evidence binds lock hash/time/result and cannot be inferred from missing file. Production gate requires real HTTPS host/game host/status, successful audit, required features/session controls, deploy backend; clear manual gates for TLS/domain/firewall/external reachability/restore/rotation/otservlist counts.
- [ ] Step 5: operator runbook includes exact commands, local lifecycle limitations, private backup and isolated restore, rollback release/DB compatibility, daily/off-host backup plus retention/RPO/RTO decisions, log redaction, restart supervision, metrics/cert expiry, private DB/FPM/8088/9090, real IP handling, default credential rotation, mail/recovery policy and disabled integrations, legal/privacy owner-provided data. Distinguish website443, game7172/status7171/login server8088. Cite official otservlist FAQ; listing is advertising not hosting. Record online/peak count consistency audit as prelaunch gate; no invented numerical rules.
- [ ] Step 6: run appropriate PHP/Pester/config parser checks once, local HTTP regression, export fixture and real secret-free release if source/audit gates allow. Report any unvalidated IIS/Nginx/HTTPS/runtime/manual requirement accurately. Commit owned code/config/docs. Final broad review consumes all task packages, prior deferred minors and launch gates.
