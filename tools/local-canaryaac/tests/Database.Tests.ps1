$toolRoot = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $toolRoot 'sql\001-canaryaac-local.sql'
$initializerPath = Join-Path $toolRoot 'Initialize-CanaryAACDatabase.ps1'
$sql = ''
if (Test-Path -LiteralPath $migrationPath) { $sql = Get-Content -LiteralPath $migrationPath -Raw }
# Load the real validation functions without invoking the administrator workflow.
if (Test-Path -LiteralPath $initializerPath) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($initializerPath, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Database initializer has syntax errors.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'CanaryAAC global role privilege source' {
    It 'refuses PUBLIC global UPDATE even when USER_PRIVILEGES returns no role rows' {
        Mock Get-CanaryAACSqlLines {
            if ($Sql -match 'mysql.global_priv') { return "5055424C4943`t`t1`t4" }
            return @()
        }
        { Get-CanaryAACPublicAudit } | Should Throw
    }

    It 'refuses global privileges obtained through an inherited role using the real role audit' {
        Mock Get-CanaryAACSqlLines {
            if ($Sql -match 'mysql.roles_mapping' -and $Sql -match "User='PUBLIC'") { return "777269746572`tN" }
            if ($Sql -match 'mysql.global_priv' -and $Sql -match "User='PUBLIC'") { return "5055424C4943`t`t1`t0" }
            if ($Sql -match 'mysql.global_priv' -and $Sql -match "User='writer'") { return "777269746572`t`t1`t4" }
            return @()
        }
        { Get-CanaryAACPublicAudit } | Should Throw
    }

    It 'allows only exact role identity with a valid unsigned zero global access value' {
        $script:globalFixture = @("6F646427726F6C65`t`t1`t0")
        $script:globalQuery = ''
        Mock Get-CanaryAACSqlLines { $script:globalQuery = $Sql; return $script:globalFixture }
        { Assert-CanaryAACPublicPrivileges @(Get-CanaryAACRoleGlobalPrivileges -Role "odd'role") } | Should Not Throw
        $script:globalQuery | Should Match "BINARY User='odd''role' AND Host=''"
        foreach ($bits in @('1','4','1024','18446744073709551615')) {
            $script:globalFixture = @("6F646427726F6C65`t`t1`t$bits")
            { Assert-CanaryAACPublicPrivileges @(Get-CanaryAACRoleGlobalPrivileges -Role "odd'role") } | Should Throw
        }
        foreach ($malformed in @("6F646427726F6C65`t`t1`t-1", "6F646427726F6C65`t`t1`t1e0", "6F646427726F6C65`t`t1`t18446744073709551616", "6F646427726F6C65`t`t1`tNULL", "6F646427726F6C65`t`t0`t0", "6F646427726F6C65`t3132372E302E302E31`t1`t0", "77726F6E67`t`t1`t0", "6F646427726F6C65`t`t1`t0`textra")) {
            $script:globalFixture = @($malformed)
            { Get-CanaryAACRoleGlobalPrivileges -Role "odd'role" } | Should Throw
        }
        $script:globalFixture = @()
        { Get-CanaryAACRoleGlobalPrivileges -Role "odd'role" } | Should Throw
        $script:globalFixture = @("6F646427726F6C65`t`t1`t0", "6F646427726F6C65`t`t1`t0")
        { Get-CanaryAACRoleGlobalPrivileges -Role "odd'role" } | Should Throw
        # '@host' inside the name is still a role name, never an account host.
        $script:globalFixture = @("726561646572406C6F63616C686F7374`t`t1`t0")
        { Assert-CanaryAACPublicPrivileges @(Get-CanaryAACRoleGlobalPrivileges -Role 'reader@localhost') } | Should Not Throw
        $script:globalQuery | Should Match "BINARY User='reader@localhost' AND Host=''"
    }
}

Describe 'CanaryAAC effective grants' {
    It 'allows only the inherited permissions already in the canary contract' {
        $records = @("SCHEMA`t1`tcanary`t*`t*`tSELECT`tNO", "TABLE`t1`tcanary`taccounts`t*`tINSERT`tNO", "COLUMN`t1`tcanary`tplayers`tname`tSELECT`tNO", "SCHEMA`t0`ttest\\_%`t*`t*`tDELETE`tNO")
        { Assert-CanaryAACPublicPrivileges -Records $records } | Should Not Throw
        foreach ($unsafe in @("GLOBAL`t1`t*`t*`t*`tSELECT`tNO", "SCHEMA`t1`tcan%`t*`t*`tUPDATE`tNO", "TABLE`t1`tcanary`tcanary_samples`t*`tINSERT`tNO", "COLUMN`t1`tcanary`taccounts`tname`tUPDATE`tNO", "ROUTINE`t1`tcanary`tunsafe_proc`tPROCEDURE`tExecute`tNO", "SCHEMA`t1`tcanary`t*`t*`tSELECT`tYES", "ROLEADMIN`t1`t*`twriter`t*`tADMIN`tYES")) {
            { Assert-CanaryAACPublicPrivileges -Records @($unsafe) } | Should Throw
        }
    }

    It 'audits nested PUBLIC roles and refuses their effective unsafe privileges' {
        Mock Get-CanaryAACSqlLines {
            if ($Sql -match 'mysql.roles_mapping' -and $Sql -match "User='PUBLIC'") { return "726561646572`tN" }
            if ($Sql -match 'mysql.roles_mapping' -and $Sql -match "User='reader'") { return "777269746572`tN" }
            if ($Sql -match 'mysql.roles_mapping' -and $Sql -match "User='writer'") { return "5055424C4943`tN" }
            return @()
        }
        Mock Get-CanaryAACRolePrivileges {
            if ($Role -eq 'reader') { return "SCHEMA`t1`tcanary`t*`t*`tSELECT`tNO" }
            if ($Role -eq 'writer') { return "TABLE`t1`tcanary`tplayers`t*`tDELETE`tNO" }
            return @()
        }
        { Get-CanaryAACPublicAudit } | Should Throw
    }

    It 'queries every MariaDB privilege scope and treats schema wildcard grants as applicable' {
        $capturedQueries = [Collections.Generic.List[string]]::new()
        Mock Get-CanaryAACSqlLines { $capturedQueries.Add($Sql); if ($Sql -match 'mysql.global_priv') { return "6F646427726F6C65`t`t1`t0" }; return @() }
        # Pester 3 keeps the preceding role fixture mock for this Describe;
        # execute the production body directly while capturing SQL calls.
        $realPrivileges = [scriptblock]::Create($ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CanaryAACRolePrivileges' }, $false).Body.Extent.Text.Trim('{', '}'))
        $null = & $realPrivileges -Role "odd'role"
        $capturedQueries.Count | Should Be 6
        foreach ($scope in @('mysql.global_priv','SCHEMA_PRIVILEGES','TABLE_PRIVILEGES','COLUMN_PRIVILEGES','mysql.procs_priv','mysql.proxies_priv')) {
            @($capturedQueries | Where-Object { $_.Contains($scope) }).Count | Should Be 1
        }
        @($capturedQueries | Where-Object { $_.Contains("IF('canary' LIKE TABLE_SCHEMA,1,0)") }).Count | Should Be 1
        foreach ($query in $capturedQueries) { $query | Should Match "odd''role" }
        $capturedQueries[5] | Should Match "BINARY User='odd''role' AND Host=''"
    }

    It 'escapes every proxied identity while revoking only the exact runtime grantee' {
        $sql = New-CanaryAACProxyRevocations @([pscustomobject] @{ User = "odd'user"; Host = '127.0.0.2' })
        $sql | Should Be "REVOKE PROXY ON 'odd''user'@'127.0.0.2' FROM 'canaryaac_local'@'127.0.0.1';"
    }

    It 'refuses residual runtime roles, proxy grants and routine privileges' {
        Mock Get-CanaryAACSqlLines { if ($Sql -match 'mysql.proxies_priv') { return "726F6F74`t6C6F63616C686F7374" }; return @() }
        { Assert-CanaryAACNoIndirectRuntimeGrants } | Should Throw
        Mock Get-CanaryAACSqlLines { if ($Sql -match 'mysql.roles_mapping') { return 'writer' }; return @() }
        { Assert-CanaryAACNoIndirectRuntimeGrants } | Should Throw
        Mock Get-CanaryAACSqlLines { if ($Sql -match 'mysql.procs_priv') { return 'Execute' }; return @() }
        { Assert-CanaryAACNoIndirectRuntimeGrants } | Should Throw
        Mock Get-CanaryAACSqlLines { return @() }
        { Assert-CanaryAACNoIndirectRuntimeGrants } | Should Not Throw
    }
}

Describe 'CanaryAAC private permanent artifacts' {
    It 'replaces broad inherited and explicit read grants on directories and files' {
        $root = Join-Path $TestDrive 'private-artifacts'
        New-Item -ItemType Directory -Path $root | Out-Null
        $file = Join-Path $root 'backup.sql'
        [IO.File]::WriteAllText($file, 'fixture-data')
        $unsafeAcl = Get-Acl -LiteralPath $file
        foreach ($sid in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')) {
            $unsafeAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'Read', 'Allow'))
        }
        $sandbox = [Security.Principal.NTAccount]::new($env:COMPUTERNAME, 'CodexSandboxUsers').Translate([Security.Principal.SecurityIdentifier])
        $unsafeAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sandbox, 'Read', 'Allow'))
        Set-Acl -LiteralPath $file -AclObject $unsafeAcl
        { Assert-CanaryAACPrivateAcl -Path $file } | Should Throw
        Set-CanaryAACPrivateAcl -Root $TestDrive -Path $root
        Set-CanaryAACPrivateAcl -Root $root -Path $file
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try { Set-CanaryAACPrivateAcl -Root $TestDrive -Path $root; Set-CanaryAACPrivateAcl -Root $root -Path $file }
        finally { $ErrorActionPreference = $saved }
        foreach ($path in @($root, $file)) {
            { Assert-CanaryAACPrivateAcl -Path $path } | Should Not Throw
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should Be $true
            $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
            foreach ($rule in $acl.Access) {
                if ($rule.AccessControlType -eq 'Allow') { $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $allowed | Should Be $true }
            }
        }
        [IO.File]::ReadAllText($file) | Should Be 'fixture-data'
    }

    It 'protects existing backup descendants without following a redirect' {
        $root = Join-Path $TestDrive 'backup-acl-tree'
        $sub = Join-Path $root 'session'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $file = Join-Path $sub 'evidence.json'
        [IO.File]::WriteAllText($file, 'fixture')
        Protect-CanaryAACBackupTree -Root $root
        { Assert-CanaryAACPrivateAcl -Path $file } | Should Not Throw
        $outside = Join-Path $TestDrive 'acl-outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        $redirect = Join-Path $root 'redirect'
        New-Item -ItemType Junction -Path $redirect -Target $outside | Out-Null
        try { { Protect-CanaryAACBackupTree -Root $root } | Should Throw }
        finally { [IO.Directory]::Delete($redirect) }
    }
}

