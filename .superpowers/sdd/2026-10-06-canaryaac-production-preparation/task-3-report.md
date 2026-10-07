# Task 3 implementation report

Status: DONE_WITH_CONCERNS. Production has not been published. The controller
requested immediate handoff after the checks below; remaining review concerns
are explicit rather than represented as validated production behavior.

## Implemented

- Production helper reconstructs the pinned app plus ordered patches in a fresh
  isolated Git directory, excludes private/generated/vendor state and compares
  runtime deployable source (text CRLF normalization, binary SHA256).
- Exact established ignored animoutfit.php residue is allowed only at its exact
  canonical relative path and SHA256 2D1ED23B26803CDA4977A6FE8C461954320706899990F568DAB3115E9D7A45CC.
  It never feeds the export, and router denial remains enforced. This follows
  Task 1's established ruling, confirmed by the controller.
- Export requires fresh lock-bound Composer evidence and current Task 2 login
  manifest identity/audits. Output must be physical .tools/releases, with no
  reparse/relative/alternate-stream destination; fresh GUID only. Manifest records
  file/patch/lock hashes and explicitly Deployable=false, Dependencies=NotInstalled.
  No unaudited local vendor copy or false clean-build assertion.
- Readiness exact CLI supports Local/Production, SiteUrl/GameHost/StatusPort,
  Backend, AuditEvidencePath, SkipHttp and no-clobber ReportPath. JSON contains
  no secrets; required failure exits nonzero. Sensitive paths use HEAD and HTTP
  probes retain only status/header booleans, never cookie values or bodies.
- Production gates require real HTTPS/site/game DNS, appropriate backend,
  source/login/audit identity, TLS cookies/headers, explicit deployment settings
  and operator attestations for firewall, reachability, restore, rotation,
  supervision, recovery, privacy/legal, dependency installation and counts.
  Evidence freshness is seven days, a documented package policy.
- Task 2 validator checks source/module/proto inventory, installed and staged
  executable hashes, Argon costs, scanner identity/hash and each source/test/
  binary audit output hash/result. Actual current login evidence passed locally.
- Linux Nginx/FPM and Windows IIS/FastCGI templates: public docroot, index-only
  PHP execution, static extension policy, TLS/security headers, private backend,
  login URI proxy, body/time bounds and per-IP limits. Private PHP/session/log/
  cache settings and placeholder-only env/evidence examples.
- Dedicated AAC start/stop use the local module. Exact already-owned listener
  adoption is idempotent; unrelated port/process identities fail. Stop verifies
  executable/router/listener/generation twice and retains a process handle
  across Kill to resist PID reuse. Mutex serializes lifecycle operations.
  Batch integration preserves original game/login commands; removes printed
  default administrator password. No launcher was executed.
- Ordered 0005 includes approved-route menu filtering, removed disabled
  recovery/payment/management/guild action links, local-only create-character
  link, private production Twig cache, and narrow integer pagination validation
  for the prior deferred fractional LIMIT issue. Seven runtime files changed,
  fully represented by the patch; no gameplay code changed.
- Operations runbook documents exact future commands, installation/evidence,
  private backup/isolated restore, rollback/Argon compatibility, daily off-host
  backup plus retention/RPO/RTO, supervision, logs, rotation, ports and current
  official otservlist FAQ. No invented listing numeric rules.

## TDD and validation evidence

Initial command:

    Invoke-Pester -Script tools/local-canaryaac/tests/Production.Tests.ps1,tools/local-canaryaac/tests/Lifecycle.Tests.ps1 -PassThru

RED: seven failures before implementation; missing production module/functions
and generation-aware process validation. One missing-function throw assertion
passed vacuously initially; the implemented positive replay/ownership cases
subsequently exercise those real functions. Fixed Pester 3 module-scope fixture
placement and corrected the positive public-domain fixture (reserved example.org
is intentionally rejected).

Navigation RED:

    .tools/php/php.exe -c .tools/php/php.ini tools/local-canaryaac/tests/php/ProductionNavigationTest.php
    RuntimeException: Menu offers disabled route: eventcalendar

