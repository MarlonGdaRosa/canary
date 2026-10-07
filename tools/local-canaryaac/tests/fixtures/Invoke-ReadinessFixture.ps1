# Test-only OS boundary. The real readiness script, modules, source replay and
# audit validation run unchanged in this child process; no socket/service opens.
param(
    [string]$ReadinessScript, [string]$Mode, [string]$SiteUrl,
    [string]$GameHost, [string]$Backend, [string]$AuditEvidencePath
)
$fixtureRoot = Split-Path (Split-Path (Split-Path $ReadinessScript -Parent) -Parent) -Parent
$fixturePhp = Join-Path $fixtureRoot '.tools\php\php.exe'
$fixtureRouter = Join-Path $fixtureRoot '.tools\canaryaac\router.php'
function global:Get-NetTCPConnection {
    param($State,$LocalPort,$ErrorAction)
    [pscustomobject]@{OwningProcess=1234; LocalAddress='127.0.0.1'; LocalPort=8080; State='Listen'}
}
function global:Get-CimInstance {
    param($ClassName,$Filter,$ErrorAction)
    if ($ClassName -ne 'Win32_Process' -or $Filter -ne 'ProcessId = 1234') { throw 'Unexpected fixture process query.' }
    [pscustomobject]@{
        ProcessId=1234; ExecutablePath=$fixturePhp
        CommandLine=('"'+$fixturePhp+'" -S 127.0.0.1:8080 "'+$fixtureRouter+'"')
        CreationDate=[datetime]'2026-10-07T00:00:00Z'
    }
}
& $ReadinessScript -Mode $Mode -SiteUrl $SiteUrl -GameHost $GameHost -Backend $Backend -AuditEvidencePath $AuditEvidencePath -SkipHttp
exit $LASTEXITCODE
