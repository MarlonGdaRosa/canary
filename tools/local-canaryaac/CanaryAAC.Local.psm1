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
        ComposerPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'composer.phar'))
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

    # Bound arguments so another port or a router with a matching prefix is rejected.
    $listenerPattern = '(?:^|\s)-S\s+127\.0\.0\.1:8080(?=\s|$)'
    $routerPattern = '(?:^|\s)"?' + [regex]::Escape($resolvedRouter) + '"?(?=\s|$)'
    return ($process.CommandLine -match $listenerPattern -and $process.CommandLine -match $routerPattern)
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

Export-ModuleMember -Function Get-CanaryAACLayout, Assert-FileSha256, Test-CanaryAACProcess, Wait-CanaryAACHttp
