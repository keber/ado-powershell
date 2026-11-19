#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #16: Invoke-AdoPipelineRun must prompt by default.
# No network access: all HTTP calls are mocked.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pipelines.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
}

Describe 'M9 - Invoke-AdoPipelineRun does not prompt under the default $ConfirmPreference' {
    BeforeEach {
        Mock Invoke-AdoRequest { [pscustomobject]@{ id = 99; state = 'inProgress' } }
        Mock Write-Host { }
    }

    It 'declares ConfirmImpact High so the default ConfirmPreference (High) prompts' {
        $attr = (Get-Command Invoke-AdoPipelineRun).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attr.SupportsShouldProcess | Should -BeTrue
        "$($attr.ConfirmImpact)" | Should -Be 'High'
    }

    It 'sends no POST with -WhatIf' {
        Invoke-AdoPipelineRun -PipelineId 4 -Branch 'main' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Invoke-AdoRequest -Times 0 -Exactly
    }

    It 'sends the POST with -Confirm:$false' {
        $r = Invoke-AdoPipelineRun -PipelineId 4 -Branch 'main' -Confirm:$false
        $r.id | Should -Be 99
        Should -Invoke Invoke-AdoRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/pipelines/4/runs?*'
        }
    }
}
