[CmdletBinding()]
param([switch] $Plan)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Local.psm1') -Force
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$layout = Get-CanaryAACLayout -RepositoryRoot $repositoryRoot
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.lock.json') -Raw | ConvertFrom-Json

function Assert-CanaryAACSafePath {
    param([string] $Root, [string] $Path, [string] $AllowedRootTarget)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -ine $rootPath -and -not $fullPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path outside runtime boundary: $fullPath"
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue
    $physicalRoot = $rootPath
    if ($null -ne $rootItem -and ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ([string]::IsNullOrEmpty($AllowedRootTarget) -or $rootItem.LinkType -ne 'Junction' -or @($rootItem.Target).Count -ne 1) {
            throw "Unauthorized root reparse point: $rootPath"
        }
        $physicalRoot = [IO.Path]::GetFullPath($rootItem.Target[0]).TrimEnd('\', '/')
        if ($physicalRoot -ine [IO.Path]::GetFullPath($AllowedRootTarget).TrimEnd('\', '/')) {
            throw "Unauthorized root reparse target: $physicalRoot"
        }
    }
    # Prove the root's physical ancestry contains no additional redirects.
    $ancestor = $physicalRoot
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe reparse ancestor: $ancestor" }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if ($fullPath -ine $rootPath) {
        $current = $rootPath
        foreach ($part in $fullPath.Substring($rootPath.Length + 1).Split('\')) {
            if ($part.Contains(':')) { throw "Alternate stream outside approved file identity: $fullPath" }
            $current = Join-Path $current $part
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe descendant reparse point: $current" }
        }
    }
}

function Assert-CanaryAACSafeTree {
    param([string] $Root, [string] $Path, [string] $AllowedRootTarget)
    Assert-CanaryAACSafePath -Root $Root -Path $Path -AllowedRootTarget $AllowedRootTarget
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe descendant reparse point: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Invoke-CanaryAACComposerEnvironment {
    param([string] $RuntimeRoot, [string] $Checkout, [string] $TempRoot, [scriptblock] $Action)
    $settings = [ordered] @{
        COMPOSER_HOME = Join-Path $RuntimeRoot 'composer\home'
        COMPOSER_CACHE_DIR = Join-Path $RuntimeRoot 'composer\cache'
        TEMP = $TempRoot
        TMP = $TempRoot
        COMPOSER = Join-Path $Checkout 'composer.json'
        COMPOSER_VENDOR_DIR = Join-Path $Checkout 'vendor'
        COMPOSER_BIN_DIR = Join-Path $Checkout 'vendor\bin'
    }
    $saved = @{}
    foreach ($name in $settings.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $settings.Keys) { [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process') }
        & $Action
    } finally {
        foreach ($name in $settings.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

function Assert-CanaryAACPhpInstallation {
    param([string] $RuntimeRoot, [string] $PhpRoot, [string] $Archive, [string] $ArchiveSha256, [string] $AllowedRootTarget, [string] $IniSha256, [switch] $KeepReadLocks)
    Assert-CanaryAACSafePath -Root $RuntimeRoot -Path $Archive -AllowedRootTarget $AllowedRootTarget
    Assert-CanaryAACSafeTree -Root $RuntimeRoot -Path $PhpRoot -AllowedRootTarget $AllowedRootTarget
    Assert-FileSha256 -Path $Archive -Expected $ArchiveSha256
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $expected = @{}
    $retained = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
    $authenticated = $false
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $relative = $entry.FullName.Replace('/', '\')
            if ($relative.StartsWith('\') -or $relative.Contains(':') -or @($relative.Split('\') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or $expected.ContainsKey($relative)) {
                throw "Unsafe or duplicate PHP archive entry: $relative"
            }
            $expected[$relative] = $true
            $path = Join-Path $PhpRoot $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Approved PHP file is missing: $relative" }
            $retained.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            Assert-FileSha256 -Path $path -Expected $hash
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $PhpRoot -File -Recurse -Force)) {
            $relative = $file.FullName.Substring([IO.Path]::GetFullPath($PhpRoot).TrimEnd('\').Length + 1)
            if ($expected.ContainsKey($relative)) { continue }
            if ($relative -ieq 'php.ini' -and -not [string]::IsNullOrEmpty($IniSha256)) {
                Assert-FileSha256 -Path $file.FullName -Expected $IniSha256
            } else { throw "Unexpected PHP file: $relative" }
        }
        $authenticated = $true
        if ($KeepReadLocks) { return $retained.ToArray() }
    } finally {
        $zip.Dispose()
        if (-not $authenticated -or -not $KeepReadLocks) { foreach ($stream in $retained) { $stream.Dispose() } }
    }
}

function New-CanaryAACPatchSnapshots {
    param([string] $RuntimeRoot, [string[]] $SourcePaths, [string] $DestinationRoot, [string] $AllowedRootTarget)
    Assert-CanaryAACSafePath -Root $RuntimeRoot -Path $DestinationRoot -AllowedRootTarget $AllowedRootTarget
    New-Item -ItemType Directory -Path $DestinationRoot -ErrorAction Stop | Out-Null
    $snapshots = @()
    try {
        foreach ($source in $SourcePaths) {
            $name = [IO.Path]::GetFileName($source)
            if ($name -notmatch '^\d+.*\.patch$') { throw "Patch must have a numbered name: $name" }
            $destination = Join-Path $DestinationRoot $name
            $sourceStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $snapshotStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $sourceStream.CopyTo($snapshotStream) } finally { $snapshotStream.Dispose() }
            } finally { $sourceStream.Dispose() }
            $readLock = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $snapshots += [pscustomobject] @{
                    Name = $name; FullName = $destination
                    Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                    ReadLock = $readLock
                }
            } catch { $readLock.Dispose(); throw }
        }
        return $snapshots
    } catch {
        foreach ($snapshot in $snapshots) { $snapshot.ReadLock.Dispose() }
        throw
    }
}

function Assert-CanaryAACInstallManifest {
    param([object] $Manifest, [object] $Lock, [string] $Checkout, [object[]] $Snapshots)
    $required = @('BaseCommit', 'Patches', 'PhpVersion', 'ComposerVersion', 'ComposerLockSha256', 'VendorInventory')
    $properties = @($Manifest.PSObject.Properties.Name)
    if ($properties.Count -ne $required.Count -or @($required | Where-Object { $_ -cnotin $properties }).Count -gt 0) {
        throw 'Install manifest schema must contain every required provenance field exactly once.'
    }
    if ($Manifest.BaseCommit -cne $Lock.canaryaac.commit -or $Manifest.PhpVersion -cne $Lock.php.version -or $Manifest.ComposerVersion -cne $Lock.composer.version) {
        throw 'Install manifest runtime/source provenance does not match the approved pins.'
    }
    if ($Manifest.ComposerLockSha256 -cnotmatch '^[a-f0-9]{64}$' -or $Manifest.Patches -isnot [array] -or $Manifest.VendorInventory -isnot [array]) {
        throw 'Install manifest hashes and collections have invalid types.'
    }
    $currentLock = (Get-FileHash -LiteralPath (Join-Path $Checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Manifest.ComposerLockSha256 -cne $currentLock) { throw 'Install manifest composer.lock provenance mismatch before patch transition.' }
    if ($Manifest.Patches.Count -gt $Snapshots.Count) { throw 'Install manifest permits only an append-only patch transition.' }
    for ($index = 0; $index -lt $Manifest.Patches.Count; $index++) {
        $record = $Manifest.Patches[$index]
        if (@($record.PSObject.Properties).Count -ne 2 -or $null -eq $record.PSObject.Properties['Name'] -or $null -eq $record.PSObject.Properties['Sha256'] -or
            $record.Name -cne $Snapshots[$index].Name -or $record.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or $record.Sha256 -cne $Snapshots[$index].Sha256) {
            throw 'Install manifest permits only an append-only patch transition; existing patch names/hashes must match immutable snapshots.'
        }
    }
    $seen = @{}
    foreach ($entry in $Manifest.VendorInventory) {
        $fields = @($entry.PSObject.Properties.Name)
        if ($fields.Count -ne 3 -or @('Status', 'Path', 'Sha256' | Where-Object { $_ -cnotin $fields }).Count -gt 0 -or
            $entry.Status -cnotmatch '^( M| D|\?\?|!!)$' -or $entry.Path -cnotmatch '^vendor/' -or $entry.Path -match '[\\:\r\n]' -or
            @($entry.Path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or $seen.ContainsKey($entry.Path) -or
            ($entry.Status -ceq ' D' -and $null -ne $entry.Sha256) -or ($entry.Status -cne ' D' -and $entry.Sha256 -cnotmatch '^[a-f0-9]{64}$')) {
            throw 'Install manifest vendor inventory schema is invalid.'
        }
        $seen[$entry.Path] = $true
    }
    $ordered = @($Manifest.VendorInventory | Sort-Object Path)
    if ((ConvertTo-Json -InputObject $ordered -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject @($Manifest.VendorInventory) -Depth 5 -Compress)) {
        throw 'Install manifest vendor inventory must be sorted by path.'
    }
}

function Assert-CanaryAACIgnoredPaths {
    param([string] $Checkout, [string] $RouterSource, [object[]] $RecordedVendor)
    $router = Join-Path $Checkout 'router.php'
    if (Test-Path -LiteralPath $router) {
        $expected = (Get-FileHash -LiteralPath $RouterSource -Algorithm SHA256).Hash
        try { Assert-FileSha256 -Path $router -Expected $expected } catch { throw "Installed router content mismatch: $($_.Exception.Message)" }
    }
    Assert-CanaryAACVendorInventory -Checkout $Checkout -Recorded @($RecordedVendor)
    $ignored = & git -C $Checkout ls-files --others --ignored --exclude-standard -z
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect ignored checkout paths.' }
    foreach ($path in @(($ignored -join '') -split [char] 0 | Where-Object { $_.Length -gt 0 })) {
        if ($path -cin @('router.php', '.local-install.json') -or $path.StartsWith('vendor/')) { continue }
        throw "Unaccounted ignored checkout path: $path"
    }
}

function Get-CanaryAACVendorInventory {
    param([Parameter(Mandatory)][string] $Checkout)
    $status = & git -C $Checkout status --porcelain=v1 -z --untracked-files=all -- vendor/
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect vendor changes.' }
    $entries = @(($status -join '') -split [char] 0 | Where-Object { $_.Length -gt 0 })
    $ignored = & git -C $Checkout ls-files --others --ignored --exclude-standard -z -- vendor/
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect ignored vendor changes.' }
    $entries += @(($ignored -join '') -split [char] 0 | Where-Object { $_.Length -gt 0 } | ForEach-Object { '!! ' + $_ })
    foreach ($entry in @($entries | Sort-Object { $_.Substring(3) })) {
        $path = $entry.Substring(3)
        if (-not $path.StartsWith('vendor/') -or $entry.Substring(0, 2) -match '[RC]') {
            throw "Unsupported vendor change: $entry"
        }
        $hash = $null
        $file = Join-Path $Checkout $path
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [pscustomobject] [ordered] @{ Status = $entry.Substring(0, 2); Path = $path; Sha256 = $hash }
    }
}

function Assert-CanaryAACVendorInventory {
    param([Parameter(Mandatory)][string] $Checkout, [AllowEmptyCollection()][object[]] $Recorded = @())
    $actual = @(Get-CanaryAACVendorInventory -Checkout $Checkout)
    $actualJson = ConvertTo-Json -InputObject $actual -Depth 5 -Compress
    $recordedJson = ConvertTo-Json -InputObject @($Recorded) -Depth 5 -Compress
    if ($actualJson -cne $recordedJson) { throw 'Unrecorded vendor changes: status, path and SHA-256 must match the prior install manifest.' }
}

function Invoke-CanaryAACPatch {
    param([Parameter(Mandatory)][string] $Checkout, [Parameter(Mandatory)][string] $PatchPath)
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -C $Checkout apply --check -- $PatchPath 2>$null
        $canApply = $LASTEXITCODE -eq 0
        if (-not $canApply) {
            & git -C $Checkout apply --reverse --check -- $PatchPath 2>$null
            if ($LASTEXITCODE -ne 0) { throw "Patch is neither safely applicable nor already applied: $PatchPath" }
        }
    } finally { $ErrorActionPreference = $savedErrorPreference }
    if ($canApply) {
        & git -C $Checkout apply -- $PatchPath
        if ($LASTEXITCODE -ne 0) { throw "Patch application failed: $PatchPath" }
    }
}

if ($Plan) {
    [ordered] @{
        PhpVersion = $lock.php.version
        ComposerVersion = $lock.composer.version
        CanaryAACCommit = $lock.canaryaac.commit
        Checkout = $layout.Checkout
    } | ConvertTo-Json
    return
}

function Invoke-CheckoutGit {
    param([string[]] $Arguments)
    $output = & git -C $layout.Checkout @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    return $output
}

function Get-VerifiedDownload {
    param([string] $Url, [string] $Hash, [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        # A failed download never becomes the reusable archive.
        $partial = "$Path.$([guid]::NewGuid().ToString('N')).partial"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
            Assert-FileSha256 -Path $partial -Expected $Hash
            Move-Item -LiteralPath $partial -Destination $Path
        } finally {
            if (Test-Path -LiteralPath $partial) {
                Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path $partial -AllowedRootTarget $allowedRuntimeTarget
                Remove-Item -LiteralPath $partial
            }
        }
    }
    Assert-FileSha256 -Path $Path -Expected $Hash
}

function Assert-PatchedCheckout {
    param([string] $ExpectedTree, [string[]] $AllowedPaths)
    $checkIndex = Join-Path $session.Root "check-$([guid]::NewGuid().ToString('N')).index"
    $previousIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $checkIndex
        Invoke-CheckoutGit @('read-tree', $ExpectedTree)
        Invoke-CheckoutGit @('diff', '--exit-code', '--', '.', ':(exclude)vendor/')
    } finally {
        $env:GIT_INDEX_FILE = $previousIndex
        if (Test-Path -LiteralPath $checkIndex) { Remove-Item -LiteralPath $checkIndex }
    }
    $untracked = @(Invoke-CheckoutGit @('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard'))
    foreach ($path in $untracked) {
        if ($path.StartsWith('vendor/')) { continue }
        if ($path -cnotin $AllowedPaths) { throw "Refusing unaccounted CanaryAAC file: $path" }
        $actualBlob = Invoke-CheckoutGit @('hash-object', '--', $path)
        $expectedBlob = Invoke-CheckoutGit @('rev-parse', "${ExpectedTree}:$path")
        if ($actualBlob -cne $expectedBlob) { throw "Unexpected content in patched file: $path" }
    }
}

function Get-CanaryAACExpectedTree {
    param([object[]] $Snapshots)
    $indexPath = Join-Path $session.Root "index-$([guid]::NewGuid().ToString('N'))"
    $savedIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexPath
        Invoke-CheckoutGit @('read-tree', $lock.canaryaac.commit)
        foreach ($snapshot in $Snapshots) {
            Assert-FileSha256 -Path $snapshot.FullName -Expected $snapshot.Sha256
            Invoke-CheckoutGit @('apply', '--cached', '--check', '--', $snapshot.FullName)
            Invoke-CheckoutGit @('apply', '--cached', '--', $snapshot.FullName)
        }
        return Invoke-CheckoutGit @('write-tree')
    } finally {
        $env:GIT_INDEX_FILE = $savedIndex
        if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath }
    }
}

$allowedRuntimeTarget = $null
$runtimeItem = Get-Item -LiteralPath $layout.RuntimeRoot -Force -ErrorAction SilentlyContinue
if ($null -ne $runtimeItem -and ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    $commonGit = & git -C $repositoryRoot rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'Cannot establish the authorized shared runtime root.' }
    $allowedRuntimeTarget = Join-Path (Split-Path -Parent $commonGit) '.tools'
}
$downloadRoot = Join-Path $layout.RuntimeRoot 'downloads'
$composerRoot = Split-Path -Parent $layout.ComposerPath
foreach ($path in @($layout.PhpRoot, $composerRoot, $layout.Checkout, $downloadRoot)) {
    Assert-CanaryAACSafeTree -Root $layout.RuntimeRoot -Path $path -AllowedRootTarget $allowedRuntimeTarget
}

$existingCheckout = Test-Path -LiteralPath $layout.Checkout
$manifestPath = Join-Path $layout.Checkout '.local-install.json'
$routerSource = Join-Path $PSScriptRoot 'config\router.php'
if ($existingCheckout) {
    if (-not (Test-Path -LiteralPath (Join-Path $layout.Checkout '.git') -PathType Container)) { throw 'Existing CanaryAAC directory is not a Git checkout.' }
    $origin = Invoke-CheckoutGit @('remote', 'get-url', 'origin')
    if ($origin -cne $lock.canaryaac.repository) { throw "CanaryAAC origin mismatch: $origin" }
    $head = Invoke-CheckoutGit @('rev-parse', 'HEAD')
    if ($head -cne $lock.canaryaac.commit) { throw "Existing CanaryAAC HEAD must equal pinned base $($lock.canaryaac.commit); got $head." }
}

$session = [pscustomobject] @{
    Root = Join-Path $layout.RuntimeRoot "canaryaac-install-$([guid]::NewGuid().ToString('N'))"
    PhpStage = $null
    Snapshots = @()
    ArtifactLocks = @()
}
Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path $session.Root -AllowedRootTarget $allowedRuntimeTarget
New-Item -ItemType Directory -Path $session.Root | Out-Null
try {
    $tempRoot = Join-Path $session.Root 'temp'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Invoke-CanaryAACComposerEnvironment -RuntimeRoot $layout.RuntimeRoot -Checkout $layout.Checkout -TempRoot $tempRoot -Action {
        $patchRoot = Join-Path $PSScriptRoot 'patches'
        $sources = @()
        if (Test-Path -LiteralPath $patchRoot) {
            Assert-CanaryAACSafeTree -Root $repositoryRoot -Path $patchRoot
            $sources = @(Get-ChildItem -LiteralPath $patchRoot -Filter '*.patch' -File | Sort-Object Name | ForEach-Object { $_.FullName })
        }
        $session.Snapshots = @(New-CanaryAACPatchSnapshots -RuntimeRoot $layout.RuntimeRoot -SourcePaths $sources -DestinationRoot (Join-Path $session.Root 'patches') -AllowedRootTarget $allowedRuntimeTarget)
        $patches = $session.Snapshots
        $patchRecords = @($patches | ForEach-Object { [pscustomobject] [ordered] @{ Name = $_.Name; Sha256 = $_.Sha256 } })
        $priorManifest = $null
        $recordedVendor = @()
        $priorPatchCount = 0
        $allowedPaths = @()

        if ($existingCheckout) {
            if (Test-Path -LiteralPath $manifestPath) {
                $priorManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                Assert-CanaryAACInstallManifest -Manifest $priorManifest -Lock $lock -Checkout $layout.Checkout -Snapshots $patches
                $recordedVendor = @($priorManifest.VendorInventory)
                $priorPatchCount = $priorManifest.Patches.Count
            }
            Assert-CanaryAACIgnoredPaths -Checkout $layout.Checkout -RouterSource $routerSource -RecordedVendor $recordedVendor
            # A transition starts only from the exact prior patched tree. Newly
            # appended patches are applied by this invocation, never adopted
            # from unexplained edits to the checkout or composer.lock.
            $priorPatches = @()
            if ($priorPatchCount -gt 0) { $priorPatches = @($patches[0..($priorPatchCount - 1)]) }
            $priorTree = Get-CanaryAACExpectedTree -Snapshots $priorPatches
            $priorPaths = @()
            foreach ($patch in $priorPatches) {
                foreach ($stat in @(Invoke-CheckoutGit @('apply', '--numstat', '--', $patch.FullName))) { $priorPaths += ($stat -split "`t", 3)[2] }
            }
            Assert-PatchedCheckout -ExpectedTree $priorTree -AllowedPaths $priorPaths
        }

        New-Item -ItemType Directory -Path $downloadRoot, $composerRoot, (Join-Path $composerRoot 'home'), (Join-Path $composerRoot 'cache') -Force | Out-Null
        $phpArchive = Join-Path $downloadRoot ([uri] $lock.php.url).Segments[-1]
        $composerArchive = Join-Path $downloadRoot "composer-$($lock.composer.version).phar"
        foreach ($path in @($phpArchive, $composerArchive, $layout.ComposerPath)) {
            Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path $path -AllowedRootTarget $allowedRuntimeTarget
        }
        Get-VerifiedDownload -Url $lock.php.url -Hash $lock.php.sha256 -Path $phpArchive
        Get-VerifiedDownload -Url $lock.composer.url -Hash $lock.composer.sha256 -Path $composerArchive
        foreach ($path in @($phpArchive, $composerArchive)) {
            $session.ArtifactLocks += [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        }
        # Authenticate all runtime files before the first php.exe invocation.
        if (-not (Test-Path -LiteralPath $layout.PhpRoot)) {
            $stage = Join-Path $layout.RuntimeRoot "php-install-$([guid]::NewGuid().ToString('N'))"
            Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path $stage -AllowedRootTarget $allowedRuntimeTarget
            New-Item -ItemType Directory -Path $stage | Out-Null
            $session.PhpStage = $stage
            Expand-Archive -LiteralPath $phpArchive -DestinationPath $stage
            Assert-CanaryAACPhpInstallation -RuntimeRoot $layout.RuntimeRoot -PhpRoot $stage -Archive $phpArchive -ArchiveSha256 $lock.php.sha256 -AllowedRootTarget $allowedRuntimeTarget
            $version = & (Join-Path $stage 'php.exe') -n -r 'echo PHP_VERSION;'
            if ($LASTEXITCODE -ne 0 -or $version -cne $lock.php.version) { throw "Extracted PHP version mismatch: $version" }
            Move-Item -LiteralPath $stage -Destination $layout.PhpRoot
            $session.PhpStage = $null
        }
        $iniSource = Join-Path $PSScriptRoot 'config\php.ini'
        $iniHash = (Get-FileHash -LiteralPath $iniSource -Algorithm SHA256).Hash
        $session.ArtifactLocks += @(Assert-CanaryAACPhpInstallation -RuntimeRoot $layout.RuntimeRoot -PhpRoot $layout.PhpRoot -Archive $phpArchive -ArchiveSha256 $lock.php.sha256 -AllowedRootTarget $allowedRuntimeTarget -IniSha256 $iniHash -KeepReadLocks)
        $version = & $layout.PhpPath -n -r 'echo PHP_VERSION;'
        if ($LASTEXITCODE -ne 0 -or $version -cne $lock.php.version) { throw "Installed PHP version mismatch: $version" }
        $phpIni = Join-Path $layout.PhpRoot 'php.ini'
        Copy-Item -LiteralPath $iniSource -Destination $phpIni
        if (-not (Test-Path -LiteralPath $layout.ComposerPath)) { Copy-Item -LiteralPath $composerArchive -Destination $layout.ComposerPath }
        $session.ArtifactLocks += [IO.File]::Open($layout.ComposerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        Assert-FileSha256 -Path $layout.ComposerPath -Expected $lock.composer.sha256
        $modules = @(& $layout.PhpPath -c $phpIni -m)
        if ($LASTEXITCODE -ne 0) { throw 'PHP module validation failed.' }
        foreach ($module in @('curl', 'dom', 'gd', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'sodium', 'xml')) {
            if ($module -cnotin $modules) { throw "Required PHP module is missing: $module" }
        }
        Write-Host "PHP $version; approved archive contents and required modules verified."

        if (-not $existingCheckout) {
            & git clone --no-checkout $lock.canaryaac.repository $layout.Checkout
            if ($LASTEXITCODE -ne 0) { throw "CanaryAAC clone failed with exit code $LASTEXITCODE." }
        }
        Assert-CanaryAACSafeTree -Root $layout.RuntimeRoot -Path $layout.Checkout -AllowedRootTarget $allowedRuntimeTarget
        Invoke-CheckoutGit @('fetch', 'origin', $lock.canaryaac.commit)
        Invoke-CheckoutGit @('checkout', '--detach', $lock.canaryaac.commit)
        $exclude = Join-Path $layout.Checkout '.git\info\exclude'
        $excludeLines = @(Get-Content -LiteralPath $exclude)
        foreach ($entry in @('/.local-install.json', '/router.php')) {
            if ($entry -cnotin $excludeLines) { Add-Content -LiteralPath $exclude -Value $entry -Encoding UTF8 }
        }
        $expectedTree = Get-CanaryAACExpectedTree -Snapshots $patches
        for ($index = 0; $index -lt $patches.Count; $index++) {
            $patch = $patches[$index]
            foreach ($stat in @(Invoke-CheckoutGit @('apply', '--numstat', '--', $patch.FullName))) {
                $path = ($stat -split "`t", 3)[2]
                if ($path.StartsWith('"') -or $path -match '[\r\n]' -or $path -cin @('router.php', '.local-install.json') -or $path.StartsWith('vendor/')) {
                    throw "Unsupported, generated or installer-owned patch path: $path"
                }
                Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path (Join-Path $layout.Checkout $path) -AllowedRootTarget $allowedRuntimeTarget
                $allowedPaths += $path
            }
            # The entire prior patch tree was verified above; reruns need not
            # reverse an older patch whose hunks a later patch has replaced.
            if ($index -ge $priorPatchCount) { Invoke-CanaryAACPatch -Checkout $layout.Checkout -PatchPath $patch.FullName }
        }
        Assert-PatchedCheckout -ExpectedTree $expectedTree -AllowedPaths $allowedPaths
        Assert-CanaryAACIgnoredPaths -Checkout $layout.Checkout -RouterSource $routerSource -RecordedVendor $recordedVendor
        Copy-Item -LiteralPath $routerSource -Destination $layout.RouterPath
        & $layout.PhpPath -c $phpIni $layout.ComposerPath "--working-dir=$($layout.Checkout)" install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-plugins
        if ($LASTEXITCODE -ne 0) { throw "Composer install failed with exit code $LASTEXITCODE." }
        & $layout.PhpPath -c $phpIni $layout.ComposerPath "--working-dir=$($layout.Checkout)" validate --strict --no-interaction --no-plugins --no-scripts
        if ($LASTEXITCODE -ne 0) { throw "Composer strict validation failed with exit code $LASTEXITCODE." }
        Assert-CanaryAACSafeTree -Root $layout.RuntimeRoot -Path $layout.Checkout -AllowedRootTarget $allowedRuntimeTarget
        Assert-PatchedCheckout -ExpectedTree $expectedTree -AllowedPaths $allowedPaths
        $vendorInventory = @(Get-CanaryAACVendorInventory -Checkout $layout.Checkout)
        $composerLockHash = (Get-FileHash -LiteralPath (Join-Path $layout.Checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($null -ne $priorManifest -and $priorPatchCount -eq $patches.Count) {
            if ($composerLockHash -cne $priorManifest.ComposerLockSha256) { throw 'Manifest lock provenance changed without an appended patch.' }
            Assert-CanaryAACVendorInventory -Checkout $layout.Checkout -Recorded $recordedVendor
        }
        Assert-CanaryAACIgnoredPaths -Checkout $layout.Checkout -RouterSource $routerSource -RecordedVendor $vendorInventory
        $phpPaths = @($allowedPaths + @($vendorInventory | ForEach-Object { $_.Path }) + 'router.php' | Sort-Object -Unique)
        foreach ($path in $phpPaths) {
            if ($path.EndsWith('.php') -and (Test-Path -LiteralPath (Join-Path $layout.Checkout $path) -PathType Leaf)) {
                & $layout.PhpPath -c $phpIni -l (Join-Path $layout.Checkout $path)
                if ($LASTEXITCODE -ne 0) { throw "PHP syntax check failed for $path." }
            }
        }
        $manifest = [pscustomobject] [ordered] @{
            BaseCommit = $lock.canaryaac.commit; Patches = @($patchRecords)
            PhpVersion = $lock.php.version; ComposerVersion = $lock.composer.version
            ComposerLockSha256 = $composerLockHash; VendorInventory = @($vendorInventory)
        }
        Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $layout.Checkout -Snapshots $patches
        $manifestStage = Join-Path $session.Root 'manifest.json'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestStage -Encoding UTF8
        Assert-CanaryAACSafePath -Root $layout.RuntimeRoot -Path $manifestPath -AllowedRootTarget $allowedRuntimeTarget
        Move-Item -LiteralPath $manifestStage -Destination $manifestPath -Force
        Write-Host "CanaryAAC installed at $($layout.Checkout) with $($patchRecords.Count) patches."
    }
} finally {
    foreach ($snapshot in $session.Snapshots) { $snapshot.ReadLock.Dispose() }
    foreach ($stream in $session.ArtifactLocks) { $stream.Dispose() }
    foreach ($ownedDirectory in @($session.PhpStage, $session.Root)) {
        if (-not [string]::IsNullOrEmpty($ownedDirectory) -and (Test-Path -LiteralPath $ownedDirectory)) {
            # These exact GUID directories were created by this invocation.
            # Refuse cleanup if a redirect was introduced; never follow it.
            Assert-CanaryAACSafeTree -Root $layout.RuntimeRoot -Path $ownedDirectory -AllowedRootTarget $allowedRuntimeTarget
            Remove-Item -LiteralPath $ownedDirectory -Recurse -Force
        }
    }
}
