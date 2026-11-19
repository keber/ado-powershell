#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #2 (Invoke-AdoPipelineRun branch name mangling). No network: HTTP is mocked.
# Run: Invoke-Pester -Path tests/issue-2.Tests.ps1 -Output Detailed

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scripts 'ado-base.ps1')
    . (Join-Path $scripts 'ado-content.ps1')
    . (Join-Path $scripts 'ado-pipelines.ps1')

    $script:FakeHeaders = @{ Authorization = 'Basic FAKE-TEST-TOKEN'; 'Content-Type' = 'application/json' }
    $script:AdoSession = [pscustomobject]@{
        Org     = 'contoso'
        Project = 'MyApp'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/contoso'
        Headers = $script:FakeHeaders
    }
}

Describe 'C2 - Invoke-AdoPipelineRun keeps the branch name intact in refName' {
    BeforeEach {
        $script:capturedBody = $null
        Mock Invoke-AdoRequest {
            $script:capturedBody = $Body
            [pscustomobject]@{ id = 1; state = 'inProgress' }
        }
        Mock Write-Host { }
    }

    It "sends refName '<Expected>' for -Branch '<Branch>'" -TestCases @(
        @{ Branch = 'feature/x';       Expected = 'refs/heads/feature/x' }
        @{ Branch = 'develop';         Expected = 'refs/heads/develop' }
        @{ Branch = 'release/1.0';     Expected = 'refs/heads/release/1.0' }
        @{ Branch = 'main';            Expected = 'refs/heads/main' }
        @{ Branch = 'refs/heads/main'; Expected = 'refs/heads/main' }
        @{ Branch = 'refs/heads/feature/x'; Expected = 'refs/heads/feature/x' }
        @{ Branch = 'hotfix/refs/heads';    Expected = 'refs/heads/hotfix/refs/heads' }
    ) {
        param($Branch, $Expected)

        $null = Invoke-AdoPipelineRun -PipelineId 4 -Branch $Branch -Org 'contoso' -Project 'MyApp' `
            -ApiV '7.1' -Headers $script:FakeHeaders -Confirm:$false

        Should -Invoke Invoke-AdoRequest -Times 1 -Exactly
        ($script:capturedBody | ConvertFrom-Json).resources.repositories.self.refName | Should -Be $Expected
    }
}
