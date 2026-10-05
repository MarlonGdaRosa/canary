[CmdletBinding()]
param([Parameter(Mandatory)][PSCredential] $AdminCredential)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CanaryAACRestoreName {
    param([string] $Name)
    if ($Name -cnotmatch '\Acanaryaac_restore_[0-9]{14}_[a-f0-9]{8}\z') { throw 'Unsafe restoration database identity.' }
}

function Assert-CanaryAACDatabasePath {
    param([string] $Root, [string] $Path)
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($Path)
    if ($target -ine $boundary -and -not $target.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Database artifact path escapes its runtime boundary.'
    }
    if ($target.Substring([IO.Path]::GetPathRoot($target).Length).Contains(':')) { throw 'Alternate data stream destination refused.' }
    # Check the destination and every physical ancestor, including ancestors above Root.
    $current = $target
    while (-not [string]::IsNullOrEmpty($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse database artifact destination refused.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-CanaryAACDump {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) { throw 'Backup is missing or empty.' }
    foreach ($table in @('accounts', 'players')) {
        if (-not (Select-String -LiteralPath $Path -Pattern ('^CREATE TABLE `' + $table + '`') -Quiet)) {
            throw "Backup is missing the $table table definition."
        }
    }
}

function ConvertTo-CanaryAACSqlIdentifier {
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value) -or $Value -match '[\x00\r\n]') { throw 'Invalid SQL identifier.' }
    '`' + $Value.Replace('`', '``') + '`'
}

function ConvertTo-CanaryAACSqlLiteral {
    param([AllowEmptyString()][string] $Value)
    if ($Value -match '[\x00\r\n]') { throw 'Invalid SQL literal.' }
    # Every caller first sets NO_BACKSLASH_ESCAPES in its own SQL session.
    "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-CanaryAACDotEnvValue {
    param([AllowEmptyString()][string] $Value)
    if ($Value -match '[\x00\r\n]') { throw 'Multiline dotenv value refused.' }
    if ($Value -notmatch "'") { return "'" + $Value + "'" }
    # phpdotenv double quotes interpret dollar signs and backslashes.
    '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$') + '"'
}

function Read-CanaryAACPassword {
    param([string] $Text)
    $entries = @([regex]::Matches($Text, '(?m)^DB_PASS[ \t]*=[ \t]*([^\r\n]*)\r?$'))
    if ($entries.Count -ne 1) { throw 'Existing dotenv must contain exactly one DB_PASS.' }
    $value = $entries[0].Groups[1].Value.Trim()
    if ($value.StartsWith("'") -and $value.EndsWith("'")) { return $value.Substring(1, $value.Length - 2) }
    if ($value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
        if ($value -match '(?<!\\)\$') { throw 'Interpolated dotenv passwords are not supported.' }
        return [regex]::Replace($value, '\\([\\"$])', '$1')
    }
    if ($value -match '[\s#"''$]') { throw 'Ambiguous unquoted dotenv password refused.' }
    $value
}

function Assert-CanaryAACSameExport {
    param([string] $Before, [string] $After)
    # SHA-256 verifies the complete ordered, lossless export, including NULLs and blobs.
    if ((Get-Item -LiteralPath $Before).Length -ne (Get-Item -LiteralPath $After).Length -or
        (Get-FileHash -LiteralPath $Before -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $After -Algorithm SHA256).Hash) {
        throw 'Preexisting database rows or core schema changed.'
    }
}

function ConvertTo-CanaryAACWindowsArgument {
    param([string] $Value)
    if ($Value -match '[\x00\r\n]') { throw 'Invalid native process argument.' }
    # Start-Process joins ArgumentList; quote for the Windows native argv parser.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Get-CanaryAACConnectionArguments {
    param([string] $User)
    @('--no-defaults', '--protocol=TCP', '--host=127.0.0.1', '--port=3306', ('--user=' + $User), '--default-character-set=utf8mb4')
}

function Get-CanaryAACSpecialPlayerQuery {
    param([string[]] $Columns, [ValidateSet('God', 'Samples')][string] $Kind)
    $where = '`name`=''GOD'''
    if ($Kind -eq 'Samples') { $where = '`name` LIKE ''% Sample''' }
    Get-CanaryAACExportQuery -Table players -Columns $Columns -Where $where
}

