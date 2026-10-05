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
