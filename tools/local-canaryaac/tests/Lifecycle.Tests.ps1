Import-Module (Join-Path $PSScriptRoot '..\CanaryAAC.Local.psm1') -Force
InModuleScope CanaryAAC.Local {
    Describe 'AAC process generation and listener ownership' {
        BeforeEach {
            $script:fake = [pscustomobject]@{ProcessId=123; ExecutablePath='C:\fixture\php.exe'; CommandLine='"C:\fixture\php.exe" -S 127.0.0.1:8080 "C:\fixture\router.php"'; CreationDate=[datetime]'2026-10-07T01:00:00Z'}
            Mock Get-CimInstance { $script:fake }
            Mock Get-NetTCPConnection { [pscustomobject]@{OwningProcess=123; LocalAddress='127.0.0.1'; LocalPort=8080; State='Listen'} }
        }
        It 'accepts only the recorded generation and exact loopback listener' {
            $record = [pscustomobject]@{ProcessId=123; CreatedUtc='2026-10-07T01:00:00.0000000Z'}
            Test-CanaryAACOwnedProcess -Record $record -PhpPath 'C:\fixture\php.exe' -RouterPath 'C:\fixture\router.php' | Should Be $true
        }
        It 'rejects a reused PID without stopping a process' {
            $record = [pscustomobject]@{ProcessId=123; CreatedUtc='2026-10-06T01:00:00.0000000Z'}
            Test-CanaryAACOwnedProcess -Record $record -PhpPath 'C:\fixture\php.exe' -RouterPath 'C:\fixture\router.php' | Should Be $false
        }
        It 'rejects a router substring and foreign listener' {
            $record = [pscustomobject]@{ProcessId=123; CreatedUtc='2026-10-07T01:00:00.0000000Z'}
            $script:fake.CommandLine = 'php -S 127.0.0.1:8080 C:\fixture\router.php.other'
            Test-CanaryAACOwnedProcess -Record $record -PhpPath 'C:\fixture\php.exe' -RouterPath 'C:\fixture\router.php' | Should Be $false
            $script:fake.CommandLine = 'php -S 127.0.0.1:8080 C:\fixture\router.php'
            Mock Get-NetTCPConnection { [pscustomobject]@{OwningProcess=999; LocalAddress='127.0.0.1'; LocalPort=8080; State='Listen'} }
            Test-CanaryAACOwnedProcess -Record $record -PhpPath 'C:\fixture\php.exe' -RouterPath 'C:\fixture\router.php' | Should Be $false
        }
    }
}