function New-CanaryAACGrantSql {
    param([string] $Password, [string[]] $Roles)
    $account = "'canaryaac_local'@'127.0.0.1'"
    $passwordSql = ConvertTo-CanaryAACSqlLiteral $Password
    $revocations = @($Roles | ForEach-Object { 'REVOKE ' + (ConvertTo-CanaryAACSqlIdentifier $_) + " FROM $account;" }) -join "`n"
    @"
CREATE USER IF NOT EXISTS $account IDENTIFIED BY $passwordSql;
ALTER USER $account IDENTIFIED BY $passwordSql;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM $account;
$revocations
GRANT SELECT ON canary.* TO $account;
GRANT INSERT ON canary.accounts TO $account;
GRANT INSERT ON canary.players TO $account;
FLUSH PRIVILEGES;
"@
}

function Invoke-CanaryAACDatabaseProcess {
    param([string] $Executable, [string[]] $Arguments, [string] $InputPath, [string] $OutputPath)
    if ([string]::IsNullOrEmpty($OutputPath)) { $OutputPath = Join-Path $sessionRoot ($([guid]::NewGuid().ToString('N')) + '.out') }
    $errorPath = Join-Path $sessionRoot ($([guid]::NewGuid().ToString('N')) + '.err')
    foreach ($path in @($OutputPath, $errorPath)) { Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $path }
    $start = @{
        FilePath = $Executable; ArgumentList = (@($Arguments | ForEach-Object { ConvertTo-CanaryAACWindowsArgument $_ }) -join ' ')
        RedirectStandardOutput = $OutputPath; RedirectStandardError = $errorPath
        NoNewWindow = $true; Wait = $true; PassThru = $true
    }
    if (-not [string]::IsNullOrEmpty($InputPath)) {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $InputPath
        $start.RedirectStandardInput = $InputPath
    }
    $process = Start-Process @start
    try {
        if ($process.ExitCode -ne 0) {
            # MariaDB errors may repeat credential-bearing SQL; never echo stderr.
            throw "MariaDB operation failed (exit $($process.ExitCode)); database credentials and SQL errors are suppressed."
        }
    } finally { $process.Dispose() }
    $OutputPath
}

function Invoke-CanaryAACSql {
    param([string] $Sql, [string] $Database, [string] $OutputPath)
    $input = Join-Path $sessionRoot ($([guid]::NewGuid().ToString('N')) + '.sql')
    Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $input
    [IO.File]::WriteAllText($input, "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';`n" + $Sql + "`n", [Text.UTF8Encoding]::new($false))
    try {
        $arguments = @($connectionArguments + @('--batch', '--raw', '--skip-column-names', '--binary-mode', '--local-infile=0'))
        if (-not [string]::IsNullOrEmpty($Database)) { $arguments += '--database=' + $Database }
        Invoke-CanaryAACDatabaseProcess -Executable $client -Arguments $arguments -InputPath $input -OutputPath $OutputPath
    } finally {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $input
        Remove-Item -LiteralPath $input -Force
    }
}

function Get-CanaryAACSqlLines {
    param([string] $Sql, [string] $Database = 'canary')
    $output = Invoke-CanaryAACSql -Sql $Sql -Database $Database
    # PowerShell 5 Get-Content decorates strings with PSDrive/PSProvider metadata;
    # JSON then traverses that object graph. Keep evidence values plain strings.
    [IO.File]::ReadAllLines($output, [Text.Encoding]::UTF8)
}

function Get-CanaryAACProjection {
    param([string[]] $Columns)
    # NULL is distinct from empty bytes; HEX is lossless for binary and text.
    # Cast numeric values to their full textual bytes before HEX: HEX(number)
    # encodes the integer itself and would truncate decimal fractions.
    (@($Columns | ForEach-Object { 'IF(' + (ConvertTo-CanaryAACSqlIdentifier $_) + ' IS NULL,''NULL'',HEX(CAST(' + (ConvertTo-CanaryAACSqlIdentifier $_) + ' AS BINARY)))' }) -join ',')
}

function Get-CanaryAACExportQuery {
    param([string] $Table, [string[]] $Columns, [string] $Where)
    $query = 'SELECT ' + (Get-CanaryAACProjection $Columns) + ' FROM ' + (ConvertTo-CanaryAACSqlIdentifier $Table)
    if (-not [string]::IsNullOrEmpty($Where)) { $query += ' WHERE ' + $Where }
    $query + ' ORDER BY `id`;'
}

