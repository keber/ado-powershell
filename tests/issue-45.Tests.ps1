#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #45: Get-AdoPipelineRuns -Branch returned no runs because
# Runs - List items carry no 'resources'. The branch is now resolved server-side through the
# Build API (pipeline id == build definition id) and intersected with the run list by id.
# No network access: HTTP is mocked with the real response shapes.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scriptsDir 'ado-base.ps1')
    . (Join-Path $scriptsDir 'ado-workitems.ps1')
    . (Join-Path $scriptsDir 'ado-testing.ps1')
    . (Join-Path $scriptsDir 'ado-pipelines.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'Fabrikam QA'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
}

Describe 'Get-AdoPipelineRuns -Branch (issue 45)' {
    BeforeAll {
        # Runs - List items: NO resources property (shape returned by the real API).
        function New-ListRun([int]$Id, [string]$Result, [string]$State, [string]$Created) {
            [pscustomobject]@{ id = $Id; name = "run-$Id"; state = $State; result = $Result; createdDate = $Created }
        }
        Mock Invoke-AdoGet {
            [pscustomobject]@{ count = 6; value = @(
                New-ListRun 1 'failed'    'completed' '2026-01-10T00:00:00Z'
                New-ListRun 2 'succeeded' 'completed' '2026-01-11T00:00:00Z'
                New-ListRun 3 'failed'    'completed' '2026-01-12T00:00:00Z'
                New-ListRun 4 'succeeded' 'completed' '2026-01-13T00:00:00Z'
                New-ListRun 5 'failed'    'completed' '2026-01-14T00:00:00Z'
                New-ListRun 6 'failed'    'completed' '2026-01-15T00:00:00Z'
            ) }
        }
        # Invoke-AdoGetPaged returns the items already merged across all pages. Here the
        # branch's builds are "spread over several pages" (ids 5,4 then 1), as the real
        # paged helper would hand them back.
        Mock Invoke-AdoGetPaged {
            @(
                [pscustomobject]@{ id = 5; sourceBranch = 'refs/heads/main' }
                [pscustomobject]@{ id = 4; sourceBranch = 'refs/heads/main' }
                [pscustomobject]@{ id = 1; sourceBranch = 'refs/heads/main' }
            )
        }
    }

    It 'returns the runs on the branch even though list items have no resources' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' -Top 10)
        ($runs.id -join ',') | Should -Be '5,4,1'
    }

    It 'returns Pipelines API run objects (same shape as without -Branch)' {
        $r = @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main')[0]
        $r.PSObject.Properties['state']        | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['createdDate']  | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties['sourceBranch'] | Should -BeNullOrEmpty
    }

    It 'queries the Build API with definitions and a refs/heads/ branchName' {
        Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' | Out-Null
        Should -Invoke Invoke-AdoGetPaged -ParameterFilter {
            $Uri -match '/_apis/build/builds\?' -and $Uri -match 'definitions=42' -and
            $Uri -match 'branchName=refs%2Fheads%2Fmain' -and $Uri -match 'api-version=7\.1'
        }
    }

    It 'does not double the prefix and encodes slashes in feature branches' {
        Get-AdoPipelineRuns -PipelineId 42 -Branch 'refs/heads/feature/x' | Out-Null
        Should -Invoke Invoke-AdoGetPaged -ParameterFilter {
            $Uri -match 'branchName=refs%2Fheads%2Ffeature%2Fx(&|$)'
        }
    }

    It 'keeps the project name escaped in both URLs (issue 41)' {
        Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' | Out-Null
        Should -Invoke Invoke-AdoGetPaged -ParameterFilter {
            $Uri -match 'Fabrikam%20QA/_apis/build/builds'
        }
        Should -Invoke Invoke-AdoGet -ParameterFilter {
            $Uri -match 'Fabrikam%20QA/_apis/pipelines/42/runs'
        }
    }

    It 'combines -Branch with -Result and applies -Top after filtering' {
        $runs = @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' -Result 'failed' -Top 2)
        ($runs.id -join ',') | Should -Be '5,1'
    }

    It 'returns no runs when the branch has no builds' {
        Mock Invoke-AdoGetPaged { @() }
        @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'nope').Count | Should -Be 0
    }

    It 'collects builds through the paged helper (every page, not just the first)' {
        @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' -Top 10).Count | Should -Be 3
        Should -Invoke Invoke-AdoGetPaged -Times 1 -Exactly
        Should -Invoke Invoke-AdoGet -Times 1 -Exactly -ParameterFilter { $Uri -match '/pipelines/42/runs' }
        Should -Invoke Invoke-AdoGet -Times 0 -ParameterFilter { $Uri -match '/_apis/build/builds' }
    }

    It 'bounds the lookup with queryOrder and an escaped minTime (oldest run minus 1 day, UTC)' {
        Get-AdoPipelineRuns -PipelineId 42 -Branch 'main' | Out-Null
        Should -Invoke Invoke-AdoGetPaged -ParameterFilter {
            $Uri -match 'queryOrder=queueTimeDescending' -and
            $Uri -match 'minTime=2026-01-09T00%3A00%3A00Z(&|$)'
        }
    }

    It 'skips the Build API entirely when the pipeline has no runs' {
        Mock Invoke-AdoGet { [pscustomobject]@{ count = 0; value = @() } }
        @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main').Count | Should -Be 0
        Should -Invoke Invoke-AdoGetPaged -Times 0 -Exactly
    }

    It 'omits minTime when no run has a createdDate' {
        Mock Invoke-AdoGet { [pscustomobject]@{ value = @([pscustomobject]@{ id = 1; state = 'completed' }) } }
        @(Get-AdoPipelineRuns -PipelineId 42 -Branch 'main').Count | Should -Be 1
        Should -Invoke Invoke-AdoGetPaged -ParameterFilter { $Uri -notmatch 'minTime' }
    }

    It 'does not call the Build API when -Branch is not set' {
        Get-AdoPipelineRuns -PipelineId 42 | Out-Null
        Should -Invoke Invoke-AdoGetPaged -Times 0 -Exactly
    }
}
