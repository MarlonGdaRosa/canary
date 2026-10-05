[CmdletBinding()]
param([switch] $Plan)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Local.psm1') -Force
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$layout = Get-CanaryAACLayout -RepositoryRoot $repositoryRoot
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.lock.json') -Raw | ConvertFrom-Json

function Get-CanaryAACVendorInventory {
    param([Parameter(Mandatory)][string] $Checkout)
    $status = & git -C $Checkout status --porcelain=v1 -z --untracked-files=all -- vendor/
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect vendor changes.' }
    $entries = @(($status -join "`n") -split [char] 0 | Where-Object { $_.Length -gt 0 })
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
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        Assert-FileSha256 -Path $partial -Expected $Hash
        Move-Item -LiteralPath $partial -Destination $Path
    }
    Assert-FileSha256 -Path $Path -Expected $Hash
}

function Assert-PatchedCheckout {
    param([string] $ExpectedTree, [string[]] $AllowedPaths)
    $checkIndex = Join-Path $layout.Checkout ".git\local-check-$([guid]::NewGuid().ToString('N')).index"
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

$patchRoot = Join-Path $PSScriptRoot 'patches'
$patches = @()
if (Test-Path -LiteralPath $patchRoot) {
    $patches = @(Get-ChildItem -LiteralPath $patchRoot -Filter '*.patch' -File | Sort-Object Name)
    foreach ($patch in $patches) {
        if ($patch.Name -notmatch '^\d+.*\.patch$') { throw "Patch must have a numbered name: $($patch.Name)" }
    }
}

# Inspect an existing checkout before provisioning or mutating it.
$existingCheckout = Test-Path -LiteralPath $layout.Checkout
$priorManifest = $null
$manifestPath = Join-Path $layout.Checkout '.local-install.json'
if ($existingCheckout) {
    if (-not (Test-Path -LiteralPath (Join-Path $layout.Checkout '.git'))) { throw 'Existing CanaryAAC directory is not a Git checkout.' }
    $origin = Invoke-CheckoutGit @('remote', 'get-url', 'origin')
    if ($origin -cne $lock.canaryaac.repository) { throw "CanaryAAC origin mismatch: $origin" }
    $head = Invoke-CheckoutGit @('rev-parse', 'HEAD')
    if ($head -cne $lock.canaryaac.commit) { throw "Existing CanaryAAC HEAD must equal pinned base $($lock.canaryaac.commit); got $head." }
    if (Test-Path -LiteralPath $manifestPath) {
        $priorManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($priorManifest.BaseCommit -cne $lock.canaryaac.commit) { throw 'Prior manifest has an unexpected base commit.' }
    }
    $recordedVendor = @()
    if ($null -ne $priorManifest -and $null -ne $priorManifest.PSObject.Properties['VendorInventory']) {
        $recordedVendor = @($priorManifest.VendorInventory)
    }
    Assert-CanaryAACVendorInventory -Checkout $layout.Checkout -Recorded $recordedVendor
}

$allowedPaths = @()
$patchRecords = @()
if ($existingCheckout) {
    foreach ($patch in $patches) {
        $stats = @(Invoke-CheckoutGit @('apply', '--numstat', '--', $patch.FullName))
        foreach ($stat in $stats) {
            $path = ($stat -split "`t", 3)[2]
            if ($path.StartsWith('"') -or $path -match '[\r\n]' -or $path -eq 'router.php' -or $path -eq '.local-install.json') {
                throw "Unsupported or installer-owned patch path: $path"
            }
            $allowedPaths += $path
        }
    }
    $changes = @(Invoke-CheckoutGit @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '--untracked-files=all'))
    foreach ($change in $changes) {
        $path = $change.Substring(3)
        if ($path.StartsWith('vendor/')) {
            # Exact status/path/hash identity was checked against the manifest.
        } elseif ($path -eq 'router.php' -and $change.StartsWith('?? ')) {
            $expected = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'config\router.php') -Algorithm SHA256).Hash
            Assert-FileSha256 -Path $layout.RouterPath -Expected $expected
        } elseif ($path -eq '.local-install.json' -and $change.StartsWith('?? ')) {
            # The installer manifest is validated separately and excluded below.
        } elseif ($path -cnotin $allowedPaths) {
            throw "Refusing unaccounted CanaryAAC change: $change"
        }
    }
}

