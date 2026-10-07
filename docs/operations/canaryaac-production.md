# CanaryAAC production preparation

This package prepares a future deployment. It does not publish the current
http://127.0.0.1:8080 website, configure DNS/certificates/firewalls/public binds,
or register with otservlist. PHP's built-in server is development-only
([PHP documentation](https://www.php.net/manual/en/features.commandline.webserver.php)).

## Local operation

Run from the repository in Windows PowerShell 5.1:

~~~powershell
powershell -NoProfile -File tools/local-canaryaac/Test-CanaryAACReadiness.ps1 -Mode Local
powershell -NoProfile -File tools/local-canaryaac/Start-LocalCanaryAAC.ps1
powershell -NoProfile -File tools/local-canaryaac/Stop-LocalCanaryAAC.ps1
~~~

Dedicated AAC commands never manage game/login. Start validates/adopts an exact
existing PHP executable/router/listener without restart. Stop requires a JSON
generation record, router arguments, listener ownership and a retained OS process
handle. A legacy integer PID cannot authorize stop; dedicated Start can validate
and adopt the exact listener. Foreign/stale records require inspection, never a
blind PID kill. Failed launch retains its record/logs under .tools/canaryaac-logs.

Batch launchers also call these commands. Their existing .tools/start-local.ps1
may restart game/login: use dedicated AAC commands when only the website needs
attention. The built-in server offers no production supervision guarantee.

## Readiness and evidence

Local mode can exit 0 while ProductionReady=false; production blockers are
explicit. SkipHttp is diagnostic and blocks production. ReportPath creates a
new file only. Safe page probes discard bodies/cookie values; sensitive paths use
HEAD. Source identity is reconstructed from the exact pin and every ordered
patch in an isolated temporary repository; text comparison normalizes CRLF only.
The sole known ignored animoutfit.php residue is tolerated only at its exact
path/hash and never exported. Unknown source drift fails. Private .env is never
read/diffed/hashed. Secret-free reconstruction trees are retained for inspection.

Audits expire after seven days (this package's operational policy). Composer
validate/audit must succeed and bind the current lock/output SHA256. Missing,
failed, future-dated or stale evidence fails. Login evidence binds the Task 2
base/patch, complete Go/proto/module inventory, built and installed executable,
Argon profile, observed pinned scanner and source/test/binary audit output hashes.
SHA1-only compatibility is insufficient. No readiness check restarts services.

Copy production/audit-evidence.example.json to the physical
.tools/canaryaac-audit.json. This is nonsecret operator evidence, not a signature:
record actual results, UTC timestamp and hashes, never invented success values.
Run with the pinned PHP/Composer; do not update dependencies during packaging:

~~~powershell
$runtime = 'C:\Users\Marlon\Documents\OT\.tools'
$php = Join-Path $runtime 'php\php.exe'
$composer = Join-Path $runtime 'composer\composer.phar'
Push-Location (Join-Path $runtime 'canaryaac')
try {
  & $php -c (Join-Path $runtime 'php\php.ini') $composer validate --strict --no-plugins
  if ($LASTEXITCODE) { throw 'Composer validation failed' }
  & $php -c (Join-Path $runtime 'php\php.ini') $composer audit --locked --no-dev --abandoned=report --no-plugins --format=json
  if ($LASTEXITCODE) { throw 'Composer audit failed or incomplete' }
  Get-FileHash composer.lock -Algorithm SHA256
} finally { Pop-Location }
~~~

Capture audit JSON to a NEW private file using Out-File -Encoding utf8 -NoClobber,
record its SHA256 and the native exit code immediately after Composer. Never
include auth configuration or environment dumps. LoginManifestPath references
the actual maintained helper's build-manifest.json. Refresh when expired:

~~~powershell
& tools/local-canaryaac/login-server/Build-CompatibleLoginServer.ps1
& tools/local-canaryaac/Export-CanaryAACRelease.ps1 -OutputRoot 'C:\Users\Marlon\Documents\OT\.tools\releases'
~~~

Exporter requires both audits, verifies source drift and creates a fresh GUID
child only. Other output roots, reparse paths, relative paths and alternate
streams fail. Existing runtime is preserved. Source releases contain approved
public resources, composer.lock, GPL LICENSE and file/patch SHA256 manifests;
preserve all source copyright notices. The repository GPL text matches the AAC
Composer GPL-3.0-or-later declaration.

Release is explicitly Deployable=false, Dependencies=NotInstalled. No .env,
.git, vendor, generated caches/logs/state, dumps, uploads, node_modules or
executables are copied. In an isolated staging copy install locked dependencies:

~~~text
composer install --no-dev --prefer-dist --no-interaction --no-plugins --no-scripts --optimize-autoloader
composer validate --strict --no-plugins
composer audit --locked --no-dev --abandoned=report --no-plugins --format=json
composer check-platform-reqs --no-dev
~~~

Use production PHP; fail on nonzero results. Preserve actual outputs, lock hash,
installed package inventory and source-release manifest hash privately. Never
copy development vendor or call the source-only manifest a clean installation.
Supply private secrets only after export; never add their hashes to manifests.

## Deployment templates

Replace every REPLACE_* key/example.invalid. Put production.env.example values
in RELEASE/.env outside public with service-only read permissions. Use unique
least-privilege database credentials, APP_ENV=production and DEV_MODE=false.
SECURITY_STATE_DIR and VIEW_CACHE_DIR must be private writable directories outside
resources/public. Source/assets are read-only. Enable PDO MySQL, mbstring, curl,
gd, openssl, sodium, XML, fileinfo and OPcache; validate platform requirements.

The route guard unconditionally disables admin/payment/recovery/upload/unaudited
API routes. FEATURE_* flags document policy; changing them cannot enable routes.
Configured 2FA verification remains enforced. SMTP/Discord/payment credentials
are absent. Owner must supply support contact, identity-checked manual recovery
policy, legal terms and privacy/retention information before launch.

Linux: use nginx.conf inside http {}, php-fpm.conf as a dedicated pool and
production/php.ini for that PHP instance. Point root at the chosen release's
public directory. Provision service identity/private paths/certificates and
Nginx socket permissions. Validate on the target before enabling traffic:

~~~sh
php-fpm -t
nginx -t
php --ini
php -m
~~~

The php-fpm command varies by distribution. Supervise Nginx/FPM with OS services,
boot start and bounded restart/backoff. OPcache timestamp validation is off:
reload the pool after an approved release switch. Only public/index.php executes;
the socket stays private and static files require the directory/extension policy.

Windows: install CGI/FastCGI, URL Rewrite 2, ARR and Dynamic IP Restrictions.
Site physicalPath MUST be RELEASE\public. Register iis-fastcgi.config at server
scope, enable ARR proxy with a 15-second timeout, install HTTPS binding and copy
web.config only to public. Convert private PHP paths to Windows ACL-protected
paths; set the dedicated PHPRC. Disable inherited wildcard PHP handlers/WebDAV.
Use a dedicated application pool identity with bounded recycle/recovery:

~~~powershell
& "$env:windir\system32\inetsrv\appcmd.exe" list config 'REPLACE_SITE/' /section:system.webServer/handlers
& "$env:windir\system32\inetsrv\appcmd.exe" list config 'REPLACE_SITE/' /section:system.webServer/rewrite
& 'C:\REPLACE_PHP\php-cgi.exe' -v
~~~

XML parsing does not validate actual IIS rewrite behavior. The template supplies
global per-IP burst/concurrency limits; configure and verify a stricter /login
limit at site/location or edge. ARR must strip client forwarding headers. PHP
uses REMOTE_ADDR, never arbitrary X-Forwarded-For. For an edge proxy, trust only
explicit known addresses and validate real-IP restoration. The Go limiter may
see one proxy address; verify expected aggregate volume and edge limiting.

Both backends proxy exact POST /login to private 127.0.0.1:8088/login, preserving
URI. This differs from website /account/login.

| Surface | Port/purpose |
| --- | --- |
| Website/client login proxy | HTTPS 443; HTTP 80 redirects |
| Game | 7172, deliberately announced game host |
| Status | 7171, deliberately enabled external status |
| Private only | DB 3306, login HTTP 8088, gRPC 9090, PHP-FPM/FastCGI |

Validate firewall and actual server/client announced addresses from outside the
LAN. A configuration template does not authorize exposing private service ports.

## Backup, restore, rollback and operation

Before any schema/release switch use a dedicated backup account and a private
defaults-extra-file (never password arguments). Example future Linux commands:

~~~sh
umask 077
mariadb-dump --defaults-extra-file=/etc/canaryaac/backup.cnf --single-transaction --routines --triggers --events REPLACE_DB > /private/backups/REPLACE_UNIQUE_UTC.sql
mariadb --defaults-extra-file=/etc/canaryaac/isolated-restore.cnf REPLACE_ISOLATED_DB < /private/backups/REPLACE_UNIQUE_UTC.sql
~~~

First verify the unique backup destination does not exist. Restore only on an
isolated host/schema with disposable credentials. Encrypt and copy backups
off-host daily; separately protect configuration/game state. Owner must choose
retention, RPO, RTO and key custody. Rehearse restore, verify checksum and
account/player relationships, run synthetic signup/login there and record timing.
Never use live initialization/restoration as a readiness test.

Keep prior immutable release/login binary and matching schema/backup metadata.
Rollback must remain compatible with current DB and compact Argon credentials;
SHA1-only login breaks new accounts. Never downgrade hashes. Schema restore
requires downtime and reconciliation of post-backup writes. After approved
release-pointer changes, recycle workers/OPcache and recheck safe pages.

Rotate historical/default administrator, DB, management and integration
credentials before public launch. Preserve least privilege/private ACLs. Never
log password/hash/cookie/session values or login request bodies. Nginx access
format omits URI/query/headers/body. Configure IIS W3C fields to Date,Time,
ClientIP,Method,HttpStatus,TimeTaken only; disable request-body traces and audit
error-log URI/query leakage. Define private log retention/rotation.

Monitor health, HTTP errors/latency, auth-limit failures, worker restarts,
resource saturation, disk, backup age, certificate expiry and game/login
reachability. Alert on failed scans/backups and before certificate expiry.
Record supervision/recovery tests and responsible contacts.

## Final gate and listing

Complete Configuration and ManualGates only after validation. They are explicit
operator attestations; the script does not silently check firewall, renewal,
restore or a remote filesystem. Bind site/game/status/backend to this invocation:

~~~powershell
powershell -NoProfile -File tools/local-canaryaac/Test-CanaryAACReadiness.ps1 -Mode Production -SiteUrl https://REPLACE_REAL_DOMAIN -GameHost REPLACE_GAME_DOMAIN -StatusPort 7171 -Backend PhpFpm -AuditEvidencePath 'C:\PRIVATE_EVIDENCE\canaryaac-audit.json' -ReportPath 'C:\PRIVATE_EVIDENCE\readiness-UNIQUE_UTC.json'
~~~

Use IisFastCgi for Windows. Require exit 0 and ProductionReady=true. HTTPS,
Nginx/IIS runtime and external/manual requirements remain unvalidated during
preparation.

Otservlist provides advertising/discovery, not hosting. Recheck the
[official FAQ](https://otservlist.org/faq) before registration: false online,
record/uptime information, aggregating multiple servers and counting players
who quit are prohibited. Compare website online/peak counts, status output and
actual eligible sessions. Resolve trainers/multiple-connections against current
rules and record evidence before OnlinePeakCounts=true. This package invents no
numeric listing rules and does not register or contact the listing.

Primary configuration references:
[Nginx FastCGI](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html),
[IIS FastCGI](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/fastcgi/),
[IIS filtering/rewrite](https://learn.microsoft.com/en-gb/iis/extensions/url-rewrite-module/iis-request-filtering-and-url-rewriting).
