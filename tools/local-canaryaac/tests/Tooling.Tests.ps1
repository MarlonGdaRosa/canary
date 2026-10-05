$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $here
Import-Module (Join-Path $toolRoot 'CanaryAAC.Local.psm1') -Force

function New-CanaryAACInstallerFixture {
    param([string] $Root)
    $fixtureTools = Join-Path $Root 'tools\local-canaryaac'
    $runtime = Join-Path $Root '.tools'
    $checkout = Join-Path $runtime 'canaryaac'
    $downloads = Join-Path $runtime 'downloads'
    $php = Join-Path $runtime 'php'
    New-Item -ItemType Directory -Path (Join-Path $fixtureTools 'config'), $checkout, $downloads, $php -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolRoot 'Install-CanaryAAC.ps1'), (Join-Path $toolRoot 'CanaryAAC.Local.psm1') -Destination $fixtureTools
    Copy-Item -LiteralPath (Join-Path $toolRoot 'config\php.ini'), (Join-Path $toolRoot 'config\router.php') -Destination (Join-Path $fixtureTools 'config')
    & git -C $checkout init --quiet
    & git -C $checkout config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $checkout '.gitignore'), "*items`n")
    [IO.File]::WriteAllText((Join-Path $checkout 'composer.lock'), 'fixture-lock')
    & git -C $checkout add .
    & git -C $checkout -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
    $lock = Get-Content -LiteralPath (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
    $lock.canaryaac.commit = (& git -C $checkout rev-parse HEAD)
    & git -C $checkout remote add origin $lock.canaryaac.repository
    [IO.File]::WriteAllText((Join-Path $checkout '.git\info\exclude'), "/router.php`n/.local-install.json`n")
    Copy-Item -LiteralPath (Join-Path $fixtureTools 'config\router.php') -Destination (Join-Path $checkout 'router.php')
    $manifestPath = Join-Path $checkout '.local-install.json'
    [pscustomobject] [ordered] @{
        BaseCommit = $lock.canaryaac.commit; Patches = @()
        PhpVersion = $lock.php.version; ComposerVersion = $lock.composer.version
        ComposerLockSha256 = (Get-FileHash -LiteralPath (Join-Path $checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
        VendorInventory = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    # Tiny approved fixture artifacts let a bad PHP installation be rejected
    # without downloading anything or ever executing this fake executable.
    $archiveSource = Join-Path $Root 'archive-source'
    New-Item -ItemType Directory -Path $archiveSource | Out-Null
    [IO.File]::WriteAllText((Join-Path $archiveSource 'php.exe'), 'approved fixture bytes')
    $archive = Join-Path $downloads 'php-fixture.zip'
    Compress-Archive -Path (Join-Path $archiveSource '*') -DestinationPath $archive
    $lock.php.url = 'https://example.invalid/php-fixture.zip'
    $lock.php.sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $php 'php.exe'), 'unapproved fixture bytes')
    $composerArchive = Join-Path $downloads 'composer-2.10.3.phar'
    [IO.File]::WriteAllText($composerArchive, 'fixture composer bytes')
    $lock.composer.sha256 = (Get-FileHash -LiteralPath $composerArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureTools 'runtime.lock.json') -Encoding UTF8
    [pscustomobject] @{
        Script = Join-Path $fixtureTools 'Install-CanaryAAC.ps1'
        Runtime = $runtime; Checkout = $checkout; ManifestPath = $manifestPath
    }
}

Describe 'CanaryAAC local tooling' {
    It 'plans a pinned install without writing runtime state' {
        $plan = & (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | ConvertFrom-Json
        $plan.PhpVersion | Should Be '8.3.35'
        $plan.ComposerVersion | Should Be '2.10.3'
        $plan.CanaryAACCommit | Should Be 'd9333dcf33d3f55cee476e9ee8ebfe3f28113c19'
        $plan.Checkout | Should Match '\\.tools\\canaryaac$'
    }

    It 'maps all generated state below .tools' {
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $layout = Get-CanaryAACLayout -RepositoryRoot $repo
        $layout.RuntimeRoot | Should Be (Join-Path $repo '.tools')
        $layout.Checkout | Should Be (Join-Path $repo '.tools\canaryaac')
        $layout.PidFile | Should Be (Join-Path $repo '.tools\canaryaac.pid')
        $layout.PhpPath | Should Be (Join-Path $repo '.tools\php\php.exe')
        $layout.RouterPath | Should Be (Join-Path $repo '.tools\canaryaac\router.php')
        $layout.ComposerPath | Should Be (Join-Path $repo '.tools\composer\composer.phar')
    }

    It 'rejects a relative repository root' {
        { Get-CanaryAACLayout -RepositoryRoot '.' } | Should Throw
    }

    It 'rejects a drive-relative repository root' {
        { Get-CanaryAACLayout -RepositoryRoot 'C:relative' } | Should Throw
    }

    It 'pins the approved runtime and source' {
        $lock = Get-Content (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
        $lock.php.version | Should Be '8.3.35'
        $lock.php.sha256 | Should Be '25a8e2ac9ff30f1d768d1447c09a600617fa6e6082729f6e95f008b59c91fe45'
        $lock.composer.version | Should Be '2.10.3'
        $lock.composer.sha256 | Should Be '7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6'
        $lock.canaryaac.commit | Should Be 'd9333dcf33d3f55cee476e9ee8ebfe3f28113c19'
    }

    It 'rejects a checksum mismatch' {
        $sample = Join-Path $TestDrive 'sample.bin'
        Set-Content -LiteralPath $sample -Value 'different' -NoNewline
        { Assert-FileSha256 -Path $sample -Expected ('0' * 64) } | Should Throw
    }

    It 'accepts a matching checksum regardless of hexadecimal case' {
        $sample = Join-Path $TestDrive 'empty.bin'
        [System.IO.File]::WriteAllBytes($sample, [byte[]] @())
        { Assert-FileSha256 -Path $sample -Expected 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855' } | Should Not Throw
    }

    It 'rejects a missing checksum input file' {
        { Assert-FileSha256 -Path (Join-Path $TestDrive 'missing.bin') -Expected ('0' * 64) } | Should Throw
    }

    It 'recognizes only the pinned executable, listener and router' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\repo\.tools\php\php.exe'
                CommandLine = '"C:\repo\.tools\php\php.exe" -c "C:\repo\.tools\php\php.ini" -S 127.0.0.1:8080 -t "C:\repo\.tools\canaryaac" "C:\repo\.tools\canaryaac\router.php"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $true
    }

    It 'rejects a reused PID running another executable' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\other\php.exe'
                CommandLine = 'php.exe -S 127.0.0.1:8080 "C:\repo\.tools\canaryaac\router.php"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
    }

    It 'rejects the pinned executable with another listener' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\repo\.tools\php\php.exe'
                CommandLine = 'php.exe -S 0.0.0.0:8080 "C:\repo\.tools\canaryaac\router.php"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
    }

    It 'rejects a quoted router argument with a suffix inside its quotes' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\repo\.tools\php\php.exe'
                CommandLine = 'php.exe -S 127.0.0.1:8080 "C:\repo\.tools\canaryaac\router.php other"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
    }

    It 'rejects listener text embedded inside a quoted script argument' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\repo\.tools\php\php.exe'
                CommandLine = 'php.exe "script -S 127.0.0.1:8080 payload.php" "C:\repo\.tools\canaryaac\router.php"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
    }

    It 'rejects another router and a missing process' {
        Mock Get-CimInstance -ModuleName CanaryAAC.Local {
            [pscustomobject] @{
                ProcessId = 123
                ExecutablePath = 'C:\repo\.tools\php\php.exe'
                CommandLine = 'php.exe -S 127.0.0.1:8080 "C:\other\router.php"'
            }
        }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
        Mock Get-CimInstance -ModuleName CanaryAAC.Local { $null }
        Test-CanaryAACProcess -ProcessId 123 -PhpPath 'C:\repo\.tools\php\php.exe' -RouterPath 'C:\repo\.tools\canaryaac\router.php' | Should Be $false
    }

    It 'returns when HTTP becomes ready' {
        Mock Invoke-WebRequest -ModuleName CanaryAAC.Local { [pscustomobject] @{ StatusCode = 200 } }
        { Wait-CanaryAACHttp -Uri 'http://127.0.0.1:8080/' -TimeoutSeconds 1 } | Should Not Throw
    }

    It 'bounds readiness retries and reports a timeout' {
        Mock Invoke-WebRequest -ModuleName CanaryAAC.Local { throw 'Connection refused' }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        { Wait-CanaryAACHttp -Uri 'http://127.0.0.1:8080/' -TimeoutSeconds 1 } | Should Throw
        $timer.Elapsed.TotalSeconds | Should BeLessThan 3
    }
}