Describe 'CanaryAAC atomic dotenv publication' {
    BeforeEach {
        $realPublication = [scriptblock]::Create($ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CanaryAACAtomicFilePublication' }, $false).Body.Extent.Text.Trim('{', '}'))
        Mock Invoke-CanaryAACAtomicFilePublication { & $realPublication -Source $Source -Destination $Destination }
        $realPrivateWriter = [scriptblock]::Create($ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-CanaryAACPrivateText' }, $false).Body.Extent.Text.Trim('{', '}'))
        Mock Write-CanaryAACPrivateText { & $realPrivateWriter -Root $Root -Path $Path -Text $Text }
        $runtimeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sessionRoot = Join-Path $runtimeRoot 'private-stage'
        New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
        $destination = Join-Path $runtimeRoot '.env'
        $values = [ordered] @{ URL = 'http://127.0.0.1:8080'; DB_PASS = 'fixture new#value' }
    }

    It 'keeps prior dotenv bytes intact when publication fails after staging' {
        [IO.File]::WriteAllText($destination, 'DB_PASS=fixture-old')
        $before = [IO.File]::ReadAllBytes($destination)
        Mock Invoke-CanaryAACAtomicFilePublication { throw 'controlled pre-publication failure' }
        { Publish-CanaryAACDotEnv -Root $runtimeRoot -SessionRoot $sessionRoot -Destination $destination -Values $values } | Should Throw 'controlled pre-publication failure'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) | Should Be ([Convert]::ToBase64String($before))
        @(Get-ChildItem -LiteralPath $sessionRoot -Force).Count | Should Be 0
    }

    It 'rejects changed raw staging bytes before publishing even when all keys still parse' {
        [IO.File]::WriteAllText($destination, 'DB_PASS=fixture-old')
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination))
        Mock Write-CanaryAACPrivateText {
            Initialize-CanaryAACPrivateFile -Root $Root -Path $Path
            [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
        }
        { Publish-CanaryAACDotEnv -Root $runtimeRoot -SessionRoot $sessionRoot -Destination $destination -Values $values } | Should Throw
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) | Should Be $before
        @(Get-ChildItem -LiteralPath $sessionRoot -Force).Count | Should Be 0
    }

    It 'replaces an existing dotenv atomically and verifies its bytes and private ACL' {
        [IO.File]::WriteAllText($destination, 'DB_PASS=fixture-old')
        Publish-CanaryAACDotEnv -Root $runtimeRoot -SessionRoot $sessionRoot -Destination $destination -Values $values
        [IO.File]::ReadAllText($destination) | Should Be "URL='http://127.0.0.1:8080'`nDB_PASS='fixture new#value'`n"
        { Assert-CanaryAACPrivateAcl -Path $destination } | Should Not Throw
        @(Get-ChildItem -LiteralPath $sessionRoot -Force).Count | Should Be 0
    }

    It 'moves a new dotenv from private staging and rejects incomplete or duplicate keys' {
        Publish-CanaryAACDotEnv -Root $runtimeRoot -SessionRoot $sessionRoot -Destination $destination -Values $values
        { Assert-CanaryAACDotEnvDocument -Text ([IO.File]::ReadAllText($destination)) -Values $values } | Should Not Throw
        { Assert-CanaryAACDotEnvDocument -Text "DB_PASS='fixture new#value'`n" -Values $values } | Should Throw
        { Assert-CanaryAACDotEnvDocument -Text "URL='http://127.0.0.1:8080'`nURL='http://127.0.0.1:8080'`nDB_PASS='fixture new#value'`n" -Values $values } | Should Throw
    }
}

