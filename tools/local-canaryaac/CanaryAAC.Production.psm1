Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CanaryAACPlainPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'An absolute local Windows path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Substring(2).Contains(':')) { throw 'Alternate data streams are forbidden.' }
    $current = $full
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse paths are forbidden.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Get-CanaryAACPhysicalRuntime {
    param([string]$RepositoryRoot)
    $runtime = Join-Path $RepositoryRoot '.tools'
    $item = Get-Item -LiteralPath $runtime -Force
    # Authenticate the established worktree junction using Git's common directory.
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $common = & git -C $RepositoryRoot rev-parse --path-format=absolute --git-common-dir
        if ($LASTEXITCODE) { throw 'Cannot resolve the workspace identity.' }
        $allowed = Join-Path (Split-Path $common -Parent) '.tools'
        if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or
            [IO.Path]::GetFullPath($item.Target[0]) -ine [IO.Path]::GetFullPath($allowed)) { throw 'Unapproved runtime mapping.' }
        $runtime = $allowed
    }
    Assert-CanaryAACPlainPath $runtime
    return [IO.Path]::GetFullPath($runtime)
}

function Assert-CanaryAACReleaseRoot {
    param([string]$RuntimeRoot, [string]$OutputRoot)
    Assert-CanaryAACPlainPath $RuntimeRoot
    Assert-CanaryAACPlainPath $OutputRoot
    if ([IO.Path]::GetFullPath($OutputRoot).TrimEnd('\') -ine (Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'releases')) {
        throw 'OutputRoot must be exactly the physical .tools/releases directory.'
    }
}

function Test-CanaryAACSourcePath {
    param([string]$Path)
    if ($Path -match '[\\:\x00-\x1f]' -or @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_.StartsWith('.') }).Count) { return $false }
    if ($Path -match '(?i)(?:^|/)(?:vendor|node_modules|cache|logs?|upload|generated-exe|sessions|limits)(?:/|$)' -or
        $Path -match '(?i)\.(?:env|sql|bak|old|log|ini|exe|dll|zip|gz)$') { return $false }
    return $Path -match '^(?:app/|includes/|routes/|resources/|public/|index\.php$|composer\.(?:json|lock)$|LICENSE$)'
}

function Test-CanaryAACAssetPath {
    param([string]$Path)
    return (Test-CanaryAACSourcePath $Path) -and
        $Path -cmatch '^resources/(?:base|bootstrap|canary|icons|images|javascripts|styles)/' -and
        $Path -notmatch '(?i)\.(?:php\d*|phtml|phar|sql|env|ini|lock|twig|bak|old|log)(?:\.|$)' -and
        $Path -match '(?i)\.(?:css|js|png|jpe?g|gif|svg|webp|ico|woff2?|ttf|eot)$'
}

