[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Local','Production')][string]$Mode,
    [string]$SiteUrl = 'http://127.0.0.1:8080',
    [string]$GameHost = '',
    [ValidateRange(1,65535)][int]$StatusPort = 7171,
    [ValidateSet('PhpFpm','IisFastCgi','Builtin')][string]$Backend = 'Builtin',
    [string]$AuditEvidencePath = '',
    [switch]$SkipHttp,
    [string]$ReportPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Production.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Local.psm1') -Force
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtime = Get-CanaryAACPhysicalRuntime $root
$checkout = Join-Path $runtime 'canaryaac'
if (!$AuditEvidencePath) { $AuditEvidencePath = Join-Path $runtime 'canaryaac-audit.json' }
$checks = New-Object 'System.Collections.Generic.List[object]'
function Add-Check([string]$Name, [bool]$Passed, [bool]$ProductionOnly, [string]$Requirement) {
    $checks.Add([pscustomobject]@{Name=$Name; Passed=$Passed; Required=(!$ProductionOnly -or $Mode -eq 'Production'); Requirement=$Requirement})
}

# HTTP response bodies/cookie values are never retained or emitted. Redirects are
# not followed, preventing a misconfigured endpoint from silently changing scope.
function Get-HeaderCheck([uri]$Uri, [string]$Method) {
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method; $request.AllowAutoRedirect = $false
    $request.Timeout = 5000; $request.ReadWriteTimeout = 5000
    $request.Proxy = $null
    $response = $null
    try { $response = $request.GetResponse() }
    catch [Net.WebException] { $response = $_.Exception.Response; if (!$response) { throw 'HTTP connection failed.' } }
    try {
        $cookie = [string]$response.Headers['Set-Cookie']
        [pscustomobject]@{
            Status=[int]$response.StatusCode
            Cookie=($cookie -match '(?i);\s*httponly' -and $cookie -match '(?i);\s*samesite=lax')
            Secure=($cookie -match '(?i);\s*secure')
            Headers=($response.Headers['X-Content-Type-Options'] -eq 'nosniff' -and $response.Headers['X-Frame-Options'] -eq 'DENY' -and
                $response.Headers['Referrer-Policy'] -eq 'strict-origin-when-cross-origin' -and $response.Headers['Content-Security-Policy'] -match "object-src 'none'")
            Hsts=($response.Headers['Strict-Transport-Security'] -match 'max-age=[1-9][0-9]+')
        }
    } finally { if ($response) { $response.Close() } }
}

$sourceOkay = $false
try {
    $lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('canaryaac-readiness-' + [guid]::NewGuid().ToString('N'))
    $identity = Import-CanaryAACSource -Checkout $checkout -BaseCommit $lock.canaryaac.commit -PatchRoot (Join-Path $PSScriptRoot 'patches') -Destination $stage
    $sourceOkay = Assert-CanaryAACSource -Checkout $checkout -ExpectedRoot $stage
} catch { $sourceOkay = $false }
Add-Check 'SourceReplay' $sourceOkay $false 'Exact pinned source plus every ordered patch; no unrecorded source drift.'
$routerOkay = $false
try { $routerOkay = (Get-FileHash (Join-Path $checkout 'router.php')).Hash -eq (Get-FileHash (Join-Path $PSScriptRoot 'config\router.php')).Hash } catch {}
Add-Check 'LocalRouter' ($Mode -eq 'Production' -or $routerOkay) $false 'Maintained local router matches runtime.'

$auditOkay = Test-CanaryAACAudit -Path $AuditEvidencePath -Checkout $checkout
Add-Check 'ComposerAudit' $auditOkay $true 'Successful locked Composer validate/audit, lock/output hashes, age at most seven days.'
$evidence = $null
try { Assert-CanaryAACPlainPath $AuditEvidencePath; $evidence = Get-Content -LiteralPath $AuditEvidencePath -Raw | ConvertFrom-Json } catch {}
$manifestPath = ''
try { $manifestPath = $evidence.LoginManifestPath } catch {}
if (!$manifestPath -and $Mode -eq 'Local') {
    $manifestPath = Join-Path $root '.superpowers\sdd\2026-10-06-canaryaac-production-preparation\task-2-build-manifest.json'
}
$loginOkay = Test-CanaryAACLoginEvidence -ManifestPath $manifestPath -RuntimeRoot $runtime -PatchPath (Join-Path $PSScriptRoot 'login-server\0001-compatible-passwords.patch')
Add-Check 'LoginCompatibilityAudit' $loginOkay $true 'Current compact-Argon source, active executable on disk, pinned scanner and source/test/binary audit hashes match.'
Add-Check 'HttpsPublicSite' (Test-CanaryAACPublicUrl $SiteUrl) $true 'Real HTTPS domain; no loopback, placeholder, IP literal or embedded credentials.'
Add-Check 'PublicGameHost' (Test-CanaryAACPublicHost $GameHost) $true 'Explicit public game DNS identity; external reachability is separately attested.'
Add-Check 'ProductionBackend' ($Backend -in @('PhpFpm','IisFastCgi')) $true 'Dedicated PHP-FPM or IIS FastCGI; PHP built-in is local only.'

$uri = $null
$validUri = [uri]::TryCreate($SiteUrl,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https') -and !$uri.UserInfo -and !$uri.Query -and !$uri.Fragment -and $uri.AbsolutePath -eq '/'
$localAddress = $validUri -and $uri.IsLoopback
if ($Mode -eq 'Local') { Add-Check 'LocalScope' $localAddress $false 'Local mode checks a loopback website.' }
if ($localAddress) {
    $owned = $false
    try {
        $listener = @(Get-NetTCPConnection -State Listen -LocalPort $uri.Port -ErrorAction Stop)
        $owned = $listener.Count -eq 1 -and (Test-CanaryAACProcess -ProcessId $listener[0].OwningProcess -PhpPath (Join-Path $runtime 'php\php.exe') -RouterPath (Join-Path $checkout 'router.php'))
    } catch {}
    Add-Check 'ObservedLocalBuiltin' ($Mode -eq 'Local' -and $owned -and $Backend -eq 'Builtin') $false 'Observed php -S is a local development backend only.'
}
if ($SkipHttp -or !$validUri) {
    Add-Check 'HttpProbes' $false $true 'HTTP checks must run against deployed HTTPS before production approval.'
} else {
    foreach ($path in @('/','/createaccount','/account/login','/downloads','/community/highscores')) {
        try {
            $probe = Get-HeaderCheck ([uri]::new($uri,$path)) 'GET'
            Add-Check ("Page:$path") ($probe.Status -eq 200) $false 'Safe public page returns 200 without redirects.'
            Add-Check ("Headers:$path") ($probe.Headers -and $probe.Cookie) $false 'Security headers and HttpOnly/SameSite=Lax session cookie present; values discarded.'
            Add-Check ("TlsSession:$path") ($probe.Secure -and $probe.Hsts) $true 'Secure session cookie and HSTS observed on HTTPS.'
        } catch { Add-Check ("Page:$path") $false $false 'Safe HTTP probe failed.' }
    }
    foreach ($path in @('/.env','/.git/HEAD','/composer.lock','/canaryaac.sql','/vendor/composer/installed.json','/app/Utils/WebSecurity.php','/resources/view/pages/base.html.twig','/index.php','/admin','/payment','/account/lostaccount')) {
        $denied = $false
        try { $probe = Get-HeaderCheck ([uri]::new($uri,$path)) 'HEAD'; $denied = $probe.Status -in @(403,404) } catch {}
        Add-Check ("Private:$path") $denied $false 'Sensitive or disabled path denied via HEAD; no body read.'
    }
}

$configOkay = $false
try {
    $config = $evidence.Configuration
    $configOkay = $auditOkay -and $config.SiteUrl.TrimEnd('/') -ceq $SiteUrl.TrimEnd('/') -and
        $config.GameHost -ceq $GameHost -and $config.StatusPort -eq $StatusPort -and $config.Backend -ceq $Backend -and
        $config.AppEnv -ceq 'production' -and $config.Debug -eq $false -and $config.StrictSessions -eq $true -and
        $config.PrivateState -eq $true -and $config.PrivateCache -eq $true -and $config.PublicDocrootOnly -eq $true -and
        $config.Admin -eq $false -and $config.Payments -eq $false -and $config.Recovery -eq $false -and
        $config.Uploads -eq $false -and $config.ExternalIntegrations -eq $false
} catch {}
Add-Check 'DeploymentConfiguration' $configOkay $true 'Fresh operator evidence binds reviewed production settings to this site/backend/game/status identity; no secrets are inspected.'
foreach ($gate in @('DomainTls','ExternalReachability','FirewallPrivateServices','BackupRestore','SecretRotation','SupervisionMonitoring','MailRecoveryPolicy','LegalPrivacy','OnlinePeakCounts','DependencyInstallVerified')) {
    $passed = $false
    try { $passed = $auditOkay -and $configOkay -and $evidence.ManualGates.$gate -eq $true } catch {}
    Add-Check ("Manual:$gate") $passed $true 'Operator must record a completed deployment check; not inferred from local success.'
}
$failed = @($checks | Where-Object { $_.Required -and !$_.Passed })
$report = [ordered]@{SchemaVersion=1; Mode=$Mode; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Ready=($failed.Count -eq 0);
    ProductionReady=($Mode -eq 'Production' -and $failed.Count -eq 0); Checks=$checks.ToArray();
    ProductionBlockers=@($checks | Where-Object { !$_.Passed } | ForEach-Object { $_.Name })}
$json = $report | ConvertTo-Json -Depth 7
if ($ReportPath) {
    Assert-CanaryAACPlainPath $ReportPath
    $stream = [IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
Write-Output $json
if ($failed.Count) { exit 1 }
