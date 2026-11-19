#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Tests for issue #38: pull request management (scripts/ado-pullrequests.ps1).
# No network access: Invoke-RestMethod / Invoke-WebRequest are mocked and every call is recorded.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pullrequests.ps1')

    $script:Base   = 'https://dev.azure.com/fakeorg/fakeproj/_apis/git/repositories/MyRepo'
    $script:PrBase = "$script:Base/pullrequests/42"
    $script:UserId = '11111111-2222-3333-4444-555555555555'

    function script:New-PrSession([string]$Access = 'Write') {
        [pscustomobject]@{
            Org        = 'fakeorg'
            Project    = 'fakeproj'
            ApiV       = '7.1'
            BaseUrl    = 'https://dev.azure.com/fakeorg'
            Access     = $Access
            AuthScheme = 'Basic'
            Headers    = @{ Authorization = 'Basic ZmFrZQ==' }
        }
    }

    # Canned responses keyed by method + URL shape. Records every call in $script:Calls.
    function script:Invoke-FakeAdo($Method, $Uri, $Body) {
        $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } elseif ($Body) { [string]$Body } else { $null }
        $u0 = if ($Uri -is [uri]) { $Uri.OriginalString } else { [string]$Uri }  # [uri]::ToString() unescapes
        $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = $u0; Body = $text })
        $u = $u0
        if ($u -match '/_apis/connectionData') {
            return [pscustomobject]@{ authenticatedUser = [pscustomobject]@{ id = $script:UserId; providerDisplayName = 'Me' } }
        }
        if ($Method -eq 'GET' -and $u -match '/pullrequests/42\?') {
            return [pscustomobject]@{ pullRequestId = 42; status = 'active'
                lastMergeSourceCommit = [pscustomobject]@{ commitId = 'abc123' } }
        }
        if ($Method -eq 'GET' -and $u -match '/pullrequests\?') {
            return [pscustomobject]@{ count = 0; value = @() }
        }
        return [pscustomobject]@{ id = 1; value = @(); count = 0 }
    }

    function script:Get-Call([string]$Method) {
        # Comma keeps a one-element result an array (.Count on a lone PSCustomObject is unreliable under StrictMode).
        ,@($script:Calls | Where-Object { $_.Method -eq $Method })
    }

    # Builds the error record Invoke-RestMethod throws for an HTTP error.
    function script:New-HttpError([int]$Status, [string]$Body = $null) {
        $ex = [System.Exception]::new("The remote server returned an error: ($Status).")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = @{} })
        $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        if ($Body) { $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
        $er
    }
}

AfterAll { $script:AdoSession = $null }

Describe 'Issue 38 - helpers' {
    It 'ConvertTo-AdoRefName adds refs/heads/ to "<In>"' -ForEach @(
        @{ In = 'main';                Out = 'refs/heads/main' }
        @{ In = 'refs/heads/main';     Out = 'refs/heads/main' }
        @{ In = 'feature/x';           Out = 'refs/heads/feature/x' }
        @{ In = 'release/1.0';         Out = 'refs/heads/release/1.0' }
        @{ In = 'heads/develop';       Out = 'refs/heads/heads/develop' }
        @{ In = 'refs/heads/refs/x';   Out = 'refs/heads/refs/x' }
    ) {
        ConvertTo-AdoRefName -Branch $In | Should -BeExactly $Out
    }

    It 'ConvertTo-AdoRefName only strips the exact lowercase prefix' {
        ConvertTo-AdoRefName -Branch 'Refs/Heads/main' | Should -BeExactly 'refs/heads/Refs/Heads/main'
    }

    It 'ConvertTo-AdoRefName rejects an empty branch' {
        { ConvertTo-AdoRefName -Branch ' ' } | Should -Throw
    }
}