function Get-CanaryAACPlainFiles {
    param([string]$Root)
    Assert-CanaryAACPlainPath $Root
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry in source or release.' }
            if ($item.Name -ceq '.git') { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}

function Import-CanaryAACSource {
    [CmdletBinding()]
    param([string]$Checkout, [string]$BaseCommit, [string]$PatchRoot, [string]$Destination)
    Assert-CanaryAACPlainPath $Checkout
    Assert-CanaryAACPlainPath $PatchRoot
    Assert-CanaryAACPlainPath $Destination
    if (Test-Path -LiteralPath $Destination) { throw 'Replay destination must be fresh.' }
    if ($BaseCommit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid base revision.' }
    $head = & git -c "safe.directory=$Checkout" -C $Checkout rev-parse HEAD
    if ($LASTEXITCODE -or $head -cne $BaseCommit) { throw 'Source base revision mismatch.' }
    # Inspect names/modes only. Never export or read upstream's tracked .env.
    $tree = @(& git -c "safe.directory=$Checkout" -C $Checkout ls-tree -r $BaseCommit)
    if ($LASTEXITCODE) { throw 'Cannot enumerate approved source.' }
    $tops = @()
    foreach ($line in $tree) {
        if ($line -notmatch '^([0-9]+) blob [a-f0-9]+\t(.+)$') { continue }
        $mode = $Matches[1]; $name = $Matches[2]
        if (Test-CanaryAACSourcePath $name) {
            if ($mode -notin @('100644','100755')) { throw 'Source links are forbidden.' }
            $tops += $name.Split('/')[0]
        }
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    & git -C $Destination init --quiet
    if ($LASTEXITCODE) { throw 'Cannot isolate patch replay from parent Git state.' }
    $archive = "$Destination.zip"
    if (Test-Path -LiteralPath $archive) { throw 'Replay archive collision.' }
    & git -c "safe.directory=$Checkout" -C $Checkout archive --format=zip "--output=$archive" $BaseCommit -- @($tops | Sort-Object -Unique)
    if ($LASTEXITCODE) { throw 'Source archive failed.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    $seen = @{}
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or !(Test-CanaryAACSourcePath $name)) { continue }
            if ($seen.ContainsKey($name)) { throw 'Duplicate source archive entry.' }
            $seen[$name] = $true
            $path = Join-Path $Destination $name
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
        }
    } finally { $zip.Dispose(); Remove-Item -LiteralPath $archive }
    $records = @()
    foreach ($patch in @(Get-ChildItem -LiteralPath $PatchRoot -File -Filter '*.patch' | Sort-Object Name)) {
        if ($patch.Name -notmatch '^\d{4}-.+\.patch$') { throw 'Ordered patch name required.' }
        Assert-CanaryAACPlainPath $patch.FullName
        $hash = (Get-FileHash -LiteralPath $patch.FullName -Algorithm SHA256).Hash
        $stats = @(& git apply --numstat -- $patch.FullName)
        if ($LASTEXITCODE -or !$stats.Count) { throw 'Invalid or empty source patch.' }
        foreach ($stat in $stats) {
            $parts = $stat -split '\t', 3
            if ($parts.Count -ne 3 -or !(Test-CanaryAACSourcePath $parts[2])) { throw 'Patch touches an excluded or unsafe path.' }
        }
        Push-Location $Destination
        try {
            & git apply --check -- $patch.FullName
            if ($LASTEXITCODE) { throw 'Patch replay check failed.' }
            & git apply -- $patch.FullName
            if ($LASTEXITCODE) { throw 'Patch replay failed.' }
        } finally { Pop-Location }
        if ((Get-FileHash -LiteralPath $patch.FullName -Algorithm SHA256).Hash -ne $hash) { throw 'Patch changed during replay.' }
        $records += [ordered]@{Name=$patch.Name; SHA256=$hash}
    }
    foreach ($file in @(Get-CanaryAACPlainFiles $Destination)) {
        $relative = $file.FullName.Substring($Destination.TrimEnd('\').Length+1).Replace('\','/')
        if (!(Test-CanaryAACSourcePath $relative) -or ($relative.StartsWith('public/') -and $relative -cne 'public/index.php')) { throw 'Unexpected patched source path.' }
    }
    return [pscustomobject]@{BaseCommit=$BaseCommit; Patches=$records}
}

function Assert-CanaryAACSource {
    param([string]$Checkout, [string]$ExpectedRoot)
    $expected = @{}
    foreach ($file in @(Get-CanaryAACPlainFiles $ExpectedRoot)) {
        $relative = $file.FullName.Substring($ExpectedRoot.TrimEnd('\').Length+1).Replace('\','/')
        $expected[$relative] = $true
        $actual = Join-Path $Checkout $relative
        Assert-CanaryAACPlainPath $actual
        if (!(Test-Path -LiteralPath $actual -PathType Leaf)) { throw 'Missing runtime source file.' }
        # Normalize Git's CRLF checkout convention only for text types.
        if ($relative -match '\.(?:php|twig|json|lock|css|js|html|txt|md|svg|xml)$') {
            if (([IO.File]::ReadAllText($file.FullName) -replace '\r\n', [string][char]10) -cne ([IO.File]::ReadAllText($actual) -replace '\r\n', [string][char]10)) { throw "Source drift: $relative" }
        } elseif ((Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) { throw "Source drift: $relative" }
    }
    foreach ($top in @('app','includes','routes','resources','public')) {
        $path = Join-Path $Checkout $top
        if (!(Test-Path -LiteralPath $path)) { continue }
        foreach ($file in @(Get-CanaryAACPlainFiles $path)) {
            $relative = $file.FullName.Substring($Checkout.TrimEnd('\').Length+1).Replace('\','/')
            if ($relative -ceq 'resources/images/charactertrade/outfits/animoutfit.php' -and
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ceq '2D1ED23B26803CDA4977A6FE8C461954320706899990F568DAB3115E9D7A45CC') {
                # Task 1 documented inert residue. Both callers use transparent.svg.
                # Router denies this path; runtime files never feed the exporter.
                continue
            }
            if ((Test-CanaryAACSourcePath $relative) -and !$expected.ContainsKey($relative)) { throw "Unrecorded runtime source: $relative" }
        }
    }
    return $true
}

function New-CanaryAACSourceRelease {
    param([string]$ExpectedRoot, [string]$OutputRoot, [object]$Identity, [string]$LicensePath)
    Assert-CanaryAACPlainPath $OutputRoot
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $release = Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $release -ErrorAction Stop | Out-Null
    $files = @()
    foreach ($file in @(Get-CanaryAACPlainFiles $ExpectedRoot)) {
        $relative = $file.FullName.Substring($ExpectedRoot.TrimEnd('\').Length+1).Replace('\','/')
        if (!(Test-CanaryAACSourcePath $relative)) { throw 'Unapproved release file.' }
        $targets = @($relative)
        if (Test-CanaryAACAssetPath $relative) { $targets += 'public/' + $relative }
        foreach ($target in $targets) {
            $destination = Join-Path $release $target
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            [IO.File]::Copy($file.FullName, $destination, $false)
            $files += [ordered]@{Path=$target; SHA256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
        }
    }
    if (!(Test-Path -LiteralPath (Join-Path $release 'LICENSE'))) {
        Copy-Item -LiteralPath $LicensePath -Destination (Join-Path $release 'LICENSE')
        $files += [ordered]@{Path='LICENSE'; SHA256=(Get-FileHash -LiteralPath (Join-Path $release 'LICENSE') -Algorithm SHA256).Hash}
    }
    $manifest = [ordered]@{SchemaVersion=1; CreatedUtc=[DateTime]::UtcNow.ToString('o'); BaseCommit=$Identity.BaseCommit;
        Patches=$Identity.Patches; Dependencies='NotInstalled'; Deployable=$false;
        ComposerLockSHA256=(Get-FileHash -LiteralPath (Join-Path $release 'composer.lock') -Algorithm SHA256).Hash;
        Files=@($files | Sort-Object Path)}
    [IO.File]::WriteAllText((Join-Path $release 'release-manifest.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return $release
}

function Test-CanaryAACPublicHost {
    param([AllowEmptyString()][string]$Name)
    if (!$Name -or $Name -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])$' -or !$Name.Contains('.') -or
        $Name -match '(?i)(?:localhost|replace|placeholder)|(?:^|\.)example\.(?:com|net|org)$|\.(?:invalid|local|test|internal)$') { return $false }
    $address = $null
    if ([Net.IPAddress]::TryParse($Name,[ref]$address)) { return $false }
    return $true
}

function Test-CanaryAACPublicUrl {
    param([string]$Value)
    $uri = $null
    return [uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -eq 'https' -and
        (Test-CanaryAACPublicHost $uri.DnsSafeHost) -and !$uri.UserInfo -and !$uri.Query -and !$uri.Fragment -and $uri.AbsolutePath -eq '/'
}

function Test-CanaryAACAudit {
    param([string]$Path, [string]$Checkout)
    try {
        Assert-CanaryAACPlainPath $Path
        $audit = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($audit.CreatedUtc).ToUniversalTime()).TotalHours
        if ($audit.SchemaVersion -ne 1 -or $age -lt 0 -or $age -gt 168 -or $audit.Composer.ExitCode -ne 0 -or
            $audit.Composer.ValidateExitCode -ne 0 -or $audit.Composer.LockSHA256 -ne (Get-FileHash -LiteralPath (Join-Path $Checkout 'composer.lock') -Algorithm SHA256).Hash) { return $false }
        Assert-CanaryAACPlainPath $audit.Composer.OutputFile
        return (Get-FileHash -LiteralPath $audit.Composer.OutputFile -Algorithm SHA256).Hash -eq $audit.Composer.OutputSHA256
    } catch { return $false }
}

function Test-CanaryAACLoginEvidence {
    param([string]$ManifestPath, [string]$RuntimeRoot, [string]$PatchPath)
    try {
        Assert-CanaryAACPlainPath $ManifestPath
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($manifest.CreatedUtc).ToUniversalTime()).TotalHours
        $source = Join-Path $RuntimeRoot 'login-server'
        Assert-CanaryAACPlainPath $source
        if ($manifest.SchemaVersion -ne 1 -or $age -lt 0 -or $age -gt 168 -or $manifest.AuditPassed -ne $true -or
            $manifest.BaseRevision -ne '2612930de4d97123a397f8f2cd0d5f784094af40' -or
            $manifest.PatchSHA256 -ne (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash -or
            $manifest.AuthenticationProfile.Argon2 -cne 'id' -or $manifest.AuthenticationProfile.MemoryKiB -ne 65536 -or
            $manifest.AuthenticationProfile.Iterations -ne 2 -or $manifest.AuthenticationProfile.Parallelism -ne 2 -or
            $manifest.AuthenticationProfile.AuthenticationWrites -ne $false -or $manifest.Scanner.IdentityVerified -ne $true -or
            $manifest.Scanner.Module -cne 'golang.org/x/vuln' -or $manifest.Scanner.Version -cne 'v1.8.0') { return $false }
        $head = & git -c "safe.directory=$source" -C $source rev-parse HEAD
        if ($LASTEXITCODE -or $head -ne $manifest.BaseRevision) { return $false }
        $actualNames = @('go.mod','go.sum') + @(Get-CanaryAACPlainFiles (Join-Path $source 'src') | Where-Object { $_.Extension -in @('.go','.proto') } | ForEach-Object { $_.FullName.Substring($source.Length+1).Replace('\','/') })
        $recordedNames = @($manifest.SourceFiles.PSObject.Properties.Name)
        if (Compare-Object ($actualNames | Sort-Object) ($recordedNames | Sort-Object)) { return $false }
        foreach ($name in $actualNames) {
            if ((Get-FileHash -LiteralPath (Join-Path $source $name) -Algorithm SHA256).Hash -ne $manifest.SourceFiles.$name) { return $false }
        }
        foreach ($binary in @($manifest.BinaryPath, (Join-Path $source 'login-server.exe'))) {
            Assert-CanaryAACPlainPath $binary
            if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ne $manifest.BinarySHA256) { return $false }
        }
        Assert-CanaryAACPlainPath $manifest.Scanner.BinaryPath
        if ((Get-FileHash -LiteralPath $manifest.Scanner.BinaryPath -Algorithm SHA256).Hash -ne $manifest.Scanner.BinarySHA256) { return $false }
        if (@($manifest.Scanner.Scans).Count -ne 3) { return $false }
        foreach ($mode in @('source','tests','binary')) {
            $scan = @($manifest.Scanner.Scans | Where-Object { $_.Mode -ceq $mode })
            if ($scan.Count -ne 1 -or $scan[0].ExitCode -ne 0) { return $false }
            Assert-CanaryAACPlainPath $scan[0].OutputFile
            if ((Get-FileHash -LiteralPath $scan[0].OutputFile -Algorithm SHA256).Hash -ne $scan[0].OutputSHA256) { return $false }
        }
        return $true
    } catch { return $false }
}

Export-ModuleMember -Function Assert-CanaryAACPlainPath, Get-CanaryAACPhysicalRuntime, Assert-CanaryAACReleaseRoot, Import-CanaryAACSource, Assert-CanaryAACSource, New-CanaryAACSourceRelease, Test-CanaryAACPublicHost, Test-CanaryAACPublicUrl, Test-CanaryAACAudit, Test-CanaryAACLoginEvidence
