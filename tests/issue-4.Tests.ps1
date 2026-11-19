#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #4 (New-AdoTestCase -State Design/Ready).
# No network access: all HTTP calls are mocked.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scriptsDir 'ado-base.ps1')
    . (Join-Path $scriptsDir 'ado-workitems.ps1')
    . (Join-Path $scriptsDir 'ado-testing.ps1')
    . (Join-Path $scriptsDir 'ado-pipelines.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }

    # Save ADO_* env vars so tests can clear them and restore afterwards
    $script:EnvNames = 'ADO_ORG', 'ADO_PROJECT', 'ADO_API_VER', 'ADO_PAT', 'AZURE_DEVOPS_EXT_PAT'
    $script:SavedEnv = @{}
    foreach ($n in $script:EnvNames) {
        $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }
}

AfterAll {
    foreach ($n in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n], 'Process')
    }
}

Describe 'H2 - New-AdoTestCase -State' {
    BeforeAll {
        Mock Invoke-AdoRequest { [pscustomobject]@{ id = 101 } }
        Mock Write-Host { }
    }

    It 'New-AdoTestCase -State <State> does not throw a parameter binding error' -TestCases @(
        @{ State = 'Design' }
        @{ State = 'Ready' }
    ) {
        param($State)
        { New-AdoTestCase -Title 'TC' -State $State -Confirm:$false } | Should -Not -Throw
    }

    It 'New-AdoTestCase -State Design sends System.State=Design in the create request' {
        New-AdoTestCase -Title 'TC' -State 'Design' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Should -Invoke Invoke-AdoRequest -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Body -match '/fields/System\.State"' -and $Body -match '"value":\s*"Design"'
        }
    }

    It 'New-AdoWorkItem accepts process-specific state <State> (no client-side ValidateSet)' -TestCases @(
        @{ State = 'Design' }
        @{ State = 'Ready' }
        @{ State = 'Committed' }
    ) {
        param($State)
        { New-AdoWorkItem -Type 'Test Case' -Title 'T' -State $State -Confirm:$false } | Should -Not -Throw
    }
}

