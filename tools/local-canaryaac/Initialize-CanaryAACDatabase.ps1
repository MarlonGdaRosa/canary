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

function Assert-CanaryAACPrivateAcl {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $allowed = @($owner.Value, 'S-1-5-18', 'S-1-5-32-544')
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner.Value) { throw 'Artifact ACL must have a private owner and disabled inheritance.' }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cnotin $allowed) { throw 'Artifact ACL allows an unapproved principal.' }
    }
}

function Set-CanaryAACPrivateAcl {
    param([string] $Root, [string] $Path)
    Assert-CanaryAACDatabasePath -Root $Root -Path $Path
    $item = Get-Item -LiteralPath $Path -Force
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($item.PSIsContainer) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, 'None', 'Allow'))
    }
    # Apply only the modified owner/DACL sections. PowerShell 5 Set-Acl can
    # request SACL privileges on an already protected descriptor during reruns.
    if ($item.PSIsContainer) { [IO.Directory]::SetAccessControl($Path, $acl) }
    else { [IO.File]::SetAccessControl($Path, $acl) }
    Assert-CanaryAACPrivateAcl -Path $Path
}

function Protect-CanaryAACBackupTree {
    param([string] $Root)
    Set-CanaryAACPrivateAcl -Root $Root -Path $Root
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force)) {
            Set-CanaryAACPrivateAcl -Root $Root -Path $item.FullName
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
}

function Initialize-CanaryAACPrivateFile {
    param([string] $Root, [string] $Path)
    Assert-CanaryAACDatabasePath -Root $Root -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Private artifact must be a regular file.' }
    Set-CanaryAACPrivateAcl -Root $Root -Path $Path
}

function Write-CanaryAACPrivateText {
    param([string] $Root, [string] $Path, [string] $Text)
    Initialize-CanaryAACPrivateFile -Root $Root -Path $Path
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
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

function Assert-CanaryAACDotEnvDocument {
    param([string] $Text, [Collections.IDictionary] $Values)
    $entries = @([regex]::Matches($Text, '(?m)^([A-Z][A-Z0-9_]*)=([^\r\n]*)\r?$'))
    if ($entries.Count -ne $Values.Count) { throw 'Dotenv document has incomplete or duplicate keys.' }
    $seen = @{}
    foreach ($entry in $entries) {
        $key = $entry.Groups[1].Value
        if ($seen.ContainsKey($key) -or -not $Values.Contains($key) -or $entry.Groups[2].Value -cne (ConvertTo-CanaryAACDotEnvValue $Values[$key])) { throw 'Dotenv document differs from the approved complete settings.' }
        $seen[$key] = $true
    }
    if ((Read-CanaryAACPassword $Text) -cne $Values['DB_PASS']) { throw 'Dotenv password round trip failed.' }
}

function Invoke-CanaryAACAtomicFilePublication {
    param([string] $Source, [string] $Destination)
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($Source, $Destination, [Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Publish-CanaryAACDotEnv {
    param([string] $Root, [string] $SessionRoot, [string] $Destination, [Collections.IDictionary] $Values)
    Assert-CanaryAACDatabasePath -Root $Root -Path $Destination
    Set-CanaryAACPrivateAcl -Root $Root -Path $SessionRoot
    if ([IO.Path]::GetPathRoot($SessionRoot) -ine [IO.Path]::GetPathRoot($Destination)) { throw 'Atomic dotenv staging must be on the destination volume.' }
    if (Test-Path -LiteralPath $Destination) { Initialize-CanaryAACPrivateFile -Root $Root -Path $Destination }
    $text = (@($Values.GetEnumerator() | ForEach-Object { $_.Key + '=' + (ConvertTo-CanaryAACDotEnvValue $_.Value) }) -join "`n") + "`n"
    Assert-CanaryAACDotEnvDocument -Text $text -Values $Values
    $expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $expectedRaw = [Convert]::ToBase64String($expectedBytes)
    $stage = Join-Path $SessionRoot ('dotenv-' + [guid]::NewGuid().ToString('N') + '.stage')
    try {
        Write-CanaryAACPrivateText -Root $Root -Path $stage -Text $text
        Assert-CanaryAACPrivateAcl -Path $stage
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($stage)) -cne $expectedRaw) { throw 'Dotenv staging bytes differ from the complete approved document; prior configuration was preserved.' }
        Assert-CanaryAACDotEnvDocument -Text ([IO.File]::ReadAllText($stage)) -Values $Values
        Assert-CanaryAACDatabasePath -Root $Root -Path $Destination
        Invoke-CanaryAACAtomicFilePublication -Source $stage -Destination $Destination
        Assert-CanaryAACPrivateAcl -Path $Destination
        $published = [IO.File]::ReadAllText($Destination)
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Destination)) -cne $expectedRaw) { throw 'Published dotenv bytes differ from validated staging.' }
        Assert-CanaryAACDotEnvDocument -Text $published -Values $Values
    } finally {
        Assert-CanaryAACDatabasePath -Root $SessionRoot -Path $stage
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force }
    }
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

