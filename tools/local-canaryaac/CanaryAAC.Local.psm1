Set-StrictMode -Version Latest

function Get-CanaryAACLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    # IsPathRooted alone also accepts C:relative and \relative on Windows.
    if ($RepositoryRoot -notmatch '^(?:[a-zA-Z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))') {
        throw 'RepositoryRoot must be an absolute Windows path.'
    }

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $root '.tools'))
    $checkout = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'canaryaac'))
    $phpRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'php'))
    [pscustomobject] @{
        RepositoryRoot = $root
        RuntimeRoot = $runtimeRoot
        Checkout = $checkout
        PhpRoot = $phpRoot
        PhpPath = [System.IO.Path]::GetFullPath((Join-Path $phpRoot 'php.exe'))
        ComposerPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'composer\composer.phar'))
        RouterPath = [System.IO.Path]::GetFullPath((Join-Path $checkout 'router.php'))
        PidFile = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'canaryaac.pid'))
        LogRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'canaryaac-logs'))
    }
}

function Assert-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Expected)

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path. Expected $Expected; got $actual"
    }
}

function Test-CanaryAACProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ProcessId,
        [Parameter(Mandatory)][string] $PhpPath,
        [Parameter(Mandatory)][string] $RouterPath
    )

    $resolvedPhp = [System.IO.Path]::GetFullPath($PhpPath)
    $resolvedRouter = [System.IO.Path]::GetFullPath($RouterPath)
    try {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    } catch {
        return $false
    }
    if ($null -eq $process -or $process.ProcessId -ne $ProcessId -or
        -not [string]::Equals($process.ExecutablePath, $resolvedPhp, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrEmpty($process.CommandLine)) {
        return $false
    }

    # The local launcher uses whole quoted or unquoted arguments. Reject malformed
    # or mixed quoting rather than interpreting a substring as process identity.
    $argumentPattern = '"[^"\r\n]*"|[^\s"]+'
    if ($process.CommandLine -notmatch ('^\s*(?:' + $argumentPattern + ')(?:\s+(?:' + $argumentPattern + '))*\s*$')) {
        return $false
    }
    $arguments = @([regex]::Matches($process.CommandLine, $argumentPattern) | ForEach-Object {
        $_.Value.Trim('"')
    })
    if ($arguments.Count -lt 4 -or
        -not [string]::Equals($arguments[-1], $resolvedRouter, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    # Parse the supported PHP launcher options before the final router argument.
    # Consume option values so a value such as "-S" is never an actual option.
    $hasListener = $false
    for ($index = 1; $index -lt $arguments.Count - 1; $index++) {
        switch -CaseSensitive ($arguments[$index]) {
            '-n' { continue }
            { $_ -cin @('-c', '-d', '-t', '-S') } {
                $option = $arguments[$index]
                $index++
                if ($index -ge $arguments.Count - 1) { return $false }
                if ($option -ceq '-S') {
                    if ($hasListener -or $arguments[$index] -cne '127.0.0.1:8080') { return $false }
                    $hasListener = $true
                }
            }
            default { return $false }
        }
    }
    return $hasListener
}

function Wait-CanaryAACHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $TimeoutSeconds
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $remaining = $TimeoutSeconds - $timer.Elapsed.TotalSeconds
        try {
            # Invoke-WebRequest exposes only whole-second request timeouts.
            $requestTimeout = [Math]::Max(1, [int][Math]::Ceiling($remaining))
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $requestTimeout -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                return
            }
        } catch {
            # Connection refusal and startup HTTP errors remain retryable until the deadline.
        }
        $remainingMs = ($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000
        if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Min(250, [Math]::Ceiling($remainingMs)))
        }
    }
    throw "CanaryAAC did not become ready at $Uri within $TimeoutSeconds seconds."
}

function Get-CanaryAACProcessRecord {
    param([int]$ProcessId)
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    if (!$process -or !$process.CreationDate) { throw 'Process generation unavailable.' }
    [pscustomobject]@{ProcessId=$ProcessId; CreatedUtc=$process.CreationDate.ToUniversalTime().ToString('o')}
}

function Test-CanaryAACOwnedProcess {
    param([object]$Record, [string]$PhpPath, [string]$RouterPath)
    try {
        if (!$Record -or $Record.ProcessId -lt 1 -or !$Record.CreatedUtc) { return $false }
        if (!(Test-CanaryAACProcess -ProcessId $Record.ProcessId -PhpPath $PhpPath -RouterPath $RouterPath)) { return $false }
        $actual = Get-CanaryAACProcessRecord $Record.ProcessId
        if ($actual.CreatedUtc -cne $Record.CreatedUtc) { return $false }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction Stop)
        return $listeners.Count -eq 1 -and $listeners[0].OwningProcess -eq $Record.ProcessId -and $listeners[0].LocalAddress -ceq '127.0.0.1'
    } catch { return $false }
}

function Stop-CanaryAACOwnedProcess {
    param([object]$Record, [string]$PhpPath, [string]$RouterPath)
    if (!(Test-CanaryAACOwnedProcess -Record $Record -PhpPath $PhpPath -RouterPath $RouterPath)) {
        throw 'AAC process identity, generation or listener mismatch; nothing stopped.'
    }
    # Retain the OS process handle across revalidation, so PID recycling cannot
    # redirect termination to a different process between validation and Kill.
    $process = [Diagnostics.Process]::GetProcessById($Record.ProcessId)
    try {
        $null = $process.Handle
        if ($process.StartTime.ToUniversalTime().ToString('o') -cne $Record.CreatedUtc -or
            !(Test-CanaryAACOwnedProcess -Record $Record -PhpPath $PhpPath -RouterPath $RouterPath)) {
            throw 'AAC identity changed; nothing stopped.'
        }
        $process.Kill()
        if (!$process.WaitForExit(5000)) { throw 'AAC termination timed out; record retained.' }
    } finally { $process.Dispose() }
}

Export-ModuleMember -Function Get-CanaryAACLayout, Assert-FileSha256, Test-CanaryAACProcess, Wait-CanaryAACHttp, Get-CanaryAACProcessRecord, Test-CanaryAACOwnedProcess, Stop-CanaryAACOwnedProcess
