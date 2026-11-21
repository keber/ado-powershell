#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #51: Complete-AdoPullRequest must not report success when Azure DevOps
# answers 200 but the PR is not completed (merge conflicts, policy rejection, queued completion).
# Mocked HTTP only; no network access.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pullrequests.ps1')

    function script:New-Pr($Status, $Merge, $Msg) {
        $o = [pscustomobject]@{ pullRequestId = 7; status = $Status; mergeStatus = $Merge }
        if ($Msg) { $o | Add-Member -NotePropertyName mergeFailureMessage -NotePropertyValue $Msg }
        $o
    }

    function script:Try-Complete {
        $e = $null; $r = $null
        try { $r = Complete-AdoPullRequest -RepoId 'R' -PullRequestId 7 -LastMergeSourceCommitId 'abc' -Confirm:$false } catch { $e = $_ }
        [pscustomobject]@{ Error = $e; Result = $r }
    }
}

AfterAll { $script:AdoSession = $null }

Describe 'Complete-AdoPullRequest outcome (issue 51)' {
    BeforeEach {
        $script:AdoSession = [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
            BaseUrl = 'https://dev.azure.com/fakeorg'; Access = 'Write'; AuthScheme = 'Basic'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
        Mock Invoke-RestMethod { $script:Patched }
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'prints success only when the returned PR is completed' {
        $script:Patched = New-Pr 'completed' 'succeeded' $null
        $o = Try-Complete
        $o.Error | Should -BeNullOrEmpty
        $o.Result.status | Should -Be 'completed'
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match '\(ok\).*completed' } -Times 1
    }

    It 'throws AdoPullRequestConflict when the PR stays active with mergeStatus conflicts' {
        $script:Patched = New-Pr 'active' 'conflicts' $null
        $o = Try-Complete
        $o.Error | Should -Not -BeNullOrEmpty
        $o.Error.FullyQualifiedErrorId | Should -Match 'AdoPullRequestConflict'
        "$($o.Error)" | Should -Match 'conflicts'
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match '\(ok\)' } -Times 0
    }

    It 'includes mergeFailureMessage in the error when present' {
        $script:Patched = New-Pr 'active' 'conflicts' 'Conflicts in a.txt'
        $o = Try-Complete
        $o.Error | Should -Not -BeNullOrEmpty
        "$($o.Error)" | Should -Match 'Conflicts in a.txt'
    }

    It 'throws AdoPullRequestNotCompleted for mergeStatus <Merge>' -ForEach @(
        @{ Merge = 'rejectedByPolicy' }, @{ Merge = 'failure' }
    ) {
        $script:Patched = New-Pr 'active' $Merge 'because'
        $o = Try-Complete
        $o.Error | Should -Not -BeNullOrEmpty
        $o.Error.FullyQualifiedErrorId | Should -Match 'AdoPullRequestNotCompleted'
        "$($o.Error)" | Should -Match $Merge
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match '\(ok\)' } -Times 0
    }

    It 'throws AdoPullRequestNotCompleted when the PR is abandoned' {
        $script:Patched = New-Pr 'abandoned' 'notSet' $null
        $o = Try-Complete
        $o.Error | Should -Not -BeNullOrEmpty
        $o.Error.FullyQualifiedErrorId | Should -Match 'AdoPullRequestNotCompleted'
    }

    It 'warns and returns the PR, without claiming completion, for active + mergeStatus <Merge>' -ForEach @(
        @{ Merge = 'queued' }, @{ Merge = 'notSet' }, @{ Merge = 'succeeded' }
    ) {
        $script:Patched = New-Pr 'active' $Merge $null
        $o = Try-Complete
        $o.Error | Should -BeNullOrEmpty
        $o.Result.status | Should -Be 'active'
        Should -Invoke Write-Warning -ParameterFilter { "$Message" -match 'not completed yet' } -Times 1
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match '\(ok\)' } -Times 0
    }
}