function Get-CanaryAACRowEvidence {
    param([string] $Path)
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($line))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $idHex = ($line -split "`t", 2)[0]
        $idBytes = [byte[]] @(for ($index = 0; $index -lt $idHex.Length; $index += 2) { [Convert]::ToByte($idHex.Substring($index, 2), 16) })
        [pscustomobject] @{ Id = [Text.Encoding]::UTF8.GetString($idBytes); Sha256 = $hash }
    }
}

function Assert-CanaryAACCoreInvariants {
    $creation = @(Get-CanaryAACSqlLines "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='canary' AND TABLE_NAME='accounts' AND COLUMN_NAME='creation';")
    if ($creation.Count -ne 1 -or $creation[0] -notmatch '^int(?:\([0-9]+\))? unsigned$') { throw 'accounts.creation must remain an unsigned integer.' }
    $indexes = @(Get-CanaryAACSqlLines "SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='canary' AND ((TABLE_NAME='accounts' AND INDEX_NAME='accounts_unique') OR (TABLE_NAME='players' AND INDEX_NAME='players_unique')) ORDER BY TABLE_NAME,SEQ_IN_INDEX;")
    if ($indexes.Count -ne 2 -or $indexes[0] -cne "accounts`taccounts_unique`t0" -or $indexes[1] -cne "players`tplayers_unique`t0") { throw 'Required core unique indexes are missing.' }
    $fk = @(Get-CanaryAACSqlLines "SELECT TABLE_NAME, REFERENCED_TABLE_NAME, DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='canary' AND CONSTRAINT_NAME='players_account_fk';")
    if ($fk.Count -ne 1 -or $fk[0] -cne "players`taccounts`tCASCADE") { throw 'players_account_fk must retain ON DELETE CASCADE.' }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtimeRoot = Join-Path $repositoryRoot '.tools'
$runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force
if ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    # Worktree .tools may only be the existing shared-runtime junction. Resolve
    # that one identity first, then reject every reparse point in physical paths.
    $commonGit = & git -C $repositoryRoot rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve shared runtime identity.' }
    $expected = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $commonGit) '.tools'))
    if ($runtimeItem.LinkType -ne 'Junction' -or @($runtimeItem.Target).Count -ne 1 -or
        [IO.Path]::GetFullPath($runtimeItem.Target[0]) -ine $expected) { throw 'Unauthorized runtime reparse point.' }
    $runtimeRoot = $expected
}
$backupRoot = Join-Path $runtimeRoot 'backups'
$envPath = Join-Path $runtimeRoot 'canaryaac\.env'
$client = Join-Path $runtimeRoot 'mariadb\bin\mariadb.exe'
$dumpClient = Join-Path $runtimeRoot 'mariadb\bin\mariadb-dump.exe'
foreach ($path in @($runtimeRoot, $backupRoot, $envPath, $client, $dumpClient)) { Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $path }
foreach ($path in @($client, $dumpClient, (Join-Path $runtimeRoot 'canaryaac\includes\app.php'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Required MariaDB tool or installed CanaryAAC checkout is missing.' }
}
if ((Get-Service -Name CanaryMariaDB).Status -ne 'Running') { throw 'CanaryMariaDB must already be running.' }
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$sessionRoot = Join-Path $backupRoot ('canaryaac-db-' + [guid]::NewGuid().ToString('N'))
Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $sessionRoot
New-Item -ItemType Directory -Path $sessionRoot | Out-Null
# Restrict transient SQL (including the runtime password) and evidence to the
# current Windows principal. No password ever appears in native arguments.
$principal = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
Set-Acl -LiteralPath $sessionRoot -AclObject $acl
$previousPassword = [Environment]::GetEnvironmentVariable('MYSQL_PWD', 'Process')
$connectionArguments = @(Get-CanaryAACConnectionArguments $AdminCredential.UserName)
$databaseLock = $null
$lockPath = Join-Path $backupRoot 'canaryaac-database.lock'
$evidence = $null
$evidencePath = $null
try {
    Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $lockPath
    $databaseLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    [Environment]::SetEnvironmentVariable('MYSQL_PWD', $AdminCredential.GetNetworkCredential().Password, 'Process')
    $version = @(Get-CanaryAACSqlLines 'SELECT VERSION();')[0]
    if ([string]::IsNullOrEmpty($version)) { throw 'MariaDB version probe failed.' }
    $scheduler = @(Get-CanaryAACSqlLines 'SELECT @@event_scheduler;')[0]
    if ($scheduler -eq 'ON') { throw 'Restore verification requires the local event scheduler to be disabled.' }
    Assert-CanaryAACCoreInvariants
    $stamp = (Get-Date).ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $prefix = Join-Path $backupRoot ('canaryaac-preinstall-' + $stamp)
    $dumpPath = $prefix + '.sql'
    $evidencePath = $prefix + '.json'
    foreach ($path in @($dumpPath, $evidencePath)) { Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $path }
    $null = Invoke-CanaryAACDatabaseProcess -Executable $dumpClient -Arguments @($connectionArguments + @('--single-transaction', '--routines', '--events', '--triggers', '--hex-blob', 'canary')) -OutputPath $dumpPath
    Assert-CanaryAACDump $dumpPath
    $countSql = 'SELECT ''accounts'', COUNT(*) FROM `accounts` UNION ALL SELECT ''players'', COUNT(*) FROM `players`;'
    $liveCounts = @(Get-CanaryAACSqlLines $countSql)
    $restoreName = 'canaryaac_restore_' + (Get-Date).ToString('yyyyMMddHHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Assert-CanaryAACRestoreName $restoreName
    $restoreIdentifier = ConvertTo-CanaryAACSqlIdentifier $restoreName
    $restoreCreated = $false
    try {
        $null = Invoke-CanaryAACSql -Sql ("CREATE DATABASE $restoreIdentifier CHARACTER SET utf8mb4;")
        $restoreCreated = $true
        $null = Invoke-CanaryAACDatabaseProcess -Executable $client -Arguments @($connectionArguments + @('--binary-mode', '--local-infile=0', ('--database=' + $restoreName))) -InputPath $dumpPath
        $restoredCounts = @(Get-CanaryAACSqlLines -Sql $countSql -Database $restoreName)
        if (($liveCounts -join "`n") -cne ($restoredCounts -join "`n")) { throw 'Restored core table counts do not match the live database.' }
    } finally {
        if ($restoreCreated) {
            Assert-CanaryAACRestoreName $restoreName
            $null = Invoke-CanaryAACSql -Sql ('DROP DATABASE ' + (ConvertTo-CanaryAACSqlIdentifier $restoreName) + ';')
        }
    }
    Write-Host 'Backup restored successfully; temporary database removed.'
    $schemaSql = "SELECT TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE, IS_NULLABLE, HEX(COLUMN_DEFAULT), EXTRA, COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='canary' AND TABLE_NAME IN ('accounts','players')"
    $indexSql = "SELECT TABLE_NAME,INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,COLLATION,SUB_PART,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='canary' AND TABLE_NAME IN ('accounts','players') ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;"
    $fkSql = "SELECT CONSTRAINT_NAME,TABLE_NAME,REFERENCED_TABLE_NAME,UPDATE_RULE,DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='canary' AND TABLE_NAME IN ('accounts','players') ORDER BY TABLE_NAME,CONSTRAINT_NAME;"
    $baselineSchema = Invoke-CanaryAACSql -Sql ($schemaSql + ' ORDER BY TABLE_NAME,ORDINAL_POSITION;') -Database canary -OutputPath ($prefix + '.columns-before.tsv')
    $baselineIndexes = Invoke-CanaryAACSql -Sql $indexSql -Database canary -OutputPath ($prefix + '.indexes-before.tsv')
    $baselineForeignKeys = Invoke-CanaryAACSql -Sql $fkSql -Database canary -OutputPath ($prefix + '.foreignkeys-before.tsv')
    $baselines = @()
    foreach ($table in @('accounts', 'players')) {
        $columns = @(Get-CanaryAACSqlLines ("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='canary' AND TABLE_NAME='$table' ORDER BY ORDINAL_POSITION;"))
        $ddl = Invoke-CanaryAACSql -Sql ('SHOW CREATE TABLE ' + (ConvertTo-CanaryAACSqlIdentifier $table) + ';') -Database canary -OutputPath ($prefix + '.' + $table + '-create-before.tsv')
        $rows = Invoke-CanaryAACSql -Sql (Get-CanaryAACExportQuery -Table $table -Columns $columns) -Database canary -OutputPath ($prefix + '.' + $table + '-before.tsv')
        $baselines += [pscustomobject] @{
            Table = $table; Columns = $columns; ExportPath = $rows; ExportSha256 = (Get-FileHash -LiteralPath $rows -Algorithm SHA256).Hash.ToLowerInvariant()
            ShowCreatePath = $ddl; ShowCreate = [IO.File]::ReadAllText($ddl); Rows = @(Get-CanaryAACRowEvidence $rows)
        }
    }
    $playerColumns = $baselines[1].Columns
    $godPath = Invoke-CanaryAACSql -Sql (Get-CanaryAACSpecialPlayerQuery -Columns $playerColumns -Kind God) -Database canary -OutputPath ($prefix + '.god-before.tsv')
    $samplePath = Invoke-CanaryAACSql -Sql (Get-CanaryAACSpecialPlayerQuery -Columns $playerColumns -Kind Samples) -Database canary -OutputPath ($prefix + '.samples-before.tsv')
    $evidence = [pscustomobject] [ordered] @{
        Schema = 'CanaryAAC-database-evidence-v1'; StartedUtc = [DateTime]::UtcNow.ToString('o'); MariaDBVersion = $version
        Backup = [pscustomobject] @{ Path = $dumpPath; Sha256 = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash.ToLowerInvariant(); Bytes = (Get-Item -LiteralPath $dumpPath).Length }
        Restore = [pscustomobject] @{ Database = $restoreName; Counts = $restoredCounts; Dropped = $true }
        Baseline = $baselines; BaselineCounts = $liveCounts
        CoreSchemaPaths = @($baselineSchema, $baselineIndexes, $baselineForeignKeys)
        God = [pscustomobject] @{ ExportPath = $godPath; Rows = @(Get-CanaryAACRowEvidence $godPath) }
        Samples = [pscustomobject] @{ ExportPath = $samplePath; Rows = @(Get-CanaryAACRowEvidence $samplePath) }
        MigrationSha256 = ''; Passes = @(); Grants = @(); Completed = $false
    }
    # Publish the pre-migration baseline first so a later failure keeps evidence.
    [IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $migrationPath = Join-Path $PSScriptRoot 'sql\001-canaryaac-local.sql'
    $migration = [IO.File]::ReadAllText($migrationPath)
    $evidence.MigrationSha256 = (Get-FileHash -LiteralPath $migrationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    # Compare all original column definitions and all indexes/FKs after each pass.
    $originalColumnFilter = @($baselines | ForEach-Object {
        "(TABLE_NAME='" + $_.Table + "' AND COLUMN_NAME IN (" + (@($_.Columns | ForEach-Object { ConvertTo-CanaryAACSqlLiteral $_ }) -join ',') + '))'
    }) -join ' OR '
    for ($pass = 1; $pass -le 2; $pass++) {
        $null = Invoke-CanaryAACSql -Sql $migration -Database canary
        Assert-CanaryAACCoreInvariants
        $currentSchema = Invoke-CanaryAACSql -Sql ($schemaSql + ' AND (' + $originalColumnFilter + ') ORDER BY TABLE_NAME,ORDINAL_POSITION;') -Database canary
        Assert-CanaryAACSameExport $baselineSchema $currentSchema
        Assert-CanaryAACSameExport $baselineIndexes (Invoke-CanaryAACSql -Sql $indexSql -Database canary)
        Assert-CanaryAACSameExport $baselineForeignKeys (Invoke-CanaryAACSql -Sql $fkSql -Database canary)
        foreach ($baseline in $baselines) {
            $current = Invoke-CanaryAACSql -Sql (Get-CanaryAACExportQuery -Table $baseline.Table -Columns $baseline.Columns) -Database canary
            Assert-CanaryAACSameExport $baseline.ExportPath $current
        }
        Assert-CanaryAACSameExport $godPath (Invoke-CanaryAACSql -Sql (Get-CanaryAACSpecialPlayerQuery -Columns $playerColumns -Kind God) -Database canary)
        Assert-CanaryAACSameExport $samplePath (Invoke-CanaryAACSql -Sql (Get-CanaryAACSpecialPlayerQuery -Columns $playerColumns -Kind Samples) -Database canary)
        $evidence.Passes += [pscustomobject] @{ Pass = $pass; CoreInvariants = $true; CoreSchemaUnchanged = $true; CompleteRowsUnchanged = $true; GodAndSamplesUnchanged = $true }
        Write-Host "Migration pass $pass verified: original schema and complete row exports preserved."
    }
    Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $envPath
    if (Test-Path -LiteralPath $envPath) {
        $runtimePassword = Read-CanaryAACPassword ([IO.File]::ReadAllText($envPath))
    } else {
        $bytes = [byte[]]::new(32)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($bytes); $runtimePassword = [Convert]::ToBase64String($bytes) }
        finally { $random.Dispose() }
    }
    $roles = @(Get-CanaryAACSqlLines "SELECT Role FROM mysql.roles_mapping WHERE User='canaryaac_local' AND Host='127.0.0.1';")
    $null = Invoke-CanaryAACSql -Sql (New-CanaryAACGrantSql -Password $runtimePassword -Roles $roles)
    # Inspect normalized information_schema privileges instead of SHOW GRANTS,
    # whose USAGE line may contain an authentication hash.
    $granteeSql = ConvertTo-CanaryAACSqlLiteral "'canaryaac_local'@'127.0.0.1'"
    $global = @(Get-CanaryAACSqlLines "SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=$granteeSql AND PRIVILEGE_TYPE <> 'USAGE';")
    $schemaGrants = @(Get-CanaryAACSqlLines "SELECT TABLE_SCHEMA,PRIVILEGE_TYPE,IS_GRANTABLE FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=$granteeSql ORDER BY TABLE_SCHEMA,PRIVILEGE_TYPE;")
    $tableGrants = @(Get-CanaryAACSqlLines "SELECT TABLE_SCHEMA,TABLE_NAME,PRIVILEGE_TYPE,IS_GRANTABLE FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE=$granteeSql ORDER BY TABLE_SCHEMA,TABLE_NAME,PRIVILEGE_TYPE;")
    $columnGrants = @(Get-CanaryAACSqlLines "SELECT PRIVILEGE_TYPE FROM information_schema.COLUMN_PRIVILEGES WHERE GRANTEE=$granteeSql;")
    if ($global.Count -ne 0 -or $columnGrants.Count -ne 0 -or $schemaGrants.Count -ne 1 -or $schemaGrants[0] -cne "canary`tSELECT`tNO" -or
        $tableGrants.Count -ne 2 -or $tableGrants[0] -cne "canary`taccounts`tINSERT`tNO" -or $tableGrants[1] -cne "canary`tplayers`tINSERT`tNO") { throw 'Runtime database grants differ from the approved least-privilege set.' }
    $evidence.Grants = @($schemaGrants + $tableGrants)
    $dotenv = [ordered] @{
        URL = 'http://127.0.0.1:8080'; SERVER_PATH = $repositoryRoot; DB_HOST = '127.0.0.1'; DB_NAME = 'canary'; DB_USER = 'canaryaac_local'; DB_PASS = $runtimePassword; DB_PORT = '3306'
        M_COST = '65536'; T_COST = '2'; PARALLELISM = '2'; SITE_NAME = 'Canary Local'; MAINTENANCE = 'false'; DEV_MODE = 'true'; MULTI_WORLD = 'false'
        PAGSEGURO_EMAIL = ''; PAGSEGURO_TOKEN = ''; MERCADOPAGO_TOKEN = ''; MERCADOPAGO_KEY = ''; MERCADOPAGO_CLIENTID = ''; MERCADOPAGO_SECRET = ''
        PAYPAL_CLIENTID = ''; PAYPAL_SECRET = ''; MAIL_SMTP = ''; MAIL_WEB = ''; OUTFITS_FOLDER = '/resources/images/charactertrade/outfits'
    }
    $envText = (@($dotenv.GetEnumerator() | ForEach-Object { $_.Key + '=' + (ConvertTo-CanaryAACDotEnvValue $_.Value) }) -join "`n") + "`n"
    Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $envPath
    [IO.File]::WriteAllText($envPath, $envText, [Text.UTF8Encoding]::new($false))
    $evidence.Completed = $true
    Write-Host "CanaryAAC database initialized. Backup and baseline evidence: $evidencePath"
} finally {
    [Environment]::SetEnvironmentVariable('MYSQL_PWD', $previousPassword, 'Process')
    if ($null -ne $databaseLock) { $databaseLock.Dispose() }
    if ($null -ne $evidence) {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $evidencePath
        [IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    }
    # Only delete direct files inside the exact GUID directory we created;
    # reject replacement by a redirect or subdirectory instead of traversing it.
    Assert-CanaryAACDatabasePath -Root $backupRoot -Path $sessionRoot
    foreach ($item in @(Get-ChildItem -LiteralPath $sessionRoot -Force)) {
        Assert-CanaryAACDatabasePath -Root $sessionRoot -Path $item.FullName
        if ($item.PSIsContainer) { throw 'Unexpected directory in database temporary session; cleanup refused.' }
        Remove-Item -LiteralPath $item.FullName -Force
    }
    [IO.Directory]::Delete($sessionRoot)
}