$downloadRoot = Join-Path $layout.RuntimeRoot 'downloads'
$composerRoot = Split-Path -Parent $layout.ComposerPath
New-Item -ItemType Directory -Path $downloadRoot, $composerRoot -Force | Out-Null
$phpArchive = Join-Path $downloadRoot ([uri] $lock.php.url).Segments[-1]
$composerArchive = Join-Path $downloadRoot "composer-$($lock.composer.version).phar"
Get-VerifiedDownload -Url $lock.php.url -Hash $lock.php.sha256 -Path $phpArchive
Get-VerifiedDownload -Url $lock.composer.url -Hash $lock.composer.sha256 -Path $composerArchive

if (-not (Test-Path -LiteralPath $layout.PhpRoot)) {
    $phpStage = Join-Path $layout.RuntimeRoot "php-install-$([guid]::NewGuid().ToString('N'))"
    Expand-Archive -LiteralPath $phpArchive -DestinationPath $phpStage
    $version = & (Join-Path $phpStage 'php.exe') -n -r 'echo PHP_VERSION;'
    if ($LASTEXITCODE -ne 0 -or $version -cne $lock.php.version) { throw "Extracted PHP version mismatch: $version" }
    Move-Item -LiteralPath $phpStage -Destination $layout.PhpRoot
}
$version = & $layout.PhpPath -n -r 'echo PHP_VERSION;'
if ($LASTEXITCODE -ne 0 -or $version -cne $lock.php.version) { throw "Installed PHP version mismatch: $version" }
$phpIni = Join-Path $layout.PhpRoot 'php.ini'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config\php.ini') -Destination $phpIni
if (Test-Path -LiteralPath $layout.ComposerPath) {
    Assert-FileSha256 -Path $layout.ComposerPath -Expected $lock.composer.sha256
} else {
    Copy-Item -LiteralPath $composerArchive -Destination $layout.ComposerPath
}
Assert-FileSha256 -Path $layout.ComposerPath -Expected $lock.composer.sha256
$modules = @(& $layout.PhpPath -c $phpIni -m)
if ($LASTEXITCODE -ne 0) { throw 'PHP module validation failed.' }
foreach ($module in @('curl', 'dom', 'gd', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'sodium', 'xml')) {
    if ($module -cnotin $modules) { throw "Required PHP module is missing: $module" }
}
Write-Host "PHP $version; required modules verified."

if (-not $existingCheckout) {
    & git clone --no-checkout $lock.canaryaac.repository $layout.Checkout
    if ($LASTEXITCODE -ne 0) { throw "CanaryAAC clone failed with exit code $LASTEXITCODE." }
}
Invoke-CheckoutGit @('fetch', 'origin', $lock.canaryaac.commit)
Invoke-CheckoutGit @('checkout', '--detach', $lock.canaryaac.commit)

$exclude = Join-Path $layout.Checkout '.git\info\exclude'
$excludeLines = @(Get-Content -LiteralPath $exclude)
foreach ($entry in @('/.local-install.json', '/router.php')) {
    if ($entry -cnotin $excludeLines) { Add-Content -LiteralPath $exclude -Value $entry -Encoding UTF8 }
}