GREEN final focused Pester: 8 passed, 0 failed, 0 skipped. Real temporary Git
fixture replays a patch, verifies drift rejection, exports an isolated source
release and asserts no env/vendor/public source exposure. Reparse output fixture
uses a junction within TestDrive. Process tests mock only OS process/listener
queries: correct generation passes; stale PID/router suffix/foreign listener fail.

Final full PHP command:

    Get-ChildItem tools/local-canaryaac/tests/php/*Test.php | ForEach-Object {
      & .tools/php/php.exe -c .tools/php/php.ini $_.FullName
      if($LASTEXITCODE){throw 'PHP test failed'}
    }

Result: 9/9 PASS (AccountAuthentication, AccountCreationValidator,
AccountTransaction, ArgonCompatibility, ProductionNavigation, RouterSecurity,
SignupForm, SqliteRetry, WebSecurity). Existing RouterSecurity symlink capability
SKIP remains on Windows. No live signup/DB writes occurred.

PowerShell AST parsing: PASS for maintained entrypoints/modules. IIS web.config
and server FastCGI fragment: XML parse PASS. Production PHP INI inspection confirms
display_errors=Off, expose_php=Off, cookie_samesite=Lax, cookie_secure=On.
An initial php -r inspection had a shell quoting error; repeated with php -i
and explicit selected settings succeeded. git diff --check found no whitespace
errors (normal Git CRLF checkout warnings only).

Real local command:

    powershell -NoProfile -File tools/local-canaryaac/Test-CanaryAACReadiness.ps1 -Mode Local -ReportPath C:/Users/Marlon/Documents/OT/.tools/task3-local-readiness.json

Exit 0; Ready=true, ProductionReady=false; 25 required checks passed, 0 failed.
Source replay including 0005 passed. Current local router, actual PHP listener
and Task 2 login build/audit identities passed. GET safe pages and HEAD private/
disabled paths passed; cookie values were not printed/stored. Separate GET
inspection confirms rendered login page offers neither recovery nor payment link.

Real Export command was deliberately refused:

    Export-CanaryAACRelease.ps1 -OutputRoot C:/Users/Marlon/Documents/OT/.tools/releases
    Fresh successful lock-bound Composer audit evidence is required...

No actual production release was created: machine-readable current Composer
evidence is missing. The previous Task 2 textual successful audit is not silently
promoted to current evidence. Source-only fixture export passed.

A production -SkipHttp invocation was started before the controller's immediate
handoff request, writing to .tools/task3-production-readiness.json when complete.
Its completion/exit was not consumed at handoff; do not cite it as verified.

## Concerns / review boundaries

- Nginx/PHP-FPM and IIS runtime, TLS, external reachability, firewall, backup
  restoration, secret rotation, supervision and otservlist count audit remain
  target-host/operator gates. XML parsing is not an IIS integration test.
- Windows template currently has global per-IP rate/concurrency restrictions;
  stricter /login limits and ARR header stripping are explicit runbook steps.
  Review these template prerequisites before deployment.
- Release deliberately omits dependencies and cannot launch until isolated locked
  install/audit/platform checks and private configuration are completed.
- Evidence Configuration/ManualGates are operator attestations, not signatures or
  remote filesystem proof. Readiness verifies local staged source/login plus
  safe HTTP; documented manual deployment identity verification remains required.
- Focused Pester suite covers core replay/output/process boundaries but lacks a
  full standalone readiness CLI fixture matrix and full start/stop wrapper mocks.
  Controller requested handoff rather than expanding checks.
- Source reconstruction/validation of this large upstream asset tree is slow
  (roughly a minute or more); it is fail-closed and makes no service changes.
- No Nginx binary/config parser was available/executed. Template syntax/escaping
  must be checked with nginx -t on the target. PHP INI does not itself load OPcache;
  production installation must enable the available extension as documented.

All user NPC/quest/movement/item/send_first_items changes remained unstaged and
untouched. No private env/credentials/backups were read or ACLs changed. No
runtime service restart/stop/start, network publication or live DB write occurred.
Owned files are the tooling/scripts/tests/0005/production templates, runbook,
README, nearest AGENTS and two batch launcher integrations.