function ConvertFrom-CanaryAACSqlHex {
    param([AllowEmptyString()][string] $Hex)
    if ($Hex -notmatch '\A(?:[a-fA-F0-9]{2})*\z') { throw 'Malformed hexadecimal SQL result.' }
    $bytes = [byte[]] @(for ($index = 0; $index -lt $Hex.Length; $index += 2) { [Convert]::ToByte($Hex.Substring($index, 2), 16) })
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Assert-CanaryAACPublicPrivileges {
    param([string[]] $Records)
    foreach ($record in $Records) {
        $fields = $record -split "`t"
        if ($fields.Count -ne 7 -or $fields[1] -cnotin @('0', '1')) { throw 'Malformed PUBLIC privilege audit record.' }
        # The approved scope is global privileges or privileges applicable to
        # canary. Existing PUBLIC permissions on unrelated test schemas remain.
        if ($fields[1] -ceq '0') { continue }
        $scope = $fields[0]; $table = $fields[3]; $privilege = $fields[5]; $grantable = $fields[6]
        $approved = ($scope -ceq 'GLOBAL' -and $privilege -ceq 'USAGE') -or
            ($scope -cin @('SCHEMA', 'TABLE', 'COLUMN') -and $privilege -ceq 'SELECT') -or
            ($scope -cin @('TABLE', 'COLUMN') -and $table -in @('accounts', 'players') -and $privilege -ceq 'INSERT')
        if (-not $approved -or $grantable -cne 'NO') { throw 'PUBLIC or an inherited role grants privileges outside the canary contract; third-party grants were not changed.' }
    }
}

function Get-CanaryAACRoleGlobalPrivileges {
    param([string] $Role)
    $roleSql = ConvertTo-CanaryAACSqlLiteral $Role
    # MariaDB 11.8 USER_PRIVILEGES enumerates users, not acl_roles. Read only
    # role identity/is_role/access from the authoritative global record. Never
    # return the Priv JSON or authentication properties to the client/evidence.
    $rows = @(Get-CanaryAACSqlLines "SELECT HEX(User),HEX(Host),JSON_VALUE(Priv,'$.is_role'),JSON_VALUE(Priv,'$.access') FROM mysql.global_priv WHERE BINARY User=$roleSql AND Host='';")
    if ($rows.Count -ne 1) { throw 'Global role privilege identity is missing or ambiguous.' }
    $fields = $rows[0] -split "`t"
    [uint64] $access = 0
    if ($fields.Count -ne 4 -or (ConvertFrom-CanaryAACSqlHex $fields[0]) -cne $Role -or
        (ConvertFrom-CanaryAACSqlHex $fields[1]) -cne '' -or $fields[2] -cne '1' -or
        $fields[3] -cnotmatch '\A(?:0|[1-9][0-9]*)\z' -or
        -not [uint64]::TryParse($fields[3], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $access)) {
        throw 'Malformed global role privilege record; audit refused.'
    }
    if ($access -eq 0) { return "GLOBAL`t1`t*`t*`t*`tUSAGE`tNO" }
    # All global bits are outside the canary contract, including GRANT OPTION;
    # do not maintain an incomplete/version-dependent privilege-name bit map.
    "GLOBAL`t1`t*`t*`t*`tGLOBAL_ACCESS_BITS:$access`tNO"
}

function Get-CanaryAACRolePrivileges {
    param([string] $Role)
    Get-CanaryAACRoleGlobalPrivileges -Role $Role
    $roleSql = ConvertTo-CanaryAACSqlLiteral $Role
    # MariaDB information_schema represents roles using quoted grantees with
    # an empty host; QUOTE also handles quote/backslash characters in names.
    $grantee = "GRANTEE IN ($roleSql, QUOTE($roleSql), CONCAT(QUOTE($roleSql),'@',QUOTE('')))"
    $queries = @(
        "SELECT 'SCHEMA',IF('canary' LIKE TABLE_SCHEMA,1,0),TABLE_SCHEMA,'*','*',PRIVILEGE_TYPE,IS_GRANTABLE FROM information_schema.SCHEMA_PRIVILEGES WHERE $grantee;",
        "SELECT 'TABLE',IF(TABLE_SCHEMA='canary',1,0),TABLE_SCHEMA,TABLE_NAME,'*',PRIVILEGE_TYPE,IS_GRANTABLE FROM information_schema.TABLE_PRIVILEGES WHERE $grantee;",
        "SELECT 'COLUMN',IF(TABLE_SCHEMA='canary',1,0),TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,PRIVILEGE_TYPE,IS_GRANTABLE FROM information_schema.COLUMN_PRIVILEGES WHERE $grantee;",
        "SELECT 'ROUTINE',IF(Db='canary',1,0),Db,Routine_name,Routine_type,Proc_priv,IF(FIND_IN_SET('Grant',Proc_priv)>0,'YES','NO') FROM mysql.procs_priv WHERE BINARY User=$roleSql AND Host='' AND Proc_priv <> '';",
        "SELECT 'PROXY',1,'*',Proxied_user,Proxied_host,'PROXY',IF(With_grant=1,'YES','NO') FROM mysql.proxies_priv WHERE BINARY User=$roleSql AND Host='';"
    )
    foreach ($query in $queries) { Get-CanaryAACSqlLines $query }
}

function Get-CanaryAACPublicAudit {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue('PUBLIC')
    $roles = @(); $records = @()
    while ($pending.Count -gt 0) {
        $role = $pending.Dequeue()
        if (-not $seen.Add($role)) { continue }
        if ($seen.Count -gt 256) { throw 'PUBLIC role graph exceeds the bounded audit limit.' }
        $roles += $role
        $records += @(Get-CanaryAACRolePrivileges $role)
        $roleSql = ConvertTo-CanaryAACSqlLiteral $role
        foreach ($assignment in @(Get-CanaryAACSqlLines "SELECT HEX(Role),Admin_option FROM mysql.roles_mapping WHERE BINARY User=$roleSql AND Host='';")) {
            $fields = $assignment -split "`t"
            if ($fields.Count -ne 2 -or $fields[1] -cnotin @('N', 'Y')) { throw 'Malformed PUBLIC role assignment.' }
            $child = ConvertFrom-CanaryAACSqlHex $fields[0]
            if ($fields[1] -ceq 'Y') { $records += "ROLEADMIN`t1`t*`t$child`t*`tADMIN`tYES" }
            $pending.Enqueue($child)
        }
    }
    Assert-CanaryAACPublicPrivileges -Records $records
    [pscustomobject] @{ SafeForCanary = $true; Roles = $roles; Records = $records; UnrelatedPublicPermissions = @($records | Where-Object { ($_ -split "`t")[1] -ceq '0' }).Count -gt 0 }
}

function Get-CanaryAACRuntimeProxies {
    foreach ($line in @(Get-CanaryAACSqlLines "SELECT HEX(Proxied_user),HEX(Proxied_host) FROM mysql.proxies_priv WHERE BINARY User='canaryaac_local' AND Host='127.0.0.1';")) {
        $fields = $line -split "`t"
        if ($fields.Count -ne 2) { throw 'Malformed runtime proxy identity.' }
        [pscustomobject] @{ User = ConvertFrom-CanaryAACSqlHex $fields[0]; Host = ConvertFrom-CanaryAACSqlHex $fields[1] }
    }
}

function New-CanaryAACProxyRevocations {
    param([object[]] $Proxies)
    @($Proxies | ForEach-Object {
        'REVOKE PROXY ON ' + (ConvertTo-CanaryAACSqlLiteral $_.User) + '@' + (ConvertTo-CanaryAACSqlLiteral $_.Host) + " FROM 'canaryaac_local'@'127.0.0.1';"
    }) -join "`n"
}

function Assert-CanaryAACNoIndirectRuntimeGrants {
    foreach ($query in @(
        "SELECT Role FROM mysql.roles_mapping WHERE BINARY User='canaryaac_local' AND Host='127.0.0.1';",
        "SELECT Proxied_user FROM mysql.proxies_priv WHERE BINARY User='canaryaac_local' AND Host='127.0.0.1';",
        "SELECT Proc_priv FROM mysql.procs_priv WHERE BINARY User='canaryaac_local' AND Host='127.0.0.1' AND Proc_priv <> '';"
    )) {
        if (@(Get-CanaryAACSqlLines $query).Count -ne 0) { throw 'Runtime account retains a role, PROXY grant or routine privilege outside its contract.' }
    }
}

function New-CanaryAACGrantSql {
    param([string] $Password, [string[]] $Roles, [object[]] $Proxies)
    $account = "'canaryaac_local'@'127.0.0.1'"
    $passwordSql = ConvertTo-CanaryAACSqlLiteral $Password
    $revocations = @($Roles | ForEach-Object { 'REVOKE ' + (ConvertTo-CanaryAACSqlIdentifier $_) + " FROM $account;" }) -join "`n"
    $proxyRevocations = New-CanaryAACProxyRevocations -Proxies $Proxies
    @"
CREATE USER IF NOT EXISTS $account IDENTIFIED BY $passwordSql;
ALTER USER $account IDENTIFIED BY $passwordSql;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM $account;
$revocations
$proxyRevocations
SET DEFAULT ROLE NONE FOR $account;
GRANT SELECT ON canary.* TO $account;
GRANT INSERT ON canary.accounts TO $account;
GRANT INSERT ON canary.players TO $account;
FLUSH PRIVILEGES;
"@
}

function Stop-CanaryAACOwnedProcessTree {
    param([Diagnostics.Process] $Process)
    # Keep handles open until every owned descendant has stopped. A Windows PID
    # cannot be recycled while its process object is held; creation identities
    # also reject stale/recycled child records returned by the process snapshot.
    $pending = [Collections.Generic.Queue[Diagnostics.Process]]::new()
    $handles = [Collections.Generic.List[Diagnostics.Process]]::new()
    $pending.Enqueue($Process)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($pending.Count -gt 0) {
            if ($deadline.Elapsed.TotalSeconds -ge 30 -or $handles.Count -gt 256) { throw 'Owned native process cleanup exceeded its bounded limit.' }
            $parent = $pending.Dequeue()
            $null = $parent.Handle
            $started = $parent.StartTime.ToUniversalTime().Ticks
            if (-not $parent.HasExited) { $parent.Kill() }
            $remaining = [Math]::Max(1, [Math]::Min(10000, [int] (30000 - $deadline.Elapsed.TotalMilliseconds)))
            if (-not $parent.WaitForExit($remaining)) { throw 'Owned native process did not stop before cleanup.' }
            $ended = $parent.ExitTime.ToUniversalTime().Ticks
            foreach ($record in @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $parent.Id) -OperationTimeoutSec 5)) {
                $created = $record.CreationDate.ToUniversalTime().Ticks
                if ($created -lt $started -or $created -gt $ended) { continue }
                $child = $null
                try {
                    $child = [Diagnostics.Process]::GetProcessById([int] $record.ProcessId)
                    $null = $child.Handle
                    if ([Math]::Abs($child.StartTime.ToUniversalTime().Ticks - $created) -ge 10) { $child.Dispose(); continue }
                } catch [ArgumentException] { if ($null -ne $child) { $child.Dispose() }; continue }
                  catch [InvalidOperationException] { if ($null -ne $child) { $child.Dispose() }; continue }
                $handles.Add($child)
                $pending.Enqueue($child)
            }
        }
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Invoke-CanaryAACDatabaseProcess {
    param([string] $Executable, [string[]] $Arguments, [string] $InputPath, [string] $OutputPath, [ValidateRange(1,3600)][int] $TimeoutSeconds = 300)
    if ($null -eq (Get-Variable canaryAACNativeCleanupSafe -Scope Script -ErrorAction SilentlyContinue)) { $script:canaryAACNativeCleanupSafe = $true }
    if ([string]::IsNullOrEmpty($OutputPath)) { $OutputPath = Join-Path $sessionRoot ($([guid]::NewGuid().ToString('N')) + '.out') }
    $errorPath = Join-Path $sessionRoot ($([guid]::NewGuid().ToString('N')) + '.err')
    foreach ($path in @($OutputPath, $errorPath)) { Initialize-CanaryAACPrivateFile -Root $runtimeRoot -Path $path }
    $start = @{
        FilePath = $Executable; ArgumentList = (@($Arguments | ForEach-Object { ConvertTo-CanaryAACWindowsArgument $_ }) -join ' ')
        RedirectStandardOutput = $OutputPath; RedirectStandardError = $errorPath
        NoNewWindow = $true; PassThru = $true
    }
    if (-not [string]::IsNullOrEmpty($InputPath)) {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $InputPath
        $start.RedirectStandardInput = $InputPath
    }
    $process = Start-Process @start
    try {
        $null = $process.Handle
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { Stop-CanaryAACOwnedProcessTree -Process $process }
            catch {
                # Retain private stdin and session files if termination cannot
                # be proved. Never remove a file a native process may still use.
                $script:canaryAACNativeCleanupSafe = $false
                throw 'Native timeout cleanup could not be proved; private diagnostic files were retained.'
            }
            throw 'MariaDB operation timed out; its owned process tree was stopped before cleanup.'
        }
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
    Write-CanaryAACPrivateText -Root $runtimeRoot -Path $input -Text ("SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';`n" + $Sql + "`n")
    try {
        $arguments = @($connectionArguments + @('--batch', '--raw', '--skip-column-names', '--binary-mode', '--local-infile=0'))
        if (-not [string]::IsNullOrEmpty($Database)) { $arguments += '--database=' + $Database }
        Invoke-CanaryAACDatabaseProcess -Executable $client -Arguments $arguments -InputPath $input -OutputPath $OutputPath
    } finally {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $input
        if ($script:canaryAACNativeCleanupSafe) { Remove-Item -LiteralPath $input -Force }
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

function Assert-CanaryAACRestoredRows {
    param([string] $RestoreDatabase, [object[]] $Baselines)
    Assert-CanaryAACRestoreName $RestoreDatabase
    foreach ($baseline in $Baselines) {
        $query = Get-CanaryAACExportQuery -Table $baseline.Table -Columns $baseline.Columns
        $restored = Invoke-CanaryAACSql -Sql $query -Database $RestoreDatabase
        Assert-CanaryAACSameExport $baseline.ExportPath $restored
        [pscustomobject] @{ Table = $baseline.Table; CompleteRowsEqual = $true; ExportSha256 = (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

function Invoke-CanaryAACRestoreVerification {
    param([string] $RestoreDatabase, [string] $DumpPath, [string] $CountSql, [string[]] $LiveCounts, [object[]] $Baselines)
    Assert-CanaryAACRestoreName $RestoreDatabase
    $identifier = ConvertTo-CanaryAACSqlIdentifier $RestoreDatabase
    $attempted = $false
    try {
        # The server may commit CREATE before its client times out or fails.
        # Track the attempt before sending SQL, not the observed client result.
        $attempted = $true
        $null = Invoke-CanaryAACSql -Sql ("CREATE DATABASE $identifier CHARACTER SET utf8mb4;")
        $null = Invoke-CanaryAACDatabaseProcess -Executable $client -Arguments @($connectionArguments + @('--binary-mode', '--local-infile=0', ('--database=' + $RestoreDatabase))) -InputPath $DumpPath
        $restoredCounts = @(Get-CanaryAACSqlLines -Sql $CountSql -Database $RestoreDatabase)
        if (($LiveCounts -join "`n") -cne ($restoredCounts -join "`n")) { throw 'Restored core table counts do not match the live database.' }
        $restoredRows = @(Assert-CanaryAACRestoredRows -RestoreDatabase $RestoreDatabase -Baselines $Baselines)
        [pscustomobject] @{ Database = $RestoreDatabase; Counts = $restoredCounts; CompleteRowsEqual = $true; Tables = $restoredRows; Dropped = $true }
    } finally {
        if ($attempted) {
            Assert-CanaryAACRestoreName $RestoreDatabase
            $null = Invoke-CanaryAACSql -Sql ('DROP DATABASE IF EXISTS ' + (ConvertTo-CanaryAACSqlIdentifier $RestoreDatabase) + ';')
        }
    }
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
Protect-CanaryAACBackupTree -Root $backupRoot
if (Test-Path -LiteralPath $envPath) { Initialize-CanaryAACPrivateFile -Root $runtimeRoot -Path $envPath }
$sessionRoot = Join-Path $backupRoot ('canaryaac-db-' + [guid]::NewGuid().ToString('N'))
Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $sessionRoot
New-Item -ItemType Directory -Path $sessionRoot | Out-Null
Set-CanaryAACPrivateAcl -Root $runtimeRoot -Path $sessionRoot
$script:canaryAACNativeCleanupSafe = $true
$previousPassword = [Environment]::GetEnvironmentVariable('MYSQL_PWD', 'Process')
$connectionArguments = @(Get-CanaryAACConnectionArguments $AdminCredential.UserName)
$databaseLock = $null
$lockPath = Join-Path $backupRoot 'canaryaac-database.lock'
$evidence = $null
$evidencePath = $null
try {
    Initialize-CanaryAACPrivateFile -Root $runtimeRoot -Path $lockPath
    $databaseLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    [Environment]::SetEnvironmentVariable('MYSQL_PWD', $AdminCredential.GetNetworkCredential().Password, 'Process')
    $version = @(Get-CanaryAACSqlLines 'SELECT VERSION();')[0]
    if ([string]::IsNullOrEmpty($version)) { throw 'MariaDB version probe failed.' }
    $scheduler = @(Get-CanaryAACSqlLines 'SELECT @@event_scheduler;')[0]
    if ($scheduler -eq 'ON') { throw 'Restore verification requires the local event scheduler to be disabled.' }
    Assert-CanaryAACCoreInvariants
    $publicBefore = Get-CanaryAACPublicAudit
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
    # The dump and the captured live baseline must agree in every value, not
    # merely counts. Concurrent core mutations abort before migration.
    $restoreVerification = Invoke-CanaryAACRestoreVerification -RestoreDatabase $restoreName -DumpPath $dumpPath -CountSql $countSql -LiveCounts $liveCounts -Baselines $baselines
    Write-Host 'Backup restored with complete core-row byte parity; temporary database removed.'
    $evidence = [pscustomobject] [ordered] @{
        Schema = 'CanaryAAC-database-evidence-v1'; StartedUtc = [DateTime]::UtcNow.ToString('o'); MariaDBVersion = $version
        Backup = [pscustomobject] @{ Path = $dumpPath; Sha256 = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash.ToLowerInvariant(); Bytes = (Get-Item -LiteralPath $dumpPath).Length }
        Restore = $restoreVerification
        Baseline = $baselines; BaselineCounts = $liveCounts
        CoreSchemaPaths = @($baselineSchema, $baselineIndexes, $baselineForeignKeys)
        God = [pscustomobject] @{ ExportPath = $godPath; Rows = @(Get-CanaryAACRowEvidence $godPath) }
        Samples = [pscustomobject] @{ ExportPath = $samplePath; Rows = @(Get-CanaryAACRowEvidence $samplePath) }
        MigrationSha256 = ''; Passes = @(); Grants = @(); Completed = $false
        Security = [pscustomobject] @{ PublicBefore = $publicBefore; PublicAfter = $null; RuntimeRolesEmpty = $false; RuntimeProxyCount = -1; RuntimeRoutinePrivilegesEmpty = $false; PrivateArtifactsVerified = $false; AtomicDotEnvPublication = $false }
    }
    # Publish the pre-migration baseline first so a later failure keeps evidence.
    Write-CanaryAACPrivateText -Root $runtimeRoot -Path $evidencePath -Text ($evidence | ConvertTo-Json -Depth 10)
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
    $roles = @(Get-CanaryAACSqlLines "SELECT HEX(Role) FROM mysql.roles_mapping WHERE BINARY User='canaryaac_local' AND Host='127.0.0.1';" | ForEach-Object { ConvertFrom-CanaryAACSqlHex $_ })
    $proxies = @(Get-CanaryAACRuntimeProxies)
    $null = Invoke-CanaryAACSql -Sql (New-CanaryAACGrantSql -Password $runtimePassword -Roles $roles -Proxies $proxies)
    Assert-CanaryAACNoIndirectRuntimeGrants
    $evidence.Security.PublicAfter = Get-CanaryAACPublicAudit
    $evidence.Security.RuntimeRolesEmpty = $true
    $evidence.Security.RuntimeProxyCount = 0
    $evidence.Security.RuntimeRoutinePrivilegesEmpty = $true
    # Inspect normalized information_schema privileges instead of SHOW GRANTS,
    # whose USAGE line may contain an authentication hash.
    $granteeSql = ConvertTo-CanaryAACSqlLiteral "'canaryaac_local'@'127.0.0.1'"
    $global = @(Get-CanaryAACSqlLines "SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=$granteeSql AND (PRIVILEGE_TYPE <> 'USAGE' OR IS_GRANTABLE <> 'NO');")
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
    Publish-CanaryAACDotEnv -Root $runtimeRoot -SessionRoot $sessionRoot -Destination $envPath -Values $dotenv
    $evidence.Security.AtomicDotEnvPublication = $true
    # Every permanent artifact (including previous backups) is explicitly
    # protected, not just transient SQL. Do not print ACL contents or secrets.
    Assert-CanaryAACPrivateAcl -Path $backupRoot
    foreach ($artifact in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Force)) {
        Assert-CanaryAACDatabasePath -Root $backupRoot -Path $artifact.FullName
        Assert-CanaryAACPrivateAcl -Path $artifact.FullName
    }
    Assert-CanaryAACPrivateAcl -Path $envPath
    $evidence.Security.PrivateArtifactsVerified = $true
    $evidence.Completed = $true
    Write-Host "CanaryAAC database initialized. Backup and baseline evidence: $evidencePath"
} finally {
    [Environment]::SetEnvironmentVariable('MYSQL_PWD', $previousPassword, 'Process')
    if ($null -ne $databaseLock) { $databaseLock.Dispose() }
    if ($null -ne $evidence) {
        Assert-CanaryAACDatabasePath -Root $runtimeRoot -Path $evidencePath
        Write-CanaryAACPrivateText -Root $runtimeRoot -Path $evidencePath -Text ($evidence | ConvertTo-Json -Depth 10)
    }
    # Only delete direct files inside the exact GUID directory we created;
    # reject replacement by a redirect or subdirectory instead of traversing it.
    if ($script:canaryAACNativeCleanupSafe) {
        Assert-CanaryAACDatabasePath -Root $backupRoot -Path $sessionRoot
        foreach ($item in @(Get-ChildItem -LiteralPath $sessionRoot -Force)) {
            Assert-CanaryAACDatabasePath -Root $sessionRoot -Path $item.FullName
            if ($item.PSIsContainer) { throw 'Unexpected directory in database temporary session; cleanup refused.' }
            Remove-Item -LiteralPath $item.FullName -Force
        }
        [IO.Directory]::Delete($sessionRoot)
    }
}
