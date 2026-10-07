$toolRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $toolRoot 'CanaryAAC.Production.psm1'
if (Test-Path $module) { Import-Module $module -Force }

Describe 'Production release boundary' {
    It 'provides the release validation boundary' {
        Test-Path $module | Should Be $true
    }
    It 'rejects HTTP, placeholders, loopback and missing game identity' {
        Test-CanaryAACPublicUrl 'http://realm.example.org' | Should Be $false
        Test-CanaryAACPublicUrl 'https://example.invalid' | Should Be $false
        Test-CanaryAACPublicUrl 'https://127.0.0.1' | Should Be $false
        Test-CanaryAACPublicUrl 'https://realm.tibiarealm.net' | Should Be $true
        Test-CanaryAACPublicHost '192.168.1.3' | Should Be $false
        Test-CanaryAACPublicHost '' | Should Be $false
    }
    It 'confines release output and refuses reparse ancestry' {
        $root = Join-Path $TestDrive 'runtime'
        New-Item -ItemType Directory $root -Force | Out-Null
        { Assert-CanaryAACReleaseRoot -RuntimeRoot $root -OutputRoot (Join-Path $root '..\escape') } | Should Throw
        { Assert-CanaryAACReleaseRoot -RuntimeRoot $root -OutputRoot 'relative' } | Should Throw
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory $outside -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $root 'releases') -Target $outside | Out-Null
        { Assert-CanaryAACReleaseRoot -RuntimeRoot $root -OutputRoot (Join-Path $root 'releases') } | Should Throw
    }
    It 'replays patches, checks all source bytes and emits only a source release' {
        $fixture = Join-Path $TestDrive 'source-fixture'
        $source = Join-Path $fixture 'canaryaac'
        $patches = Join-Path $fixture 'patches'
        New-Item -ItemType Directory (Join-Path $source 'public'), (Join-Path $source 'app'), (Join-Path $source 'resources\images'), $patches -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'public\index.php'), '<?php echo "safe";')
        [IO.File]::WriteAllText((Join-Path $source 'app\entry.php'), '<?php echo "base";')
        [IO.File]::WriteAllText((Join-Path $source 'resources\images\logo.svg'), '<svg/>')
        [IO.File]::WriteAllText((Join-Path $source 'composer.lock'), '{}')
        [IO.File]::WriteAllText((Join-Path $source '.env'), 'NEVER_EXPORT=synthetic-secret')
        & git -C $source init -q
        & git -C $source -c core.autocrlf=false add .
        & git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
        $base = & git -C $source rev-parse HEAD
        $patch = "diff --git a/app/entry.php b/app/entry.php`n--- a/app/entry.php`n+++ b/app/entry.php`n@@ -1 +1 @@`n-<?php echo `"base`";`n\ No newline at end of file`n+<?php echo `"patched`";`n\ No newline at end of file`n"
        [IO.File]::WriteAllText((Join-Path $patches '0001-fixture.patch'), $patch)
        & git -C $source apply (Join-Path $patches '0001-fixture.patch')
        $stage = Join-Path $fixture 'replay'
        $identity = Import-CanaryAACSource -Checkout $source -BaseCommit $base -PatchRoot $patches -Destination $stage
        Assert-CanaryAACSource -Checkout $source -ExpectedRoot $stage | Should Be $true
        Test-Path (Join-Path $stage '.env') | Should Be $false
        $release = New-CanaryAACSourceRelease -ExpectedRoot $stage -OutputRoot (Join-Path $fixture 'releases') -Identity $identity -LicensePath (Join-Path $toolRoot '..\..\LICENSE')
        Test-Path (Join-Path $release 'public\resources\images\logo.svg') | Should Be $true
        Test-Path (Join-Path $release 'public\app') | Should Be $false
        Test-Path (Join-Path $release '.env') | Should Be $false
        Test-Path (Join-Path $release 'vendor') | Should Be $false
        $manifest = Get-Content (Join-Path $release 'release-manifest.json') -Raw | ConvertFrom-Json
        $manifest.Deployable | Should Be $false
        $manifest.Dependencies | Should Be 'NotInstalled'
        [IO.File]::AppendAllText((Join-Path $source 'app\entry.php'), 'drift')
        { Assert-CanaryAACSource -Checkout $source -ExpectedRoot $stage } | Should Throw
        [IO.File]::WriteAllText((Join-Path $source 'app\extra.php'), 'unexpected')
        { Assert-CanaryAACSource -Checkout $source -ExpectedRoot $stage } | Should Throw
    }
    It 'fails closed on absent and stale audit evidence' {
        Test-CanaryAACAudit -Path (Join-Path $TestDrive 'missing.json') -Checkout $TestDrive | Should Be $false
        $file = Join-Path $TestDrive 'audit.json'
        [IO.File]::WriteAllText($file, '{"SchemaVersion":1,"CreatedUtc":"2000-01-01T00:00:00Z","Passed":true}')
        Test-CanaryAACAudit -Path $file -Checkout $TestDrive | Should Be $false
    }
}
