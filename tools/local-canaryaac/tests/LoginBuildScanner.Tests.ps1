[CmdletBinding()]
param([string]$SourceRoot='C:\Users\Marlon\Documents\OT\.tools\login-server')
$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot '..\login-server\Build-CompatibleLoginServer.ps1'
$fixture=Join-Path 'C:\Users\Marlon\Documents\OT\.tools' ('scanner-fixture-'+[Guid]::NewGuid().ToString('N'))
$toolsRoot=Join-Path $fixture 'tools'
$alternate=Join-Path $fixture 'inherited-bin'
New-Item -ItemType Directory -Path (Join-Path $toolsRoot 'go\bin'),$alternate | Out-Null
$stub=Join-Path $fixture 'scanner-stub.exe'
$class='ScannerFixture'+[Guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Reflection;
public class $class {
  public static void Main() {
    File.AppendAllText(Environment.GetEnvironmentVariable("SCANNER_FIXTURE_LOG"), Assembly.GetExecutingAssembly().Location + Environment.NewLine);
    Console.WriteLine("No vulnerabilities found (isolated scanner fixture).");
  }
}
"@ -OutputAssembly $stub -OutputType ConsoleApplication
$stale=Join-Path $toolsRoot 'go\bin\govulncheck.exe'
Copy-Item -LiteralPath $stub -Destination $stale
[IO.File]::WriteAllText($stale+'.module','v1.7.0')
$fakeGo=Join-Path $fixture 'go-fixture.ps1'
[IO.File]::WriteAllText($fakeGo,@'
if ($args[0] -eq 'version') {
    if ($args.Count -eq 1) { 'go version go1.27.0 windows/amd64' }
    else {
        $scanner=$args[2]
        $version=[IO.File]::ReadAllText($scanner+'.module')
        "${scanner}: go1.27.0"
        "`tpath`tgolang.org/x/vuln/cmd/govulncheck"
        "`tmod`tgolang.org/x/vuln`t$version`th1:fixture"
    }
} elseif ($args[0] -eq 'install') {
    $bin=if($env:GOBIN){$env:GOBIN}else{Join-Path $env:GOPATH 'bin'}
    New-Item -ItemType Directory -Force $bin | Out-Null
    $scanner=Join-Path $bin 'govulncheck.exe'
    Copy-Item -LiteralPath $env:SCANNER_FIXTURE_STUB -Destination $scanner -Force
    [IO.File]::WriteAllText($scanner+'.module',$env:SCANNER_FIXTURE_VERSION)
} elseif ($args[0] -eq 'build') {
    $output=$args[[Array]::IndexOf($args,'-o')+1]
    [IO.File]::WriteAllText($output,'isolated fixture build')
}
$global:LASTEXITCODE=0
'@)
$saved=@{}
foreach($key in @('GOBIN','SCANNER_FIXTURE_STUB','SCANNER_FIXTURE_VERSION','SCANNER_FIXTURE_LOG')){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
try {
    $env:GOBIN=$alternate
    $env:SCANNER_FIXTURE_STUB=$stub
    $env:SCANNER_FIXTURE_VERSION='v1.8.0'
    $env:SCANNER_FIXTURE_LOG=Join-Path $fixture 'scans.log'
    & $helper -ToolsRoot $toolsRoot -SourceRoot $SourceRoot -Go $fakeGo | Out-Null
    if($env:GOBIN -ne $alternate){throw 'Inherited GOBIN was not restored'}
    if(@(Get-ChildItem -LiteralPath $alternate -Force).Count){throw 'Inherited alternate GOBIN received an install'}
    if([IO.File]::ReadAllText($stale+'.module') -ne 'v1.8.0'){throw 'Stale scanner was executed instead of replacing it'}
    $manifests=@(Get-ChildItem -LiteralPath (Join-Path $toolsRoot 'login-server-builds') -Recurse -Filter build-manifest.json)
    if($manifests.Count -ne 1){throw 'Expected one successful manifest'}
    $manifest=Get-Content -LiteralPath $manifests[0].FullName -Raw | ConvertFrom-Json
    if(!$manifest.Scanner.IdentityVerified -or $manifest.Scanner.Version -ne 'v1.8.0'){throw 'Scanner embedded identity was not verified'}
    if(@(Get-Content -LiteralPath $env:SCANNER_FIXTURE_LOG).Count -ne 3){throw 'Expected source/test/binary fixture scans'}
    $env:SCANNER_FIXTURE_VERSION='v1.7.0'
    $rejected=$false
    try { & $helper -ToolsRoot $toolsRoot -SourceRoot $SourceRoot -Go $fakeGo | Out-Null }
    catch { if($_.Exception.Message -notlike '*scanner binary identity*'){throw}; $rejected=$true }
    if(!$rejected){throw 'A stale scanner was accepted after reported installation success'}
    if(@(Get-Content -LiteralPath $env:SCANNER_FIXTURE_LOG).Count -ne 3){throw 'Unverified scanner executed'}
    if($env:GOBIN -ne $alternate){throw 'GOBIN was not restored on rejection'}
    'PASS LoginBuildScanner.Tests (alternate GOBIN confined/restored; stale scanner replaced/rejected before scans)'
} finally {
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}
    # Keep the small, uniquely named fixture as failure evidence; it contains no secrets.
}