Describe 'CanaryAAC restoration byte parity' {
    It 'drops the validated restore database when CREATE commits and the client then times out' {
        $script:fixtureRestoreExists = $false
        Mock Invoke-CanaryAACSql {
            if ($Sql -ceq 'CREATE DATABASE `canaryaac_restore_20261005123456_a0b1c2d3` CHARACTER SET utf8mb4;') { $script:fixtureRestoreExists = $true; throw 'controlled timeout after server CREATE' }
            if ($Sql -ceq 'DROP DATABASE IF EXISTS `canaryaac_restore_20261005123456_a0b1c2d3`;') { $script:fixtureRestoreExists = $false; return }
            throw 'Unexpected restoration SQL.'
        }
        { Invoke-CanaryAACRestoreVerification -RestoreDatabase 'canaryaac_restore_20261005123456_a0b1c2d3' -DumpPath 'fixture.sql' } | Should Throw 'controlled timeout after server CREATE'
        $script:fixtureRestoreExists | Should Be $false
    }

    It 'never attempts CREATE or DROP for an unvalidated restore identity' {
        $script:fixtureCoreExists = $true
        $script:fixtureSqlCalls = 0
        Mock Invoke-CanaryAACSql { $script:fixtureCoreExists = $false; $script:fixtureSqlCalls++ }
        { Invoke-CanaryAACRestoreVerification -RestoreDatabase 'canary' -DumpPath 'fixture.sql' } | Should Throw
        $script:fixtureCoreExists | Should Be $true
        $script:fixtureSqlCalls | Should Be 0
    }

    It 'aborts when restored values differ despite unchanged row counts' {
        $before = Join-Path $TestDrive 'live-before.tsv'
        $restored = Join-Path $TestDrive 'restored.tsv'
        [IO.File]::WriteAllText($before, "31`t4142`n")
        [IO.File]::WriteAllText($restored, "31`t4143`n")
        Mock Invoke-CanaryAACSql { $restored }
        $baseline = @([pscustomobject] @{ Table = 'accounts'; Columns = @('id','name'); ExportPath = $before })
        { Assert-CanaryAACRestoredRows -RestoreDatabase 'canaryaac_restore_20261005123456_a0b1c2d3' -Baselines $baseline } | Should Throw
        [IO.File]::WriteAllText($restored, "31`t4142`n")
        { Assert-CanaryAACRestoredRows -RestoreDatabase 'canaryaac_restore_20261005123456_a0b1c2d3' -Baselines $baseline } | Should Not Throw
    }
}

