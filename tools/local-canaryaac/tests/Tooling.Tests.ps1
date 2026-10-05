$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $here
Import-Module (Join-Path $toolRoot 'CanaryAAC.Local.psm1') -Force

Describe 'CanaryAAC local tooling' {
    It 'maps all generated state below .tools' {
        $repo = (Resolve-Path (Join-Path $toolRoot '..\..')).Path
        $layout = Get-CanaryAACLayout -RepositoryRoot $repo
        $layout.RuntimeRoot | Should Be (Join-Path $repo '.tools')
        $layout.Checkout | Should Be (Join-Path $repo '.tools\canaryaac')
        $layout.PidFile | Should Be (Join-Path $repo '.tools\canaryaac.pid')
        $layout.PhpPath | Should Be (Join-Path $repo '.tools\php\php.exe')
        $layout.RouterPath | Should Be (Join-Path $repo '.tools\canaryaac\router.php')
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
                CommandLine = '"C:\repo\.tools\php\php.exe" -S 127.0.0.1:8080 "C:\repo\.tools\canaryaac\router.php"'
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
