[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Local.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Production.psm1') -Force
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtime = Get-CanaryAACPhysicalRuntime $root
$layout = Get-CanaryAACLayout -RepositoryRoot (Split-Path $runtime -Parent)
foreach ($path in @($layout.PhpPath,$layout.RouterPath,$layout.PidFile,$layout.LogRoot)) { Assert-CanaryAACPlainPath $path }
$mutex = [Threading.Mutex]::new($false, 'Local\CanaryAAC-127.0.0.1-8080')
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); throw 'Another AAC lifecycle operation is in progress.' }
try {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue)
    if ($listeners.Count) {
        if ($listeners.Count -ne 1) { throw 'Port 8080 has multiple listener identities.' }
        $record = Get-CanaryAACProcessRecord $listeners[0].OwningProcess
        if (!(Test-CanaryAACOwnedProcess -Record $record -PhpPath $layout.PhpPath -RouterPath $layout.RouterPath)) { throw 'Port 8080 is owned by an unrelated process.' }
        # Existing exact local service can be adopted without a restart.
        [IO.File]::WriteAllText($layout.PidFile, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-Output 'CanaryAAC already listening at http://127.0.0.1:8080.'
        return
    }
    if (Test-Path -LiteralPath $layout.PidFile) {
        # Never discard an ambiguous legacy PID or a record still naming a process.
        $old = Get-Content -LiteralPath $layout.PidFile -Raw | ConvertFrom-Json
        if (!$old.PSObject.Properties['CreatedUtc']) { throw 'Legacy PID record needs operator inspection; nothing started.' }
        if (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$old.ProcessId)") { throw 'Recorded process still exists without its expected listener.' }
    }
    if (!(Test-Path -LiteralPath $layout.PhpPath) -or !(Test-Path -LiteralPath $layout.RouterPath)) { throw 'Install CanaryAAC before starting it.' }
    New-Item -ItemType Directory -Path $layout.LogRoot -Force | Out-Null
    $stamp = [guid]::NewGuid().ToString('N')
    $arguments = @('-c', ('"' + (Join-Path $layout.PhpRoot 'php.ini') + '"'), '-S', '127.0.0.1:8080', ('"' + $layout.RouterPath + '"'))
    $process = Start-Process -FilePath $layout.PhpPath -ArgumentList $arguments -WorkingDirectory $layout.Checkout -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $layout.LogRoot "$stamp-out.log") -RedirectStandardError (Join-Path $layout.LogRoot "$stamp-error.log")
    $record = Get-CanaryAACProcessRecord $process.Id
    [IO.File]::WriteAllText($layout.PidFile, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Wait-CanaryAACHttp -Uri 'http://127.0.0.1:8080/' -TimeoutSeconds 15
    if (!(Test-CanaryAACOwnedProcess -Record $record -PhpPath $layout.PhpPath -RouterPath $layout.RouterPath)) { throw 'AAC started but ownership verification failed; inspect record and logs.' }
    Write-Output 'CanaryAAC listening at http://127.0.0.1:8080 (development only).'
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