# Build the exact patched tree independently of the working tree. This catches
# unrelated edits even when they share a path with an approved patch.
$indexPath = Join-Path $layout.Checkout ".git\local-install-$([guid]::NewGuid().ToString('N')).index"
$savedIndex = $env:GIT_INDEX_FILE
try {
    $env:GIT_INDEX_FILE = $indexPath
    Invoke-CheckoutGit @('read-tree', $lock.canaryaac.commit)
    foreach ($patch in $patches) {
        Invoke-CheckoutGit @('apply', '--cached', '--check', '--', $patch.FullName)
        Invoke-CheckoutGit @('apply', '--cached', '--', $patch.FullName)
    }
    $expectedTree = Invoke-CheckoutGit @('write-tree')
} finally {
    $env:GIT_INDEX_FILE = $savedIndex
    if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath }
}
$allowedPaths = @()
foreach ($patch in $patches) {
    $stats = @(Invoke-CheckoutGit @('apply', '--numstat', '--', $patch.FullName))
    foreach ($stat in $stats) {
        $path = ($stat -split "`t", 3)[2]
        if ($path.StartsWith('"') -or $path -match '[\r\n]' -or $path -eq 'router.php' -or $path -eq '.local-install.json' -or $path.StartsWith('vendor/')) {
            throw "Unsupported, generated or installer-owned patch path: $path"
        }
        $allowedPaths += $path
    }
    Invoke-CanaryAACPatch -Checkout $layout.Checkout -PatchPath $patch.FullName
    $patchRecords += [ordered] @{ Name = $patch.Name; Sha256 = (Get-FileHash -LiteralPath $patch.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
Assert-PatchedCheckout -ExpectedTree $expectedTree -AllowedPaths $allowedPaths

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config\router.php') -Destination $layout.RouterPath
& $layout.PhpPath -c $phpIni $layout.ComposerPath "--working-dir=$($layout.Checkout)" install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-plugins
if ($LASTEXITCODE -ne 0) { throw "Composer install failed with exit code $LASTEXITCODE." }
& $layout.PhpPath -c $phpIni $layout.ComposerPath "--working-dir=$($layout.Checkout)" validate --strict --no-interaction --no-plugins --no-scripts
if ($LASTEXITCODE -ne 0) { throw "Composer strict validation failed with exit code $LASTEXITCODE." }
foreach ($path in @($allowedPaths | Sort-Object -Unique)) {
    if ($path.EndsWith('.php') -and (Test-Path -LiteralPath (Join-Path $layout.Checkout $path))) {
        & $layout.PhpPath -c $phpIni -l (Join-Path $layout.Checkout $path)
        if ($LASTEXITCODE -ne 0) { throw "PHP syntax check failed for $path." }
    }
}
& $layout.PhpPath -c $phpIni -l $layout.RouterPath
if ($LASTEXITCODE -ne 0) { throw 'Router PHP syntax check failed.' }
$composerLockHash = (Get-FileHash -LiteralPath (Join-Path $layout.Checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-PatchedCheckout -ExpectedTree $expectedTree -AllowedPaths $allowedPaths
$vendorInventory = @(Get-CanaryAACVendorInventory -Checkout $layout.Checkout)
foreach ($entry in $vendorInventory) {
    if ($entry.Path.EndsWith('.php') -and $null -ne $entry.Sha256) {
        & $layout.PhpPath -c $phpIni -l (Join-Path $layout.Checkout $entry.Path)
        if ($LASTEXITCODE -ne 0) { throw "Generated vendor PHP syntax check failed for $($entry.Path)." }
    }
}
foreach ($record in $patchRecords) {
    Assert-FileSha256 -Path (Join-Path $patchRoot $record.Name) -Expected $record.Sha256
}
if ($null -ne $priorManifest -and $null -ne $priorManifest.PSObject.Properties['ComposerLockSha256'] -and
    $priorManifest.ComposerVersion -ceq $lock.composer.version -and $priorManifest.ComposerLockSha256 -ceq $composerLockHash -and
    (ConvertTo-Json -InputObject @($priorManifest.Patches) -Depth 5 -Compress) -ceq (ConvertTo-Json -InputObject @($patchRecords) -Depth 5 -Compress)) {
    Assert-CanaryAACVendorInventory -Checkout $layout.Checkout -Recorded @($priorManifest.VendorInventory)
}
[ordered] @{
    BaseCommit = $lock.canaryaac.commit
    Patches = @($patchRecords)
    PhpVersion = $lock.php.version
    ComposerVersion = $lock.composer.version
    ComposerLockSha256 = $composerLockHash
    VendorInventory = @($vendorInventory)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$manifestPath.tmp" -Encoding UTF8
Move-Item -LiteralPath "$manifestPath.tmp" -Destination $manifestPath -Force
Write-Host "CanaryAAC installed at $($layout.Checkout) with $($patchRecords.Count) patches."
