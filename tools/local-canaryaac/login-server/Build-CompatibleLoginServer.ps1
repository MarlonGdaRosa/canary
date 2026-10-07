[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\Users\Marlon\Documents\OT\.tools',
    [string]$SourceRoot = '',
    [string]$Go = 'C:\Program Files\Go\bin\go.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$SourceRoot) { $SourceRoot = Join-Path $ToolsRoot 'login-server' }
$ToolsRoot = (Resolve-Path -LiteralPath $ToolsRoot).Path
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$baseRevision = '2612930de4d97123a397f8f2cd0d5f784094af40'
$patch = Join-Path $PSScriptRoot '0001-compatible-passwords.patch'
$safeDirectory = 'safe.directory=' + $SourceRoot.Replace('\', '/')
$head = & git -c $safeDirectory -C $SourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $baseRevision) { throw 'Unexpected login-server base revision; review existing changes before applying.' }
$ErrorActionPreference = 'Continue'
& git -c $safeDirectory -C $SourceRoot apply --reverse --check $patch 2>$null
$reverseExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($reverseExit -ne 0) {
    & git -c $safeDirectory -C $SourceRoot apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Compatibility patch conflicts; existing source edits were preserved.' }
    & git -c $safeDirectory -C $SourceRoot apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Compatibility patch failed.' }
}

$stage = Join-Path $ToolsRoot ('login-server-builds\' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$environmentKeys = @('GOPATH','GOBIN','GOCACHE','GOMODCACHE','GOTMPDIR','GOTOOLCHAIN','TEMP','TMP','PATH')
$previous = @{}
foreach ($key in $environmentKeys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
try {
    $env:GOPATH = Join-Path $ToolsRoot 'go'
    $env:GOBIN = Join-Path $env:GOPATH 'bin'
    $env:GOCACHE = Join-Path $env:GOPATH 'build-cache'
    $env:GOMODCACHE = Join-Path $env:GOPATH 'pkg\mod'
    $env:GOTMPDIR = Join-Path $env:GOPATH 'tmp'
    $env:GOTOOLCHAIN = 'local'
    $env:TEMP = $env:GOTMPDIR
    $env:TMP = $env:GOTMPDIR
    $env:PATH = (Split-Path -Parent $Go) + ';' + $env:PATH
    New-Item -ItemType Directory -Force $env:GOTMPDIR | Out-Null
    $goVersion = & $Go version
    if ($LASTEXITCODE -ne 0 -or $goVersion -ne 'go version go1.27.0 windows/amd64') { throw 'This build evidence requires Go 1.27.0 windows/amd64.' }
    Push-Location $SourceRoot
    try {
        & $Go mod verify
        if ($LASTEXITCODE -ne 0) { throw 'Go module checksum verification failed.' }
        $testPattern = '^(TestCompatibleAccountAuthentication|Test_loginHandlerReturnsSessionFlowVariants|TestLogin|TestBuildLogin|TestBuildConfiguration)'
        & $Go test -mod=readonly ./src/database ./src/api ./src/grpc -run $testPattern -count=1
        if ($LASTEXITCODE -ne 0) { throw 'Login authentication / HTTP-gRPC compatibility tests failed.' }
        $binary = Join-Path $stage 'login-server.exe'
        & $Go build -mod=readonly -trimpath -buildvcs=false -o $binary ./src
        if ($LASTEXITCODE -ne 0) { throw 'Login build failed.' }
        & $Go install golang.org/x/vuln/cmd/govulncheck@v1.8.0
        if ($LASTEXITCODE -ne 0) { throw 'Pinned vulnerability scanner installation failed; audit is incomplete.' }
        $scanner = Join-Path $env:GOBIN 'govulncheck.exe'
        $scannerBuildInfo = & $Go version -m $scanner
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify scanner binary identity; audit is incomplete.' }
        $scannerMetadata = $scannerBuildInfo -join "`n"
        $scannerModule = [regex]::Match($scannerMetadata, '(?m)^\s*mod\s+golang\.org/x/vuln\s+(\S+)\s+(\S+)\s*$')
        if ($scannerMetadata -notmatch '(?m)^\s*path\s+golang\.org/x/vuln/cmd/govulncheck\s*$' -or
            !$scannerModule.Success -or $scannerModule.Groups[1].Value -ne 'v1.8.0' -or
            $scannerMetadata -match '(?m)^\s*=>\s') {
            throw 'Unexpected scanner binary identity; no vulnerability scan was executed.'
        }
        $scans = @(
            @{Name='source'; Arguments=@('-show','verbose','./src/...')},
            @{Name='tests'; Arguments=@('-test','-show','traces','./src/...')},
            @{Name='binary'; Arguments=@('-mode','binary',$binary)}
        )
        $audit = @()
        foreach ($scan in $scans) {
            $arguments = $scan.Arguments
            $output = & $scanner @arguments 2>&1
            $code = $LASTEXITCODE
            $log = Join-Path $stage ($scan.Name + '-govulncheck.txt')
            [IO.File]::WriteAllLines($log, [string[]]$output, [Text.UTF8Encoding]::new($false))
            $audit += [ordered]@{Mode=$scan.Name; ExitCode=$code; OutputFile=$log; OutputSHA256=(Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash}
            Write-Output ($scan.Name + ' govulncheck exit=' + $code)
        }
        $sources = [ordered]@{}
        $files = @('go.mod','go.sum') + @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'src') -File -Recurse | Where-Object { $_.Extension -in @('.go','.proto') } | ForEach-Object { $_.FullName.Substring($SourceRoot.Length + 1).Replace('\','/') })
        foreach ($file in ($files | Sort-Object)) { $sources[$file] = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $file) -Algorithm SHA256).Hash }
        $manifest = [ordered]@{
            SchemaVersion=1; CreatedUtc=[DateTime]::UtcNow.ToString('o'); BaseRevision=$baseRevision
            SourceRoot=$SourceRoot; GoVersion=$goVersion; BuildArguments=@('-mod=readonly','-trimpath','-buildvcs=false','./src')
            PatchFile=$patch; PatchSHA256=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
            SourceFiles=$sources; BinaryPath=$binary; BinarySHA256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
            AuthenticationProfile=@{Argon2='id'; Version=19; MemoryKiB=65536; Iterations=2; Parallelism=2; SaltBytes=16; DigestBytes=32; LegacySHA1=$true; AuthenticationWrites=$false}
            Scanner=@{Module='golang.org/x/vuln'; Version=$scannerModule.Groups[1].Value; ModuleChecksum=$scannerModule.Groups[2].Value;
                IdentityVerified=$true; BinaryPath=$scanner; BuildInfo=$scannerBuildInfo;
                BinarySHA256=(Get-FileHash -LiteralPath $scanner -Algorithm SHA256).Hash; Scans=$audit}
            AuditPassed=(@($audit | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0)
        }
        $manifestPath = Join-Path $stage 'build-manifest.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Output ('Build manifest: ' + $manifestPath)
        if (!$manifest.AuditPassed) { throw 'Source or binary audit failed; see manifest. Production remains blocked.' }
        # This helper stages and verifies only. Service deployment is an explicit separate operation.
    } finally { Pop-Location }
} finally {
    foreach ($key in $environmentKeys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
}
