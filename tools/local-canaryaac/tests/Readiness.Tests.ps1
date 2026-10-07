$toolRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'fixtures\Invoke-ReadinessFixture.ps1'

Describe 'Readiness CLI mode and evidence gates' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fixtureTool = Join-Path $fixtureRoot 'tools\local-canaryaac'
        $source = Join-Path $fixtureRoot '.tools\canaryaac'
        New-Item -ItemType Directory $fixtureTool,(Join-Path $fixtureTool 'patches'),(Join-Path $fixtureTool 'config'),(Join-Path $source 'public') -Force | Out-Null
        foreach ($file in @('Test-CanaryAACReadiness.ps1','CanaryAAC.Production.psm1','CanaryAAC.Local.psm1')) {
            Copy-Item -LiteralPath (Join-Path $toolRoot $file) -Destination (Join-Path $fixtureTool $file)
        }
        [IO.File]::WriteAllText((Join-Path $source 'public\index.php'),'<?php echo "fixture";')
        [IO.File]::WriteAllText((Join-Path $source 'composer.lock'),'{}')
        & git -C $source init --quiet
        & git -C $source add .
        & git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
        $base = & git -C $source rev-parse HEAD
        [IO.File]::WriteAllText((Join-Path $fixtureTool 'runtime.lock.json'),(@{canaryaac=@{commit=$base}} | ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $source 'router.php'),'fixture router')
        [IO.File]::WriteAllText((Join-Path $fixtureTool 'config\router.php'),'fixture router')
        $auditOutput = Join-Path $fixtureRoot 'composer-audit.json'
        [IO.File]::WriteAllText($auditOutput,'{"advisories":[],"abandoned":[]}')
        $auditPath = Join-Path $fixtureRoot 'evidence.json'
        $evidence = @{
            SchemaVersion=1; CreatedUtc=[datetime]::UtcNow.ToString('o')
            Composer=@{ExitCode=0; ValidateExitCode=0; LockSHA256=(Get-FileHash (Join-Path $source 'composer.lock')).Hash;
                OutputFile=$auditOutput; OutputSHA256=(Get-FileHash $auditOutput).Hash}
            LoginManifestPath=(Join-Path $fixtureRoot 'absent-build.json')
            Configuration=@{
                SiteUrl='https://realm.tibiarealm.net'; GameHost='game.tibiarealm.net'; StatusPort=7171; Backend='PhpFpm'
                AppEnv='production'; Debug=$false; StrictSessions=$true; PrivateState=$true; PrivateCache=$true; PublicDocrootOnly=$true
                Admin=$false; Payments=$false; Recovery=$false; Uploads=$false; ExternalIntegrations=$false
            }
            ManualGates=@{}
        }
        $cli = Join-Path $fixtureTool 'Test-CanaryAACReadiness.ps1'
    }
    It 'can succeed locally while declaring explicit production blockers' {
        $json = & powershell -NoProfile -File $runner -ReadinessScript $cli -Mode Local -SiteUrl http://127.0.0.1:8080 -GameHost game.tibiarealm.net -Backend Builtin -AuditEvidencePath $auditPath
        $LASTEXITCODE | Should Be 0
        $report = ($json -join [Environment]::NewLine) | ConvertFrom-Json
        $report.Ready | Should Be $true
        $report.ProductionReady | Should Be $false
        @($report.Checks | Where-Object { $_.Required -and !$_.Passed }).Count | Should Be 0
        ($report.ProductionBlockers -contains 'ComposerAudit') | Should Be $true
        ($report.ProductionBlockers -contains 'ProductionBackend') | Should Be $true
        ($report.ProductionBlockers -contains 'HttpProbes') | Should Be $true
    }
    It 'rejects HTTP, loopback, placeholders and Builtin as required production gates' {
        foreach ($site in @('http://realm.tibiarealm.net','https://127.0.0.1','https://example.invalid')) {
            $json = & powershell -NoProfile -File $runner -ReadinessScript $cli -Mode Production -SiteUrl $site -GameHost game.tibiarealm.net -Backend Builtin -AuditEvidencePath $auditPath
            $LASTEXITCODE | Should Be 1
            $report = ($json -join [Environment]::NewLine) | ConvertFrom-Json
            foreach ($name in @('HttpsPublicSite','ProductionBackend','ComposerAudit','HttpProbes','DeploymentConfiguration')) {
                $gate = @($report.Checks | Where-Object { $_.Name -eq $name })[0]
                $gate.Required | Should Be $true
                $gate.Passed | Should Be $false
            }
            $report.ProductionReady | Should Be $false
        }
    }
    It 'recognizes valid evidence and refuses stale or missing deployment evidence' {
        foreach ($case in @('valid','stale','missing-config','wrong-site')) {
            $candidate = $evidence | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            if ($case -eq 'stale') { $candidate.CreatedUtc=[DateTime]::UtcNow.AddDays(-8).ToString('o') }
            if ($case -eq 'missing-config') { $candidate.PSObject.Properties.Remove('Configuration') }
            if ($case -eq 'wrong-site') { $candidate.Configuration.SiteUrl='https://other.tibiarealm.net' }
            [IO.File]::WriteAllText($auditPath,($candidate | ConvertTo-Json -Depth 6))
            $json = & powershell -NoProfile -File $runner -ReadinessScript $cli -Mode Production -SiteUrl https://realm.tibiarealm.net -GameHost game.tibiarealm.net -Backend PhpFpm -AuditEvidencePath $auditPath
            $LASTEXITCODE | Should Be 1
            $report = ($json -join [Environment]::NewLine) | ConvertFrom-Json
            @($report.Checks | Where-Object { $_.Name -eq 'HttpsPublicSite' })[0].Passed | Should Be $true
            @($report.Checks | Where-Object { $_.Name -eq 'ProductionBackend' })[0].Passed | Should Be $true
            @($report.Checks | Where-Object { $_.Name -eq 'ComposerAudit' })[0].Passed | Should Be ($case -ne 'stale')
            @($report.Checks | Where-Object { $_.Name -eq 'DeploymentConfiguration' })[0].Passed | Should Be ($case -eq 'valid')
            # Even good supplied configuration cannot replace observed HTTP and
            # login build evidence: these independent required gates still fail.
            $report.ProductionReady | Should Be $false
            ($report.ProductionBlockers -contains 'HttpProbes') | Should Be $true
            ($report.ProductionBlockers -contains 'LoginCompatibilityAudit') | Should Be $true
        }
    }
}
