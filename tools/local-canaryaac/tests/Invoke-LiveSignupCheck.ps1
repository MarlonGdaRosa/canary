[CmdletBinding()]
param([Parameter(Mandatory)][PSCredential]$CleanupCredential,
    [string]$RuntimeRoot='C:\Users\Marlon\Documents\OT\.tools')
$ErrorActionPreference='Stop'
$php=Join-Path $RuntimeRoot 'php\php.exe'
$ini=Join-Path $RuntimeRoot 'php\php.ini'
$script=Join-Path $PSScriptRoot 'php\LiveSignupCheck.php'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$php
$start.Arguments='-c "'+$ini+'" "'+$script+'"'
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.EnvironmentVariables['CANARYAAC_TEST_ROOT']=Join-Path $RuntimeRoot 'canaryaac'
$process=[Diagnostics.Process]::Start($start)
$process.StandardInput.Write((@{user=$CleanupCredential.UserName;password=$CleanupCredential.GetNetworkCredential().Password}|ConvertTo-Json -Compress))
$process.StandardInput.Close()
$output=$process.StandardOutput.ReadToEnd()
$errors=$process.StandardError.ReadToEnd()
$process.WaitForExit()
Write-Output $output
if ($process.ExitCode -ne 0) { throw 'Live signup integration check failed; sensitive stderr withheld.' }