Describe 'Issue 38 - pull requests: core lifecycle' {
    BeforeEach {
        $script:AdoSession = New-PrSession
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Invoke-FakeAdo $Method $Uri $Body }
        Mock Write-Host { }
        Mock Start-Sleep { }
    }

    It 'Get-AdoPullRequests builds searchCriteria and pages with $top/$skip' {
        $script:Page = 0
        Mock Invoke-RestMethod {
            Invoke-FakeAdo $Method $Uri $Body | Out-Null
            $script:Page++
            if ($script:Page -eq 1) { [pscustomobject]@{ count = 2; value = @([pscustomobject]@{ pullRequestId = 1 }, [pscustomobject]@{ pullRequestId = 2 }) } }
            else                    { [pscustomobject]@{ count = 1; value = @([pscustomobject]@{ pullRequestId = 3 }) } }
        }
        $r = Get-AdoPullRequests -RepoId 'MyRepo' -Status completed -CreatorId 'c1' -ReviewerId 'r1' `
                -SourceBranch 'feature/x' -TargetBranch 'main' -PageSize 2
        @($r).Count | Should -Be 3
        $gets = Get-Call GET
        $gets.Count | Should -Be 2
        $gets[0].Uri | Should -Match '^https://dev\.azure\.com/fakeorg/fakeproj/_apis/git/repositories/MyRepo/pullrequests\?'
        $gets[0].Uri | Should -Match 'searchCriteria\.status=completed'
        $gets[0].Uri | Should -Match 'searchCriteria\.creatorId=c1'
        $gets[0].Uri | Should -Match 'searchCriteria\.reviewerId=r1'
        $gets[0].Uri | Should -Match 'searchCriteria\.sourceRefName=refs%2Fheads%2Ffeature%2Fx'
        $gets[0].Uri | Should -Match 'searchCriteria\.targetRefName=refs%2Fheads%2Fmain'
        $gets[0].Uri | Should -Match '\$top=2'
        $gets[0].Uri | Should -Match '\$skip=0'
        $gets[0].Uri | Should -Match 'api-version=7\.1'
        $gets[1].Uri | Should -Match '\$skip=2'
    }

    It 'Get-AdoPullRequests -Top caps the number of items returned' {
        Mock Invoke-RestMethod {
            Invoke-FakeAdo $Method $Uri $Body | Out-Null
            [pscustomobject]@{ count = 3; value = @(1, 2, 3 | ForEach-Object { [pscustomobject]@{ pullRequestId = $_ } }) }
        }
        @(Get-AdoPullRequests -RepoId 'MyRepo' -Top 2).Count | Should -Be 2
        (Get-Call GET)[0].Uri | Should -Match '\$top=2'
    }

    It 'Get-AdoPullRequests escapes a repository name with spaces' {
        Get-AdoPullRequests -RepoId 'My Repo' | Out-Null
        (Get-Call GET)[0].Uri | Should -Match '/repositories/My%20Repo/pullrequests\?'
    }

    It 'Get-AdoPullRequest by repository uses the repository route' {
        Get-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -IncludeCommits | Out-Null
        $c = (Get-Call GET)[0]
        $c.Uri | Should -Match '^https://dev\.azure\.com/fakeorg/fakeproj/_apis/git/repositories/MyRepo/pullrequests/42\?'
        $c.Uri | Should -Match 'includeCommits=true'
    }

    It 'Get-AdoPullRequest without -RepoId uses the project-level route' {
        Get-AdoPullRequest -PullRequestId 42 | Out-Null
        (Get-Call GET)[0].Uri | Should -Match '^https://dev\.azure\.com/fakeorg/fakeproj/_apis/git/pullrequests/42\?api-version=7\.1'
    }

    It 'New-AdoPullRequest POSTs the documented body shape' {
        New-AdoPullRequest -RepoId 'MyRepo' -SourceBranch 'feature/x' -TargetBranch 'refs/heads/main' `
            -Title 'T' -Description 'D' -Draft -ReviewerIds 'u1' -RequiredReviewerIds 'u2' `
            -WorkItemIds 7, 8 -Labels 'l1' -Confirm:$false | Out-Null
        $c = (Get-Call POST)[0]
        $c.Uri | Should -Be "$script:Base/pullrequests?api-version=7.1"
        $b = $c.Body | ConvertFrom-Json
        $b.sourceRefName | Should -Be 'refs/heads/feature/x'
        $b.targetRefName | Should -Be 'refs/heads/main'
        $b.title         | Should -Be 'T'
        $b.description   | Should -Be 'D'
        $b.isDraft       | Should -BeTrue
        @($b.reviewers).Count | Should -Be 2
        ($b.reviewers | Where-Object id -eq 'u1').isRequired | Should -BeFalse
        ($b.reviewers | Where-Object id -eq 'u2').isRequired | Should -BeTrue
        @($b.workItemRefs.id) | Should -Be @('7', '8')
        @($b.labels.name)     | Should -Be @('l1')
    }

    It 'New-AdoPullRequest omits optional collections when not given' {
        New-AdoPullRequest -RepoId 'MyRepo' -SourceBranch 'a' -TargetBranch 'b' -Title 'T' -Confirm:$false | Out-Null
        $b = (Get-Call POST)[0].Body | ConvertFrom-Json
        $b.PSObject.Properties.Name | Should -Not -Contain 'reviewers'
        $b.PSObject.Properties.Name | Should -Not -Contain 'workItemRefs'
        $b.PSObject.Properties.Name | Should -Not -Contain 'labels'
        $b.isDraft | Should -BeFalse
    }

    It 'New-AdoPullRequest honours -WhatIf' {
        New-AdoPullRequest -RepoId 'MyRepo' -SourceBranch 'a' -TargetBranch 'b' -Title 'T' -WhatIf | Out-Null
        $script:Calls.Count | Should -Be 0
    }

    It 'Set-AdoPullRequest PATCHes only the fields given' {
        Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Title 'New' -TargetBranch 'develop' -Confirm:$false | Out-Null
        $c = (Get-Call PATCH)[0]
        $c.Uri | Should -Be "$script:PrBase`?api-version=7.1"
        $b = $c.Body | ConvertFrom-Json
        $b.title         | Should -Be 'New'
        $b.targetRefName | Should -Be 'refs/heads/develop'
        $b.PSObject.Properties.Name | Should -Not -Contain 'description'
        $b.PSObject.Properties.Name | Should -Not -Contain 'isDraft'
    }

    It 'Set-AdoPullRequest -Publish sends isDraft false, -Draft sends true' {
        Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Publish -Confirm:$false | Out-Null
        ((Get-Call PATCH)[0].Body | ConvertFrom-Json).isDraft | Should -BeFalse
        Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Draft -Confirm:$false | Out-Null
        ((Get-Call PATCH)[1].Body | ConvertFrom-Json).isDraft | Should -BeTrue
    }

    It 'Set-AdoPullRequest rejects -Draft with -Publish, and an empty update' {
        { Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Draft -Publish -Confirm:$false } | Should -Throw
        { Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false } | Should -Throw '*Nothing to update*'
        (Get-Call PATCH).Count | Should -Be 0
    }

    It 'Stop-AdoPullRequest abandons (status abandoned) with ConfirmImpact High' {
        (Get-Command Stop-AdoPullRequest).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { $_.ConfirmImpact } | Should -Be 'High'
        Stop-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false | Out-Null
        $c = (Get-Call PATCH)[0]
        $c.Uri | Should -Be "$script:PrBase`?api-version=7.1"
        ($c.Body | ConvertFrom-Json).status | Should -Be 'abandoned'
    }

    It 'Restore-AdoPullRequest reactivates (status active)' {
        Restore-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false | Out-Null
        ((Get-Call PATCH)[0].Body | ConvertFrom-Json).status | Should -Be 'active'
    }

    It 'Complete-AdoPullRequest fetches lastMergeSourceCommit when not given' {
        (Get-Command Complete-AdoPullRequest).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { $_.ConfirmImpact } | Should -Be 'High'
        Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -MergeStrategy squash `
            -DeleteSourceBranch -TransitionWorkItems -MergeCommitMessage 'msg' -Confirm:$false | Out-Null
        (Get-Call GET)[0].Uri | Should -Match '/repositories/MyRepo/pullrequests/42\?'
        $b = (Get-Call PATCH)[0].Body | ConvertFrom-Json
        $b.status                                  | Should -Be 'completed'
        $b.lastMergeSourceCommit.commitId          | Should -Be 'abc123'
        $b.completionOptions.mergeStrategy         | Should -Be 'squash'
        $b.completionOptions.deleteSourceBranch    | Should -BeTrue
        $b.completionOptions.transitionWorkItems   | Should -BeTrue
        $b.completionOptions.mergeCommitMessage    | Should -Be 'msg'
    }

    It 'Complete-AdoPullRequest uses an explicit commit id without fetching' {
        Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -LastMergeSourceCommitId 'def456' -Confirm:$false | Out-Null
        (Get-Call GET).Count | Should -Be 0
        $b = (Get-Call PATCH)[0].Body | ConvertFrom-Json
        $b.lastMergeSourceCommit.commitId        | Should -Be 'def456'
        $b.completionOptions.mergeStrategy       | Should -Be 'noFastForward'
        $b.completionOptions.deleteSourceBranch  | Should -BeFalse
        $b.completionOptions.transitionWorkItems | Should -BeFalse
    }

    It 'Complete-AdoPullRequest rejects an undocumented merge strategy' {
        { Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -MergeStrategy fastForward -Confirm:$false } | Should -Throw
    }

    It 'Complete-AdoPullRequest fails clearly when the PR has no lastMergeSourceCommit' {
        Mock Invoke-RestMethod {
            Invoke-FakeAdo $Method $Uri $Body | Out-Null
            [pscustomobject]@{ pullRequestId = 42; status = 'active' }
        }
        { Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false } | Should -Throw '*lastMergeSourceCommit*'
        (Get-Call PATCH).Count | Should -Be 0
    }

    It 'Complete-AdoPullRequest surfaces a 409 conflict as AdoPullRequestConflict' {
        Mock Invoke-RestMethod {
            Invoke-FakeAdo $Method $Uri $Body | Out-Null
            if ($Method -eq 'PATCH') { throw (New-HttpError -Status 409 -Body '{"message":"TF401181: The pull request cannot be completed"}') }
        }
        $err = $null
        try { Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -LastMergeSourceCommitId 'x' -Confirm:$false } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoPullRequestConflict'
        "$err" | Should -Match '409'
        "$err" | Should -Match 'TF401181'
        (Get-Call PATCH).Count | Should -Be 1
    }

    It 'Complete-AdoPullRequest honours -WhatIf (no PATCH)' {
        Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -LastMergeSourceCommitId 'x' -WhatIf | Out-Null
        (Get-Call PATCH).Count | Should -Be 0
    }

    It 'Set-AdoPullRequestAutoComplete sets autoCompleteSetBy to the current user' {
        Set-AdoPullRequestAutoComplete -RepoId 'MyRepo' -PullRequestId 42 -MergeStrategy rebase -DeleteSourceBranch -Confirm:$false | Out-Null
        $b = (Get-Call PATCH)[0].Body | ConvertFrom-Json
        $b.autoCompleteSetBy.id                | Should -Be $script:UserId
        $b.completionOptions.mergeStrategy     | Should -Be 'rebase'
        $b.completionOptions.deleteSourceBranch | Should -BeTrue
    }

    It 'Set-AdoPullRequestAutoComplete -Disable clears autoCompleteSetBy (empty GUID)' {
        Set-AdoPullRequestAutoComplete -RepoId 'MyRepo' -PullRequestId 42 -Disable -Confirm:$false | Out-Null
        $b = (Get-Call PATCH)[0].Body | ConvertFrom-Json
        $b.autoCompleteSetBy.id | Should -Be '00000000-0000-0000-0000-000000000000'
        $b.PSObject.Properties.Name | Should -Not -Contain 'completionOptions'
    }
}

Describe 'Issue 38 - reviewers and votes' {
    BeforeEach {
        $script:AdoSession = New-PrSession
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Invoke-FakeAdo $Method $Uri $Body }
        Mock Write-Host { }
    }

    It 'Get-AdoPullRequestReviewers GETs the reviewers collection' {
        Get-AdoPullRequestReviewers -RepoId 'MyRepo' -PullRequestId 42 | Out-Null
        (Get-Call GET)[0].Uri | Should -Be "$script:PrBase/reviewers?api-version=7.1"
    }

    It 'Add-AdoPullRequestReviewer PUTs {id, isRequired}' {
        Add-AdoPullRequestReviewer -RepoId 'MyRepo' -PullRequestId 42 -ReviewerId 'u9' -Required -Confirm:$false | Out-Null
        $c = (Get-Call PUT)[0]
        $c.Uri | Should -Be "$script:PrBase/reviewers/u9?api-version=7.1"
        $b = $c.Body | ConvertFrom-Json
        $b.id         | Should -Be 'u9'
        $b.isRequired | Should -BeTrue
        $b.PSObject.Properties.Name | Should -Not -Contain 'vote'
    }

    It 'Remove-AdoPullRequestReviewer DELETEs the reviewer' {
        Remove-AdoPullRequestReviewer -RepoId 'MyRepo' -PullRequestId 42 -ReviewerId 'u9' -Confirm:$false | Out-Null
        (Get-Call DELETE)[0].Uri | Should -Be "$script:PrBase/reviewers/u9?api-version=7.1"
    }

    It 'Set-AdoPullRequestVote -Vote <Vote> sends <Value>' -ForEach @(
        @{ Vote = 'Approve';                Value = 10 }
        @{ Vote = 'ApproveWithSuggestions'; Value = 5 }
        @{ Vote = 'NoVote';                 Value = 0 }
        @{ Vote = 'WaitForAuthor';          Value = -5 }
        @{ Vote = 'Reject';                 Value = -10 }
    ) {
        Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote $Vote -Confirm:$false | Out-Null
        $c = (Get-Call PUT)[0]
        $c.Uri | Should -Be "$script:PrBase/reviewers/$script:UserId`?api-version=7.1"
        $b = $c.Body | ConvertFrom-Json
        $b.vote | Should -Be $Value
        $b.id   | Should -Be $script:UserId
    }

    It 'resolves the current user once per session and caches it on the session' {
        Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote Approve -Confirm:$false | Out-Null
        Approve-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false | Out-Null
        @($script:Calls | Where-Object { $_.Uri -match 'connectionData' }).Count | Should -Be 1
        $script:AdoSession.AuthenticatedUserId | Should -Be $script:UserId
    }

    It 'Approve-AdoPullRequest votes 10' {
        Approve-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false | Out-Null
        ((Get-Call PUT)[0].Body | ConvertFrom-Json).vote | Should -Be 10
    }

    It 'an explicit -ReviewerId skips connectionData' {
        Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote Reject -ReviewerId 'other' -Confirm:$false | Out-Null
        @($script:Calls | Where-Object { $_.Uri -match 'connectionData' }).Count | Should -Be 0
        (Get-Call PUT)[0].Uri | Should -Match '/reviewers/other\?'
    }

    It 'fails clearly when the current user id cannot be resolved' {
        Mock Invoke-RestMethod {
            Invoke-FakeAdo $Method $Uri $Body | Out-Null
            if ($Uri -match 'connectionData') { return [pscustomobject]@{ instanceId = 'x' } }
        }
        { Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote Approve -Confirm:$false } |
            Should -Throw '*authenticated user*'
        (Get-Call PUT).Count | Should -Be 0
    }

    It 'Get-AdoCurrentUserId calls the organization-level connectionData route' {
        Get-AdoCurrentUserId | Should -Be $script:UserId
        $script:Calls[0].Uri | Should -Be 'https://dev.azure.com/fakeorg/_apis/connectionData'
    }

    It 'rejects an unknown vote value' {
        { Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote Maybe -Confirm:$false } | Should -Throw
    }
}

