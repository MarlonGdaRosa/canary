[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Local.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Production.psm1') -Force
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtime = Get-CanaryAACPhysicalRuntime $root
$layout = Get-CanaryAACLayout -RepositoryRoot (Split-Path $runtime -Parent)
foreach ($path in @($layout.PhpPath,$layout.RouterPath,$layout.PidFile)) { Assert-CanaryAACPlainPath $path }
$mutex = [Threading.Mutex]::new($false, 'Local\CanaryAAC-127.0.0.1-8080')
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); throw 'Another AAC lifecycle operation is in progress.' }
try {
    if (!(Test-Path -LiteralPath $layout.PidFile)) {
        if (@(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue).Count) { throw 'Unrecorded listener; inspect ownership first.' }
        Write-Output 'CanaryAAC is already stopped.'
        return
    }
    $record = Get-Content -LiteralPath $layout.PidFile -Raw | ConvertFrom-Json
    if (!$record.PSObject.Properties['CreatedUtc']) { throw 'Legacy PID record cannot authorize termination; run the dedicated start command to validate/adopt the exact listener.' }
    Stop-CanaryAACOwnedProcess -Record $record -PhpPath $layout.PhpPath -RouterPath $layout.RouterPath
    Remove-Item -LiteralPath $layout.PidFile
    Write-Output 'Owned CanaryAAC process stopped; game and login-server were not touched.'
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
