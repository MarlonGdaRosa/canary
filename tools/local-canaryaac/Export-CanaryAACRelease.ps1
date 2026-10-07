[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CanaryAAC.Production.psm1') -Force
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtime = Get-CanaryAACPhysicalRuntime $root
Assert-CanaryAACReleaseRoot -RuntimeRoot $runtime -OutputRoot $OutputRoot
$checkout = Join-Path $runtime 'canaryaac'
$auditPath = Join-Path $runtime 'canaryaac-audit.json'
if (!(Test-CanaryAACAudit -Path $auditPath -Checkout $checkout)) { throw 'Fresh successful lock-bound Composer audit evidence is required in .tools/canaryaac-audit.json.' }
$audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
if (!(Test-CanaryAACLoginEvidence -ManifestPath $audit.LoginManifestPath -RuntimeRoot $runtime -PatchPath (Join-Path $PSScriptRoot 'login-server\0001-compatible-passwords.patch'))) {
    throw 'Current login source/binary/audit evidence is required.'
}
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
$stage = Join-Path $runtime ('release-replay-' + [guid]::NewGuid().ToString('N'))
$identity = Import-CanaryAACSource -Checkout $checkout -BaseCommit $lock.canaryaac.commit -PatchRoot (Join-Path $PSScriptRoot 'patches') -Destination $stage
$null = Assert-CanaryAACSource -Checkout $checkout -ExpectedRoot $stage
$release = New-CanaryAACSourceRelease -ExpectedRoot $stage -OutputRoot $OutputRoot -Identity $identity -LicensePath (Join-Path $root 'LICENSE')
[ordered]@{ReleasePath=$release; Deployable=$false; Dependencies='NotInstalled'; NextGate='Install locked dependencies in the isolated release, validate and audit, then provision private configuration.'} | ConvertTo-Json
# Retain secret-free reconstruction for independent inspection; never clean broad paths.
