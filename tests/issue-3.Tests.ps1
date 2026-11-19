#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #3: Get-AdoPipelineRuns filters must be applied client-side
# because the Pipelines Runs - List API (7.1) ignores them. No network access: HTTP is mocked.

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
}

Describe 'H1 - Get-AdoPipelineRuns filters' {
    BeforeAll {
        function New-FakeRun([int]$Id, [string]$Ref, [string]$Result, [string]$State, [string]$Created) {
            [pscustomobject]@{
                id          = $Id
                state       = $State
                result      = $Result
                createdDate = $Created
                resources   = [pscustomobject]@{
                    repositories = [pscustomobject]@{
                        self = [pscustomobject]@{ refName = $Ref }
                    }
                }
            }
        }
        # The Pipelines Runs - List API (7.1) documents only api-version, so the
        # service returns every run regardless of the filter query parameters.
        Mock Invoke-AdoGet {
            [pscustomobject]@{ value = @(
                New-FakeRun 1 'refs/heads/main'      'failed'    'completed' '2026-01-10T00:00:00Z'
                New-FakeRun 2 'refs/heads/main'      'succeeded' 'completed' '2026-01-11T00:00:00Z'
                New-FakeRun 3 'refs/heads/feature/x' 'failed'    'completed' '2026-01-12T00:00:00Z'
                New-FakeRun 4 'refs/heads/main'      'failed'    'completed' '2026-01-13T00:00:00Z'
                New-FakeRun 5 'refs/heads/main'      'failed'    'completed' '2026-01-14T00:00:00Z'
                New-FakeRun 6 'refs/heads/other'     'succeeded' 'inProgress' '2026-01-15T00:00:00Z'
                [pscustomobject]@{ id = 7; state = 'completed' }
            ) }
        }
    }

    It 'returns only runs matching -Branch and -Result when the API ignores those query parameters' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 7 -Branch 'main' -Result 'failed' -Top 10)
        $runs.Count | Should -BeGreaterThan 0
        foreach ($r in $runs) {
            $r.resources.repositories.self.refName | Should -Be 'refs/heads/main'
            $r.result | Should -Be 'failed'
        }
    }

    It 'returns at most -Top runs when the API ignores $top' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 7 -Top 2)
        $runs.Count | Should -BeLessOrEqual 2
    }

    It 'does not send unsupported query parameters' {
        Get-AdoPipelineRuns -PipelineId 7 -Top 3 -Branch 'main' -State 'completed' -Result 'failed' `
            -CreatedFrom '2026-01-01' -CreatedTo '2026-02-01' | Out-Null
        Should -Invoke Invoke-AdoGet -ParameterFilter {
            $Uri -notmatch 'top=|branchName|runStateFilter|runResultFilter|minTime|maxTime' -and $Uri -match 'api-version=7\.1$'
        }
    }

    It 'matches -Branch with or without refs/heads/ prefix' {
        @(Get-AdoPipelineRuns -PipelineId 7 -Branch 'refs/heads/feature/x').Count | Should -Be 1
        @(Get-AdoPipelineRuns -PipelineId 7 -Branch 'feature/x').Count | Should -Be 1
        @(Get-AdoPipelineRuns -PipelineId 7 -Branch 'refs/heads/main').Count | Should -Be 4
    }

    It 'filters by -State' {
        @(Get-AdoPipelineRuns -PipelineId 7 -State 'inProgress').Count | Should -Be 1
    }

    It 'filters by createdDate range' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 7 -CreatedFrom '2026-01-11T00:00:00Z' -CreatedTo '2026-01-13T00:00:00Z')
        ($runs.id | Sort-Object) -join ',' | Should -Be '2,3,4'
    }

    It 'returns the most recent runs first when applying -Top' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 7 -Top 2)
        $runs.id -join ',' | Should -Be '6,5'
    }

    It 'tolerates runs lacking result, resources or createdDate (StrictMode)' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 7 -Branch 'main' -Result 'failed')
        ($runs.id -contains 7) | Should -BeFalse
        { Get-AdoPipelineRuns -PipelineId 7 -CreatedFrom '2026-01-01' } | Should -Not -Throw
    }
}
