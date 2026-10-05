$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $here
Import-Module (Join-Path $toolRoot 'CanaryAAC.Local.psm1') -Force

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
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $php = Join-Path $repo '.tools\php\php.exe'
        if (-not (Test-Path -LiteralPath $php)) { Set-TestInconclusive 'Pinned PHP is not installed yet.'; return }
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