Describe 'CanaryAAC native process deadlines' {
    It 'captures controlled process output and errors before returning' {
        $runtimeRoot = Join-Path $TestDrive 'native-success'
        $sessionRoot = Join-Path $runtimeRoot 'session'
        New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
        $script = Join-Path $runtimeRoot 'success.ps1'
        [IO.File]::WriteAllText($script, "[Console]::WriteLine('fixture-out'); [Console]::Error.WriteLine('fixture-error')")
        $shell = Join-Path $PSHOME 'powershell.exe'
        $output = Invoke-CanaryAACDatabaseProcess -Executable $shell -Arguments @('-NoProfile','-NonInteractive','-File',$script) -TimeoutSeconds 5
        [IO.File]::ReadAllText($output).Trim() | Should Be 'fixture-out'
        $errorFile = @(Get-ChildItem -LiteralPath $sessionRoot -Filter '*.err')[0]
        [IO.File]::ReadAllText($errorFile.FullName).Trim() | Should Be 'fixture-error'
    }

    It 'terminates only its timed-out process tree and waits before stdin cleanup' {
        $runtimeRoot = Join-Path $TestDrive 'native-timeout'
        $sessionRoot = Join-Path $runtimeRoot 'session'
        New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
        $script = Join-Path $runtimeRoot 'timeout.ps1'
        $marker = Join-Path $runtimeRoot 'identities.json'
        $inputFile = Join-Path $runtimeRoot 'stdin.txt'
        [IO.File]::WriteAllText($inputFile, 'fixture-input')
        $shell = Join-Path $PSHOME 'powershell.exe'
        $program = @'
param([string] $Marker)
$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -WindowStyle Hidden -PassThru
[pscustomobject] @{ RootId=$PID; RootTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks; ChildId=$child.Id; ChildTicks=$child.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json | Set-Content -LiteralPath $Marker
Start-Sleep -Seconds 4
'@
        [IO.File]::WriteAllText($script, $program)
        $unrelated = Start-Process -FilePath $shell -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -WindowStyle Hidden -PassThru
        $identities = $null
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-CanaryAACDatabaseProcess -Executable $shell -Arguments @('-NoProfile','-NonInteractive','-File',$script,'-Marker',$marker) -InputPath $inputFile -TimeoutSeconds 2 } | Should Throw 'timed out'
            $timer.Elapsed.TotalSeconds | Should BeLessThan 10
            $identities = [IO.File]::ReadAllText($marker) | ConvertFrom-Json
            foreach ($identity in @(@($identities.RootId,$identities.RootTicks), @($identities.ChildId,$identities.ChildTicks))) {
                $current = Get-Process -Id $identity[0] -ErrorAction SilentlyContinue
                ($null -eq $current -or $current.StartTime.ToUniversalTime().Ticks -ne $identity[1]) | Should Be $true
            }
            $unrelated.HasExited | Should Be $false
            Test-Path -LiteralPath $inputFile | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $marker) { $identities = [IO.File]::ReadAllText($marker) | ConvertFrom-Json }
            if ($null -ne $identities) {
                $child = Get-Process -Id $identities.ChildId -ErrorAction SilentlyContinue
                if ($null -ne $child -and $child.StartTime.ToUniversalTime().Ticks -eq $identities.ChildTicks) { $child.Kill(); $null=$child.WaitForExit(5000); $child.Dispose() }
            }
            if (-not $unrelated.HasExited) { $unrelated.Kill(); $null=$unrelated.WaitForExit(5000) }
            $unrelated.Dispose()
        }
    }
}