Describe 'CanaryAAC installer hardening' {
    BeforeEach {
        . (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | Out-Null
    }

    It 'confines Composer and temporary state and restores caller variables on failure' {
        $runtime = Join-Path $TestDrive 'environment'
        New-Item -ItemType Directory -Path $runtime | Out-Null
        $names = @('COMPOSER_HOME', 'COMPOSER_CACHE_DIR', 'TEMP', 'TMP', 'COMPOSER', 'COMPOSER_VENDOR_DIR', 'COMPOSER_BIN_DIR')
        $before = @{}
        foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            Invoke-CanaryAACComposerEnvironment -RuntimeRoot $runtime -Checkout (Join-Path $runtime 'checkout') -TempRoot (Join-Path $runtime 'temp') -Action {
                foreach ($name in $names) {
                    [Environment]::GetEnvironmentVariable($name, 'Process').StartsWith($runtime + '\') | Should Be $true
                }
            }
            { Invoke-CanaryAACComposerEnvironment -RuntimeRoot $runtime -Checkout (Join-Path $runtime 'checkout') -TempRoot (Join-Path $runtime 'temp') -Action { throw 'controlled failure' } } | Should Throw 'controlled failure'
            foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name, 'Process') | Should Be $before[$name] }
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
        }
    }

    It 'refuses ignored router and vendor mutations before overwriting or accepting them' {
        $checkout = Join-Path $TestDrive 'ignored-checkout'
        New-Item -ItemType Directory -Path (Join-Path $checkout 'vendor') -Force | Out-Null
        & git -C $checkout init --quiet
        & git -C $checkout config core.autocrlf false
        [IO.File]::WriteAllText((Join-Path $checkout '.gitignore'), "*items`n")
        [IO.File]::WriteAllText((Join-Path $checkout '.git\info\exclude'), "/router.php`n/.local-install.json`n")
        & git -C $checkout add .
        & git -C $checkout -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
        $source = Join-Path $TestDrive 'router-source.php'
        [IO.File]::WriteAllText($source, '<?php echo 1;')
        Copy-Item -LiteralPath $source -Destination (Join-Path $checkout 'router.php')
        { Assert-CanaryAACIgnoredPaths -Checkout $checkout -RouterSource $source -RecordedVendor @() } | Should Not Throw
        [IO.File]::WriteAllText((Join-Path $checkout 'router.php'), '<?php echo 2;')
        { Assert-CanaryAACIgnoredPaths -Checkout $checkout -RouterSource $source -RecordedVendor @() } | Should Throw 'router'
        Copy-Item -LiteralPath $source -Destination (Join-Path $checkout 'router.php')
        [IO.File]::WriteAllText((Join-Path $checkout 'vendor\unrecordeditems'), 'unaccounted')
        $inventory = @(Get-CanaryAACVendorInventory -Checkout $checkout)
        $inventory.Count | Should Be 1
        $inventory[0].Status | Should Be '!!'
        { Assert-CanaryAACIgnoredPaths -Checkout $checkout -RouterSource $source -RecordedVendor @() } | Should Throw 'vendor'
    }

    It 'permits only the authorized root junction and refuses descendant reparse points' {
        $target = Join-Path $TestDrive 'physical-root'
        $outside = Join-Path $TestDrive 'outside'
        $runtime = Join-Path $TestDrive 'runtime-link'
        New-Item -ItemType Directory -Path $target, $outside | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'preserve')
        New-Item -ItemType Junction -Path $runtime -Target $target | Out-Null
        $child = Join-Path $runtime 'php'
        try {
            { Assert-CanaryAACSafePath -Root $runtime -Path (Join-Path $runtime 'safe.txt') -AllowedRootTarget $target } | Should Not Throw
            New-Item -ItemType Junction -Path $child -Target $outside | Out-Null
            { Assert-CanaryAACSafePath -Root $runtime -Path (Join-Path $child 'sentinel.txt') -AllowedRootTarget $target } | Should Throw 'reparse'
            (Get-Content -LiteralPath (Join-Path $outside 'sentinel.txt')) | Should Be 'preserve'
            { Assert-CanaryAACSafePath -Root $runtime -Path $outside -AllowedRootTarget $target } | Should Throw 'outside'
        } finally {
            if (Test-Path -LiteralPath $child) { [IO.Directory]::Delete($child) }
            [IO.Directory]::Delete($runtime)
        }
    }

    It 'authenticates all PHP bytes before execution and rejects changed missing and extra binaries' {
        $source = Join-Path $TestDrive 'zip-source'
        $installed = Join-Path $TestDrive 'php-auth'
        New-Item -ItemType Directory -Path (Join-Path $source 'ext'), $installed -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'php.exe'), 'approved-executable')
        [IO.File]::WriteAllText((Join-Path $source 'ext\php_curl.dll'), 'approved-library')
        $archive = Join-Path $TestDrive 'php-fixture.zip'
        Compress-Archive -Path (Join-Path $source '*') -DestinationPath $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $installed
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        { Assert-CanaryAACPhpInstallation -RuntimeRoot $TestDrive -PhpRoot $installed -Archive $archive -ArchiveSha256 $hash } | Should Not Throw
        [IO.File]::WriteAllText((Join-Path $installed 'php.exe'), 'tampered-executable')
        { Assert-CanaryAACPhpInstallation -RuntimeRoot $TestDrive -PhpRoot $installed -Archive $archive -ArchiveSha256 $hash } | Should Throw 'mismatch'
        Copy-Item -LiteralPath (Join-Path $source 'php.exe') -Destination (Join-Path $installed 'php.exe')
        [IO.File]::WriteAllText((Join-Path $installed 'extra.dll'), 'unapproved')
        { Assert-CanaryAACPhpInstallation -RuntimeRoot $TestDrive -PhpRoot $installed -Archive $archive -ArchiveSha256 $hash } | Should Throw 'Unexpected PHP file'
        Remove-Item -LiteralPath (Join-Path $installed 'extra.dll')
        Remove-Item -LiteralPath (Join-Path $installed 'ext\php_curl.dll')
        { Assert-CanaryAACPhpInstallation -RuntimeRoot $TestDrive -PhpRoot $installed -Archive $archive -ArchiveSha256 $hash } | Should Throw 'missing'
    }

    It 'uses one immutable patch snapshot when the tracked source changes' {
        $checkout = Join-Path $TestDrive 'snapshot-checkout'
        New-Item -ItemType Directory -Path $checkout | Out-Null
        & git -C $checkout init --quiet
        & git -C $checkout config core.autocrlf false
        [IO.File]::WriteAllText((Join-Path $checkout 'sample.php'), "<?php echo 'base';`n")
        & git -C $checkout add .
        & git -C $checkout -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
        $source = Join-Path $TestDrive '001-source.patch'
        [IO.File]::WriteAllText($source, "diff --git a/sample.php b/sample.php`n--- a/sample.php`n+++ b/sample.php`n@@ -1 +1 @@`n-<?php echo 'base';`n+<?php echo 'snapshot';`n")
        $hashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $snapshotRoot = Join-Path $TestDrive 'patch-snapshots'
        $snapshots = @()
        try {
            $snapshots = @(New-CanaryAACPatchSnapshots -RuntimeRoot $TestDrive -SourcePaths @($source) -DestinationRoot $snapshotRoot)
            $snapshots[0].Sha256 | Should Be $hashBefore
            [IO.File]::WriteAllText($source, 'changed-after-snapshot')
            Invoke-CanaryAACPatch -Checkout $checkout -PatchPath $snapshots[0].FullName
            (Get-Content -LiteralPath (Join-Path $checkout 'sample.php')) | Should Be "<?php echo 'snapshot';"
            { [IO.File]::WriteAllText($snapshots[0].FullName, 'tampered-snapshot') } | Should Throw
            (Get-FileHash -LiteralPath $snapshots[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $hashBefore
        } finally { foreach ($snapshot in $snapshots) { $snapshot.ReadLock.Dispose() } }
    }

    It 'requires a complete pinned manifest and permits only append-only patch transitions' {
        $checkout = Join-Path $TestDrive 'manifest-checkout'
        New-Item -ItemType Directory -Path $checkout | Out-Null
        [IO.File]::WriteAllText((Join-Path $checkout 'composer.lock'), 'pinned-lock')
        $lock = Get-Content (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
        $manifest = [pscustomobject] @{
            BaseCommit = $lock.canaryaac.commit; PhpVersion = $lock.php.version; ComposerVersion = $lock.composer.version
            ComposerLockSha256 = (Get-FileHash -LiteralPath (Join-Path $checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
            Patches = @(); VendorInventory = @()
        }
        { Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $checkout -Snapshots @() } | Should Not Throw
        $append = @([pscustomobject] @{ Name = '001-new.patch'; Sha256 = ('a' * 64) })
        { Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $checkout -Snapshots $append } | Should Not Throw
        foreach ($property in @('ComposerVersion', 'ComposerLockSha256', 'Patches', 'VendorInventory')) {
            $bad = $manifest | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $bad.PSObject.Properties.Remove($property)
            { Assert-CanaryAACInstallManifest -Manifest $bad -Lock $lock -Checkout $checkout -Snapshots @() } | Should Throw 'manifest'
        }
        $manifest.ComposerVersion = '0.0.0'
        { Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $checkout -Snapshots @() } | Should Throw 'manifest'
        $manifest.ComposerVersion = $lock.composer.version
        $manifest.ComposerLockSha256 = '0' * 64
        { Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $checkout -Snapshots @() } | Should Throw 'manifest'
        $manifest.ComposerLockSha256 = (Get-FileHash -LiteralPath (Join-Path $checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.Patches = @([pscustomobject] @{ Name = '001-original.patch'; Sha256 = ('b' * 64) })
        { Assert-CanaryAACInstallManifest -Manifest $manifest -Lock $lock -Checkout $checkout -Snapshots $append } | Should Throw 'append-only'
    }

    It 'enforces manifest and ignored-path gates in the real installer before PHP execution' {
        $fixture = New-CanaryAACInstallerFixture -Root (Join-Path $TestDrive 'full-gates')
        $originalManifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw
        $bad = $originalManifest | ConvertFrom-Json
        $bad.ComposerVersion = '0.0.0'
        $bad | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixture.ManifestPath -Encoding UTF8
        { & $fixture.Script } | Should Throw 'manifest runtime/source provenance'
        Set-Content -LiteralPath $fixture.ManifestPath -Value $originalManifest -Encoding UTF8
        $router = Join-Path $fixture.Checkout 'router.php'
        $originalRouter = [IO.File]::ReadAllBytes($router)
        [IO.File]::WriteAllText($router, 'unaccounted router')
        { & $fixture.Script } | Should Throw 'router content mismatch'
        (Get-Content -LiteralPath $router) | Should Be 'unaccounted router'
        [IO.File]::WriteAllBytes($router, $originalRouter)
        New-Item -ItemType Directory -Path (Join-Path $fixture.Checkout 'vendor') | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'vendor\unrecordeditems'), 'ignored vendor')
        { & $fixture.Script } | Should Throw 'Unrecorded vendor'
        Remove-Item -LiteralPath (Join-Path $fixture.Checkout 'vendor\unrecordeditems')
        [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'hiddenitems'), 'ignored non-vendor')
        { & $fixture.Script } | Should Throw 'Unaccounted ignored'
        @(Get-ChildItem -LiteralPath $fixture.Runtime -Directory -Filter 'canaryaac-install-*').Count | Should Be 0
    }

    It 'rejects unauthenticated PHP in the real installer and cleans only its failed session' {
        $fixture = New-CanaryAACInstallerFixture -Root (Join-Path $TestDrive 'full-php')
        $sentinel = Join-Path $fixture.Runtime 'preserve.partial'
        [IO.File]::WriteAllText($sentinel, 'unrelated')
        $names = @('COMPOSER_HOME', 'COMPOSER_CACHE_DIR', 'TEMP', 'TMP', 'COMPOSER', 'COMPOSER_VENDOR_DIR', 'COMPOSER_BIN_DIR')
        $before = @{}
        foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $manifestBefore = (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash
        { & $fixture.Script } | Should Throw 'SHA-256 mismatch'
        foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name, 'Process') | Should Be $before[$name] }
        (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash | Should Be $manifestBefore
        (Get-Content -LiteralPath $sentinel) | Should Be 'unrelated'
        @(Get-ChildItem -LiteralPath $fixture.Runtime -Directory -Filter 'canaryaac-install-*').Count | Should Be 0
    }
}

Describe 'CanaryAAC installer recovery' {
    BeforeEach {
        . (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | Out-Null
    }

    It 'excludes a hostile external INI scan on success and failure and restores its value' {
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $php = Join-Path $repo '.tools\php\php.exe'
        if (-not (Test-Path -LiteralPath $php)) { Set-TestInconclusive 'Pinned PHP is not installed yet.'; return }
        $runtime = Join-Path $TestDrive 'scan-runtime'
        $outside = Join-Path $TestDrive 'hostile-scan'
        New-Item -ItemType Directory -Path $runtime, $outside | Out-Null
        $ini = Join-Path $runtime 'safe.ini'
        [IO.File]::WriteAllText($ini, 'date.timezone=UTC')
        [IO.File]::WriteAllText((Join-Path $outside 'hostile.ini'), 'date.timezone=Pacific/Honolulu')
        $original = [Environment]::GetEnvironmentVariable('PHP_INI_SCAN_DIR', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('PHP_INI_SCAN_DIR', $outside, 'Process')
            Invoke-CanaryAACComposerEnvironment -RuntimeRoot $runtime -Checkout (Join-Path $runtime 'checkout') -TempRoot (Join-Path $runtime 'temp') -Action {
                (& $php -c $ini -r 'echo date_default_timezone_get();') | Should Be 'UTC'
                [Environment]::GetEnvironmentVariable('PHP_INI_SCAN_DIR', 'Process').StartsWith($runtime + '\') | Should Be $true
                @(& $php -c $ini -r 'echo php_ini_scanned_files();').Count | Should Be 0
            }
            [Environment]::GetEnvironmentVariable('PHP_INI_SCAN_DIR', 'Process') | Should Be $outside
            { Invoke-CanaryAACComposerEnvironment -RuntimeRoot $runtime -Checkout (Join-Path $runtime 'checkout') -TempRoot (Join-Path $runtime 'temp') -Action {
                (& $php -c $ini -r 'echo date_default_timezone_get();') | Should Be 'UTC'
                throw 'scan controlled failure'
            } } | Should Throw 'scan controlled failure'
            [Environment]::GetEnvironmentVariable('PHP_INI_SCAN_DIR', 'Process') | Should Be $outside
            [Environment]::SetEnvironmentVariable('PHP_INI_SCAN_DIR', $null, 'Process')
            Invoke-CanaryAACComposerEnvironment -RuntimeRoot $runtime -Checkout (Join-Path $runtime 'checkout') -TempRoot (Join-Path $runtime 'temp') -Action {}
            [Environment]::GetEnvironmentVariable('PHP_INI_SCAN_DIR', 'Process') | Should Be $null
        } finally { [Environment]::SetEnvironmentVariable('PHP_INI_SCAN_DIR', $original, 'Process') }
    }

    It 'rejects hidden staged changes without altering the real Git index' {
        $fixture = New-CanaryAACInstallerFixture -Root (Join-Path $TestDrive 'staged-checkout')
        { Assert-CanaryAACRealIndex -Checkout $fixture.Checkout } | Should Not Throw
        $file = Join-Path $fixture.Checkout 'composer.lock'
        $base = [IO.File]::ReadAllBytes($file)
        [IO.File]::WriteAllText($file, 'staged-unaccounted')
        & git -C $fixture.Checkout add -- composer.lock
        [IO.File]::WriteAllBytes($file, $base)
        $index = Join-Path $fixture.Checkout '.git\index'
        $before = (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash
        { Assert-CanaryAACRealIndex -Checkout $fixture.Checkout } | Should Throw 'staged'
        { & $fixture.Script } | Should Throw 'staged'
        (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash | Should Be $before
        (Get-Content -LiteralPath $file) | Should Be 'fixture-lock'
    }

    It 'resumes an authenticated post-patch failure and refuses checkout or journal tampering' {
        $fixture = New-CanaryAACInstallerFixture -Root (Join-Path $TestDrive 'transition-checkout')
        $fixtureTools = Split-Path -Parent $fixture.Script
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $lockPath = Join-Path $fixtureTools 'runtime.lock.json'
        $fixtureLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $approved = Get-Content -LiteralPath (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
        $fixtureLock.php = $approved.php
        $fixtureLock.canaryaac.repository = $fixture.Checkout
        & git -C $fixture.Checkout remote set-url origin $fixture.Checkout
        $phpName = ([uri] $approved.php.url).Segments[-1]
        Copy-Item -LiteralPath (Join-Path $repo ".tools\downloads\$phpName") -Destination (Join-Path $fixture.Runtime "downloads\$phpName")
        Remove-Item -LiteralPath (Join-Path $fixture.Runtime 'php\php.exe')
        [IO.Directory]::Delete((Join-Path $fixture.Runtime 'php'))
        $composer = @'
<?php
$fail = __DIR__ . '/fail-once';
if (in_array('install', $argv, true) && file_exists($fail)) {
    unlink($fail);
    $vendor = getenv('COMPOSER_VENDOR_DIR');
    if (!is_dir($vendor)) { mkdir($vendor, 0777, true); }
    file_put_contents($vendor . '/generated.php', "<?php // generated by the pinned fixture\n");
    fwrite(STDERR, "simulated post-patch Composer failure\n");
    exit(17);
}
echo "fixture Composer validation passed\n";
'@
        $composerArchive = Join-Path $fixture.Runtime 'downloads\composer-2.10.3.phar'
        [IO.File]::WriteAllText($composerArchive, $composer)
        $fixtureLock.composer.sha256 = (Get-FileHash -LiteralPath $composerArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixtureLock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $lockPath -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $fixture.Runtime 'composer') | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixture.Runtime 'composer\fail-once'), 'fail')
        $patchRoot = Join-Path $fixtureTools 'patches'
        New-Item -ItemType Directory -Path $patchRoot | Out-Null
        $patch = Join-Path $patchRoot '001-lock.patch'
        [IO.File]::WriteAllText($patch, "diff --git a/composer.lock b/composer.lock`n--- a/composer.lock`n+++ b/composer.lock`n@@ -1 +1 @@`n-fixture-lock`n\ No newline at end of file`n+fixture-lock-patched`n\ No newline at end of file`n")
        $manifestBefore = (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash
        { & $fixture.Script } | Should Throw 'Composer install failed with exit code 17'
        (Get-Content -LiteralPath (Join-Path $fixture.Checkout 'composer.lock')) | Should Be 'fixture-lock-patched'
        (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash | Should Be $manifestBefore
        $journal = Join-Path $fixture.Runtime 'canaryaac-transition.dat'
        Test-Path -LiteralPath $journal | Should Be $true
        $journalBytes = [IO.File]::ReadAllBytes($journal)
        $manifestBytes = [IO.File]::ReadAllBytes($fixture.ManifestPath)
        [IO.File]::WriteAllText($fixture.ManifestPath, '{}')
        { & $fixture.Script } | Should Throw 'Transition prior manifest identity'
        [IO.File]::WriteAllBytes($fixture.ManifestPath, $manifestBytes)
        [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'composer.lock'), 'unaccounted-transition')
        { & $fixture.Script } | Should Throw 'Transition'
        [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'composer.lock'), 'fixture-lock-patched')
        $corrupted = [byte[]] $journalBytes.Clone()
        $corrupted[20] = $corrupted[20] -bxor 1
        [IO.File]::WriteAllBytes($journal, $corrupted)
        { & $fixture.Script } | Should Throw 'journal authentication'
        [IO.File]::WriteAllBytes($journal, $journalBytes)
        $generated = Join-Path $fixture.Checkout 'vendor\generated.php'
        $generatedBytes = [IO.File]::ReadAllBytes($generated)
        [IO.File]::WriteAllText($generated, '<?php // unrecorded change')
        { & $fixture.Script } | Should Throw 'Unrecorded vendor'
        [IO.File]::WriteAllBytes($generated, $generatedBytes)
        $patchBytes = [IO.File]::ReadAllBytes($patch)
        [IO.File]::WriteAllText($patch, 'changed-source-patch')
        { & $fixture.Script } | Should Throw 'Transition journal provenance'
        [IO.File]::WriteAllBytes($patch, $patchBytes)
        # Reproduce the signed pending checkpoint immediately before the
        # completed git apply, so the crash window is exercised independently.
        $entropy = [Text.Encoding]::UTF8.GetBytes("CanaryAAC-transition-v1:$([IO.Path]::GetFullPath($fixture.Runtime))")
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($journalBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $pendingJournal = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        $pendingJournal.Pending = [pscustomobject] @{ Count = $pendingJournal.Count; Tree = $pendingJournal.Tree; LockHash = $pendingJournal.LockHash }
        $pendingJournal.Count = 0
        $pendingJournal.Tree = (& git -C $fixture.Checkout rev-parse 'HEAD^{tree}')
        $pendingJournal.LockHash = $pendingJournal.PriorLock
        $pendingPlain = [Text.Encoding]::UTF8.GetBytes(($pendingJournal | ConvertTo-Json -Depth 8 -Compress))
        [IO.File]::WriteAllBytes($journal, [Security.Cryptography.ProtectedData]::Protect($pendingPlain, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        { & $fixture.Script } | Should Not Throw
        Test-Path -LiteralPath $journal | Should Be $false
        $manifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw | ConvertFrom-Json
        $manifest.Patches.Count | Should Be 1
        $manifest.VendorInventory.Count | Should Be 1
        $manifest.VendorInventory[0].Path | Should Be 'vendor/generated.php'
        $manifest.Patches[0].Sha256 | Should Be (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.ComposerLockSha256 | Should Be (Get-FileHash -LiteralPath (Join-Path $fixture.Checkout 'composer.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Describe 'CanaryAAC installer safety' {
    It 'applies an absent numbered patch and recognizes it on rerun' {
        . (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | Out-Null
        $checkout = Join-Path $TestDrive 'patch-checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        & git -C $checkout init --quiet
        & git -C $checkout config core.autocrlf false
        $file = Join-Path $checkout 'sample.php'
        [System.IO.File]::WriteAllText($file, "<?php echo 'base';`n")
        & git -C $checkout add .
        & git -C $checkout -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
        $patch = Join-Path $TestDrive '001-sample.patch'
        [System.IO.File]::WriteAllText($patch, "diff --git a/sample.php b/sample.php`n--- a/sample.php`n+++ b/sample.php`n@@ -1 +1 @@`n-<?php echo 'base';`n+<?php echo 'patched';`n")
        { Invoke-CanaryAACPatch -Checkout $checkout -PatchPath $patch } | Should Not Throw
        (Get-Content -LiteralPath $file -Raw) | Should Be "<?php echo 'patched';`n"
        { Invoke-CanaryAACPatch -Checkout $checkout -PatchPath $patch } | Should Not Throw
        (Get-Content -LiteralPath $file -Raw) | Should Be "<?php echo 'patched';`n"
        [System.IO.File]::WriteAllText($file, "<?php echo 'unaccounted';`n")
        { Invoke-CanaryAACPatch -Checkout $checkout -PatchPath $patch } | Should Throw 'neither safely applicable nor already applied'
    }

    It 'accepts recorded vendor content and rejects an unrecorded mutation' {
        . (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | Out-Null
        $checkout = Join-Path $TestDrive 'vendor-checkout'
        New-Item -ItemType Directory -Path (Join-Path $checkout 'vendor') -Force | Out-Null
        & git -C $checkout init --quiet
        & git -C $checkout config core.autocrlf false
        $file = Join-Path $checkout 'vendor\generated.php'
        Set-Content -LiteralPath $file -Value 'base' -NoNewline
        & git -C $checkout add .
        & git -C $checkout -c user.name=Test -c user.email=test@example.invalid commit --quiet -m base
        Set-Content -LiteralPath $file -Value 'generated' -NoNewline
        $recorded = @([pscustomobject] @{ Status = ' M'; Path = 'vendor/generated.php'; Sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() })
        { Assert-CanaryAACVendorInventory -Checkout $checkout -Recorded $recorded } | Should Not Throw
        Set-Content -LiteralPath $file -Value 'unrecorded' -NoNewline
        { Assert-CanaryAACVendorInventory -Checkout $checkout -Recorded $recorded } | Should Throw 'Unrecorded vendor'
    }

    It 'recognizes XML capabilities built into the pinned Windows runtime' {
        . (Join-Path $toolRoot 'Install-CanaryAAC.ps1') -Plan | Out-Null
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $php = Join-Path $repo '.tools\php\php.exe'
        if (-not (Test-Path -LiteralPath $php)) { Set-TestInconclusive 'Pinned PHP is not installed yet.'; return }
        $lock = Get-Content -LiteralPath (Join-Path $toolRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
        $runtime = Join-Path $repo '.tools'
        $commonGit = & git -C $repo rev-parse --path-format=absolute --git-common-dir
        $rootTarget = Join-Path (Split-Path -Parent $commonGit) '.tools'
        $iniHash = (Get-FileHash -LiteralPath (Join-Path $toolRoot 'config\php.ini') -Algorithm SHA256).Hash
        Assert-CanaryAACPhpInstallation -RuntimeRoot $runtime -PhpRoot (Join-Path $runtime 'php') -Archive (Join-Path $runtime 'downloads\php-8.3.35-nts-Win32-vs16-x64.zip') -ArchiveSha256 $lock.php.sha256 -AllowedRootTarget $rootTarget -IniSha256 $iniHash
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $php
        $start.Arguments = '-c "' + (Join-Path $toolRoot 'config\php.ini') + '" -m'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEnd()
            $errors = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should Be 0
            $errors | Should Be ''
            $output | Should Match '(?m)^dom\r?$'
            $output | Should Match '(?m)^xml\r?$'
        } finally { $process.Dispose() }
    }

    It 'does not create runtime directories for a plan' {
        $fixture = Join-Path $TestDrive 'plan-repo'
        $fixtureTools = Join-Path $fixture 'tools\local-canaryaac'
        New-Item -ItemType Directory -Path $fixtureTools -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $toolRoot 'Install-CanaryAAC.ps1'), (Join-Path $toolRoot 'CanaryAAC.Local.psm1'), (Join-Path $toolRoot 'runtime.lock.json') -Destination $fixtureTools
        $plan = & (Join-Path $fixtureTools 'Install-CanaryAAC.ps1') -Plan | ConvertFrom-Json
        $plan.Checkout | Should Be (Join-Path $fixture '.tools\canaryaac')
        Test-Path (Join-Path $fixture '.tools') | Should Be $false
        @($plan.PSObject.Properties).Count | Should Be 4
    }

    It 'refuses a checkout belonging to another origin before provisioning' {
        $fixture = Join-Path $TestDrive 'foreign-repo'
        $fixtureTools = Join-Path $fixture 'tools\local-canaryaac'
        $checkout = Join-Path $fixture '.tools\canaryaac'
        New-Item -ItemType Directory -Path $fixtureTools, $checkout -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $toolRoot 'Install-CanaryAAC.ps1'), (Join-Path $toolRoot 'CanaryAAC.Local.psm1'), (Join-Path $toolRoot 'runtime.lock.json') -Destination $fixtureTools
        & git -C $checkout init --quiet
        & git -C $checkout remote add origin 'https://example.invalid/unrelated.git'
        { & (Join-Path $fixtureTools 'Install-CanaryAAC.ps1') } | Should Throw 'origin mismatch'
        Test-Path (Join-Path $fixture '.tools\php') | Should Be $false
        (& git -C $checkout remote get-url origin) | Should Be 'https://example.invalid/unrelated.git'
    }
}
