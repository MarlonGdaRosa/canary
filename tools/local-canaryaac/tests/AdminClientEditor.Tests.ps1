$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = (Resolve-Path (Join-Path $here '..\..\..')).Path
$runtime = Join-Path $repositoryRoot '.tools\canaryaac'
$script = Join-Path $here 'AdminClientEditor.Tests.js'

Describe 'CanaryAAC Create Client editor' {
    It 'runs the inline-editor target regression test' {
        $node = (Get-Command node -ErrorAction Stop).Source
        $previousRuntime = $env:CANARYAAC_TEST_ROOT
        try {
            $env:CANARYAAC_TEST_ROOT = $runtime
            & $node $script
            $LASTEXITCODE | Should Be 0
        } finally {
            $env:CANARYAAC_TEST_ROOT = $previousRuntime
        }
    }
}