Describe 'CanaryAAC database migration' {
    It 'has a separately reviewable adapted migration' {
        Test-Path -LiteralPath $migrationPath -PathType Leaf | Should Be $true
    }

    It 'never imports destructive upstream statements' {
        $sql | Should Not Match '(?i)DROP\s+(INDEX|TABLE)'
        $sql | Should Not Match '(?i)(DELETE|INSERT|UPDATE)\s+(FROM\s+|INTO\s+)?`?(accounts|players)`?'
        $sql | Should Not Match '(?i)MODIFY\s+(COLUMN\s+)?`?creation`?'
        $sql | Should Not Match '(?i)\b(TRUNCATE|REPLACE|CHANGE|FOREIGN\s+KEY)\b'
    }

    It 'only adds the three permitted core columns' {
        $alter = @([regex]::Matches($sql, '(?im)^ALTER TABLE [^\r\n]+;(?=\r?$)') | ForEach-Object { $_.Value })
        $alter.Count | Should Be 3
        $alter[0] | Should Be 'ALTER TABLE `accounts` ADD COLUMN IF NOT EXISTS `page_access` INT NOT NULL DEFAULT 0;'
        $alter[1] | Should Be 'ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `main` INT NOT NULL DEFAULT 0;'
        $alter[2] | Should Be 'ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `world` INT NOT NULL DEFAULT 0;'
    }

    It 'creates exactly the six AAC tables with InnoDB and utf8mb4' {
        $tables = @([regex]::Matches($sql, '(?i)CREATE TABLE IF NOT EXISTS `([^`]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        ($tables -join ',') | Should Be 'canary_countdowns,canary_polls,canary_polls_questions,canary_samples,canary_website,canary_worlds'
        [regex]::Matches($sql, 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4').Count | Should Be 6
    }

    It 'contains all five vocation seeds with complete Thais defaults' {
        foreach ($vocation in 1, 2, 3, 4, 9) {
            $sql | Should Match "\($vocation,\s*$vocation,\s*4200,\s*8,\s*185,\s*185,\s*0,\s*90,\s*90,\s*0,\s*0,\s*8,\s*32369,\s*32241,\s*7,\s*470,\s*0,\s*113,\s*115,\s*95,\s*39,\s*129,\s*0\)"
        }
        [regex]::Matches($sql, '(?i)ON DUPLICATE KEY UPDATE').Count | Should Be 3
    }

    It 'disables every payment flag and uses the local world' {
        $sql | Should Match "\(1, 'America/Sao_Paulo', 'Canary Local', '', '', 1, 10, 100, 0, 0\.00, 0, 0, 0\)"
        $sql | Should Match "\(1, 'Canary Local', 7, 0, 0, 0, 0, 0, '127\.0\.0\.1', 7172\)"
    }
}

Describe 'CanaryAAC database safety boundaries' {
    It 'wires effective grants, private publication and restored-byte gates into the live workflow' {
        $source = [IO.File]::ReadAllText($initializerPath)
        $main = $source.Substring($source.IndexOf('$repositoryRoot ='))
        $main | Should Match 'Protect-CanaryAACBackupTree -Root \$backupRoot'
        [regex]::Matches($main, 'Get-CanaryAACPublicAudit').Count | Should Be 2
        $main | Should Match 'Invoke-CanaryAACRestoreVerification -RestoreDatabase \$restoreName -DumpPath \$dumpPath -CountSql \$countSql -LiveCounts \$liveCounts -Baselines \$baselines'
        $main | Should Match 'New-CanaryAACGrantSql -Password \$runtimePassword -Roles \$roles -Proxies \$proxies'
        $main | Should Match 'Assert-CanaryAACNoIndirectRuntimeGrants'
        $main | Should Match "PRIVILEGE_TYPE <> 'USAGE' OR IS_GRANTABLE <> 'NO'"
        $main | Should Match 'Publish-CanaryAACDotEnv -Root \$runtimeRoot'
        $main | Should Not Match '\[IO.File\]::WriteAllText\(\$envPath'
        $main | Should Not Match '\[IO.File\]::WriteAllText\(\$evidencePath'
        $main | Should Not Match 'restoreCreated -and'
        ($main.IndexOf('Protect-CanaryAACBackupTree') -lt $main.IndexOf('$null = Invoke-CanaryAACDatabaseProcess')) | Should Be $true
        ($main.IndexOf('Invoke-CanaryAACRestoreVerification') -lt $main.IndexOf('for ($pass =')) | Should Be $true
    }

    It 'returns plain SQL result strings without provider metadata in evidence' {
        $output = Join-Path $TestDrive 'plain-results.tsv'
        [IO.File]::WriteAllText($output, "id`nname`n")
        Mock Invoke-CanaryAACSql { $output }
        $results = @(Get-CanaryAACSqlLines 'SELECT fixture;')
        ($results -join ',') | Should Be 'id,name'
        @($results[0].PSObject.Properties | Where-Object { $_.Name -in @('PSPath', 'PSDrive', 'PSProvider') }).Count | Should Be 0
    }

    It 'passes an administrator username as exactly one native option' {
        $arguments = @(Get-CanaryAACConnectionArguments 'fixture user')
        $arguments.Count | Should Be 6
        $arguments[4] | Should Be '--user=fixture user'
    }

    It 'keeps literal SQL backticks in GOD and sample queries' {
        (Get-CanaryAACSpecialPlayerQuery -Columns @('id') -Kind God) | Should Be 'SELECT IF(`id` IS NULL,''NULL'',HEX(CAST(`id` AS BINARY))) FROM `players` WHERE `name`=''GOD'' ORDER BY `id`;'
        (Get-CanaryAACSpecialPlayerQuery -Columns @('id') -Kind Samples) | Should Be 'SELECT IF(`id` IS NULL,''NULL'',HEX(CAST(`id` AS BINARY))) FROM `players` WHERE `name` LIKE ''% Sample'' ORDER BY `id`;'
    }

    It 'emits credential SQL only for the exact runtime user and approved grants' {
        $grantSql = New-CanaryAACGrantSql -Password "fixture'quote\slash" -Roles @('old-role')
        $grantSql | Should Match "IDENTIFIED BY 'fixture''quote\\slash'"
        $grantSql | Should Match 'REVOKE `old-role` FROM ''canaryaac_local''@''127\.0\.0\.1'''
        $grantSql | Should Match 'GRANT SELECT ON canary\.\*'
        $grantSql | Should Match 'GRANT INSERT ON canary\.accounts'
        $grantSql | Should Match 'GRANT INSERT ON canary\.players'
        $grantSql | Should Not Match '[\x00-\x08\x0b\x0c\x0e-\x1f]'
    }

    It 'accepts only generated restoration database identities' {
        { Assert-CanaryAACRestoreName 'canaryaac_restore_20261005123456_a0b1c2d3' } | Should Not Throw
        foreach ($unsafe in @('canary', 'canaryaac_restore_20261005123456_a0b1c2d3;DROP DATABASE canary', 'canaryaac_restore_20261005123456_A0B1C2D3', 'canaryaac_restore_20261005123456_a0b1c2d3_extra')) {
            { Assert-CanaryAACRestoreName $unsafe } | Should Throw
        }
    }

    It 'rejects empty dumps and either missing core table' {
        $dump = Join-Path $TestDrive 'dump.sql'
        [IO.File]::WriteAllText($dump, '')
        { Assert-CanaryAACDump $dump } | Should Throw
        [IO.File]::WriteAllText($dump, 'CREATE TABLE `accounts` (id INT);')
        { Assert-CanaryAACDump $dump } | Should Throw
        [IO.File]::WriteAllText($dump, 'CREATE TABLE `players` (id INT);')
        { Assert-CanaryAACDump $dump } | Should Throw
        [IO.File]::WriteAllText($dump, "CREATE TABLE ``accounts`` (id INT);`nCREATE TABLE ``players`` (id INT);")
        { Assert-CanaryAACDump $dump } | Should Not Throw
    }

    It 'escapes SQL identifiers and values without backslash interpretation' {
        (ConvertTo-CanaryAACSqlIdentifier 'a`b') | Should Be '`a``b`'
        (ConvertTo-CanaryAACSqlLiteral "a'b\c") | Should Be "'a''b\c'"
    }

    It 'rejects path escapes and alternate streams' {
        $root = Join-Path $TestDrive 'boundary'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        { Assert-CanaryAACDatabasePath -Root $root -Path (Join-Path $root 'backups\safe.json') } | Should Not Throw
        { Assert-CanaryAACDatabasePath -Root $root -Path (Join-Path $root '..\outside.json') } | Should Throw
        { Assert-CanaryAACDatabasePath -Root $root -Path (Join-Path $root 'safe.json:stream') } | Should Throw
    }

    It 'rejects junctions at backup and env destinations before writing' {
        $root = Join-Path $TestDrive 'redirect-root'
        $outside = Join-Path $TestDrive 'redirect-target'
        New-Item -ItemType Directory -Path $root, $outside -Force | Out-Null
        $link = Join-Path $root 'backups'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try {
            { Assert-CanaryAACDatabasePath -Root $root -Path (Join-Path $link 'evidence.json') } | Should Throw
            { Assert-CanaryAACDatabasePath -Root $root -Path (Join-Path $link '.env') } | Should Throw
            @(Get-ChildItem -LiteralPath $outside).Count | Should Be 0
        } finally { [IO.Directory]::Delete($link) }
    }

    It 'retains an existing dotenv password without displaying it' {
        (Read-CanaryAACPassword "DB_PASS=fixture-value`nURL=http://old") | Should Be 'fixture-value'
        (Read-CanaryAACPassword "DB_PASS='a b#c'`n") | Should Be 'a b#c'
        { Read-CanaryAACPassword "URL=http://old`n" } | Should Throw
        { Read-CanaryAACPassword "DB_PASS=one`nDB_PASS=two`n" } | Should Throw
    }

    It 'writes dotenv quotes that preserve whitespace and special characters' {
        (ConvertTo-CanaryAACDotEnvValue 'a b#c$z\path') | Should Be "'a b#c`$z\path'"
        { ConvertTo-CanaryAACDotEnvValue "line`nbreak" } | Should Throw
    }

    It 'compares complete row bytes rather than row counts alone' {
        $before = Join-Path $TestDrive 'before.tsv'
        $after = Join-Path $TestDrive 'after.tsv'
        [IO.File]::WriteAllText($before, "1`t4142`tNULL`n")
        [IO.File]::WriteAllText($after, "1`t4142`tNULL`n")
        { Assert-CanaryAACSameExport $before $after } | Should Not Throw
        [IO.File]::WriteAllText($after, "1`t4143`tNULL`n")
        { Assert-CanaryAACSameExport $before $after } | Should Throw
    }
}