Describe 'Issue 38 - error propagation' {
    BeforeEach {
        $script:AdoSession = New-PrSession
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Start-Sleep { }
        Mock Write-Host { }
    }

    It 'HTTP <Status> on <Name> surfaces <Pattern>' -ForEach @(
        @{ Status = 401; Name = 'Get-AdoPullRequest';  Pattern = '401 Unauthorized*' }
        @{ Status = 403; Name = 'Get-AdoPullRequest';  Pattern = '403 Forbidden*' }
        @{ Status = 404; Name = 'Get-AdoPullRequest';  Pattern = '404 Not Found*' }
        @{ Status = 401; Name = 'Stop-AdoPullRequest'; Pattern = '401 Unauthorized*' }
        @{ Status = 403; Name = 'Stop-AdoPullRequest'; Pattern = '403 Forbidden*' }
        @{ Status = 404; Name = 'Stop-AdoPullRequest'; Pattern = '404 Not Found*' }
    ) {
        $s = $Status
        Mock Invoke-RestMethod { throw (New-HttpError -Status $s) }
        $sb = if ($Name -eq 'Get-AdoPullRequest') { { Get-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 } }
              else { { Stop-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Confirm:$false } }
        $sb | Should -Throw $Pattern
    }
}

Describe 'Issue 38 - Read session (write guard from #18)' {
    BeforeEach {
        $script:AdoSession = New-PrSession -Access 'Read'
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Invoke-FakeAdo $Method $Uri $Body }
        Mock Invoke-WebRequest {
            Invoke-FakeAdo 'GET' $Uri $null | Out-Null
            [pscustomobject]@{ Content = '{"value":[]}'; Headers = @{} }
        }
        Mock Write-Host { }
    }

    It 'write function <Name> is refused and sends no write' -ForEach @(
        @{ Name = 'New-AdoPullRequest';             Params = @{ RepoId = 'MyRepo'; SourceBranch = 'a'; TargetBranch = 'b'; Title = 't' } }
        @{ Name = 'Set-AdoPullRequest';             Params = @{ RepoId = 'MyRepo'; PullRequestId = 42; Title = 't' } }
        @{ Name = 'Stop-AdoPullRequest';            Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Restore-AdoPullRequest';         Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Complete-AdoPullRequest';        Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Set-AdoPullRequestAutoComplete'; Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Add-AdoPullRequestReviewer';     Params = @{ RepoId = 'MyRepo'; PullRequestId = 42; ReviewerId = 'u' } }
        @{ Name = 'Remove-AdoPullRequestReviewer';  Params = @{ RepoId = 'MyRepo'; PullRequestId = 42; ReviewerId = 'u' } }
        @{ Name = 'Set-AdoPullRequestVote';         Params = @{ RepoId = 'MyRepo'; PullRequestId = 42; Vote = 'Reject' } }
        @{ Name = 'Approve-AdoPullRequest';         Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
    ) {
        $a = $Params
        $err = $null
        try { & $Name @a -Confirm:$false } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.FullyQualifiedErrorId | Should -Match 'AdoReadOnlySession'
        @($script:Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
    }

    It 'read function <Name> works' -ForEach @(
        @{ Name = 'Get-AdoPullRequests';          Params = @{ RepoId = 'MyRepo' } }
        @{ Name = 'Get-AdoPullRequest';           Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Get-AdoPullRequestReviewers';  Params = @{ RepoId = 'MyRepo'; PullRequestId = 42 } }
        @{ Name = 'Get-AdoCurrentUserId';         Params = @{} }
    ) {
        $a = $Params
        { & $Name @a } | Should -Not -Throw
        $script:Calls.Count | Should -BeGreaterThan 0
        @($script:Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
    }

    It 'every SupportsShouldProcess function in ado-pullrequests.ps1 is covered by the refusal table' {
        $file = Join-Path $script:ScriptsDir 'ado-pullrequests.ps1'
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $writers = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Body.ParamBlock -and ($_.Body.ParamBlock.Attributes | Where-Object {
                $_.TypeName.Name -eq 'CmdletBinding' -and ($_.NamedArguments.ArgumentName -contains 'SupportsShouldProcess') }) } |
            ForEach-Object Name
        $covered = 'New-AdoPullRequest', 'Set-AdoPullRequest', 'Stop-AdoPullRequest', 'Restore-AdoPullRequest',
                   'Complete-AdoPullRequest', 'Set-AdoPullRequestAutoComplete', 'Add-AdoPullRequestReviewer',
                   'Remove-AdoPullRequestReviewer', 'Set-AdoPullRequestVote', 'Approve-AdoPullRequest'
        @($writers | Where-Object { $_ -notin $covered }) | Should -BeNullOrEmpty
    }
}

Describe 'Issue 38 - load.ps1' {
    It 'load.ps1 dot-sources ado-pullrequests.ps1' {
        $load = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'load.ps1')
        $load | Should -Match 'scripts/ado-pullrequests\.ps1'
    }
}
