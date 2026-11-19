#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #5: test suite / test case listing must not swallow errors.
# No network access: all HTTP calls are mocked.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scriptsDir 'ado-base.ps1')
    . (Join-Path $scriptsDir 'ado-workitems.ps1')
    . (Join-Path $scriptsDir 'ado-testing.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
}

Describe 'H3 - Test suite / test case listing must not swallow auth errors' {
    It 'Get-AdoTestSuites propagates 401 instead of returning empty' {
        Mock Invoke-AdoGet { throw '401 Unauthorized - check ADO_PAT.' }
        { Get-AdoTestSuites -PlanId 1 } | Should -Throw '*401*'
    }

    It 'Get-AdoTestSuites propagates 403 instead of returning empty' {
        Mock Invoke-AdoGet { throw '403 Forbidden - PAT does not have sufficient permissions for: x' }
        { Get-AdoTestSuites -PlanId 1 } | Should -Throw '*403*'
    }

    It 'Get-AdoTestCases propagates 401 instead of returning empty' {
        Mock Invoke-AdoGet { throw '401 Unauthorized - check ADO_PAT.' }
        { Get-AdoTestCases -PlanId 1 -SuiteId 2 } | Should -Throw '*401*'
    }

    It 'Get-AdoTestCases propagates 403 instead of returning empty' {
        Mock Invoke-AdoGet { throw '403 Forbidden - PAT does not have sufficient permissions for: x' }
        { Get-AdoTestCases -PlanId 1 -SuiteId 2 } | Should -Throw '*403*'
    }

    It 'Get-AdoTestSuites tries all 4 endpoint shapes on 404, then throws a clear error' {
        Mock Invoke-AdoGet { throw '404 Not Found - resource not found: x' }
        { Get-AdoTestSuites -PlanId 1 } | Should -Throw '*404*'
        Should -Invoke Invoke-AdoGet -Times 4 -Exactly
    }

    It 'Get-AdoTestSuites propagates 500 instead of returning empty' {
        Mock Invoke-AdoGet { throw '500 Internal Server Error - x' }
        { Get-AdoTestSuites -PlanId 1 } | Should -Throw '*500*'
    }

    It 'Get-AdoTestSuites stops at the first non-404 error' {
        Mock Invoke-AdoGet { throw '401 Unauthorized - check ADO_PAT.' }
        try { Get-AdoTestSuites -PlanId 1 } catch { }
        Should -Invoke Invoke-AdoGet -Times 1 -Exactly
    }

    It 'Get-AdoTestCases tries all 5 endpoint shapes on 404, then throws a clear error' {
        Mock Invoke-AdoGet { throw '404 Not Found - resource not found: x' }
        { Get-AdoTestCases -PlanId 1 -SuiteId 2 } | Should -Throw '*404*'
        Should -Invoke Invoke-AdoGet -Times 5 -Exactly
    }

    It 'Get-AdoTestSuites falls through 404 to a later shape that succeeds' {
        $script:n = 0
        Mock Invoke-AdoGet {
            $script:n++
            if ($script:n -lt 3) { throw '404 Not Found - x' }
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 7 }) }
        }
        (Get-AdoTestSuites -PlanId 1).id | Should -Be 7
    }

    It 'Get-AdoTestSuites error on all-404 names the plan and hints at PlanId/project' {
        Mock Invoke-AdoGet { throw '404 Not Found - x' }
        { Get-AdoTestSuites -PlanId 42 } | Should -Throw '*plan 42*Check PlanId*'
    }

    It 'Get-AdoTestSuites does not warn when a call succeeded with an empty value' {
        Mock Invoke-AdoGet { [pscustomobject]@{ value = @() } }
        $null = Get-AdoTestSuites -PlanId 1 -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -Be 0
    }

    It 'Get-AdoTestSuites returns an empty array (not $null) when value is empty' {
        Mock Invoke-AdoGet { [pscustomobject]@{ value = @() } }
        $r = Get-AdoTestSuites -PlanId 1
        $null -ne $r | Should -BeTrue
        @($r).Count | Should -Be 0
    }

    It 'Get-AdoTestCases returns an empty array (not $null) when value is empty' {
        Mock Invoke-AdoGet { [pscustomobject]@{ value = @() } }
        $r = Get-AdoTestCases -PlanId 1 -SuiteId 2
        $null -ne $r | Should -BeTrue
        @($r).Count | Should -Be 0
    }
}
