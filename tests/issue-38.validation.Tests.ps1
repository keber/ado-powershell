#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Independent validation tests for issue #38 (pull requests, scripts/ado-pullrequests.ps1).
# Mocked HTTP; the one test that uses a local HttpListener (127.0.0.1) is tagged Integration.

BeforeDiscovery {
    $prScript = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts\ado-pullrequests.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($prScript, [ref]$null, [ref]$null)
    $PrWriteCases = @(
        $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            Where-Object { $_.Body.ParamBlock -and ($_.Body.ParamBlock.Attributes | Where-Object {
                $_.TypeName.Name -eq 'CmdletBinding' -and ($_.NamedArguments | Where-Object ArgumentName -eq 'SupportsShouldProcess') }) } |
            ForEach-Object { @{ Name = $_.Name } }
    )
}

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pullrequests.ps1')

    $script:Repo   = 'https://dev.azure.com/fakeorg/fakeproj/_apis/git/repositories/MyRepo'
    $script:Pr     = "$script:Repo/pullrequests/42"
    $script:UserA  = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:UserB  = 'bbbbbbbb-0000-0000-0000-000000000002'
    $script:Secret = 'VAL38SECRETPAT0123456789'

    function script:New-Sess([string]$Access = 'Write', [string]$Auth = 'Basic ZmFrZQ==') {
        [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/fakeorg'
                           Access = $Access; AuthScheme = 'Basic'; Headers = @{ Authorization = $Auth } }
    }

    # Records calls; connectionData answers with the user that owns the Authorization header used.
    function script:Fake($Method, $Uri, $Body, $Headers) {
        $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } elseif ($Body) { [string]$Body } else { $null }
        $u = if ($Uri -is [uri]) { $Uri.OriginalString } else { [string]$Uri }
        $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = $u; Body = $text; Auth = [string]$Headers.Authorization })
        if ($u -match '/_apis/connectionData') {
            $id = if ([string]$Headers.Authorization -eq 'Basic B') { $script:UserB } else { $script:UserA }
            return [pscustomobject]@{ authenticatedUser = [pscustomobject]@{ id = $id } }
        }
        if ("$Method" -eq 'GET' -and $u -match '/pullrequests/42\?') {
            return [pscustomobject]@{ pullRequestId = 42; lastMergeSourceCommit = [pscustomobject]@{ commitId = 'abc123' } }
        }
        if ("$Method" -eq 'GET' -and $u -match '/iterations\?') {
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 3 }, [pscustomobject]@{ id = 2 }) }
        }
        return [pscustomobject]@{ id = 1; value = @() }
    }
    function script:Writes { ,@($script:Calls | Where-Object { $_.Method -notin 'GET', 'Get', 'Default', '' }) }
    function script:Json($c) { $c.Body | ConvertFrom-Json }

    function script:New-HttpError([int]$Status, [string]$Body = $null) {
        $ex = [System.Exception]::new("The remote server returned an error: ($Status).")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = @{} })
        $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        if ($Body) { $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
        $er
    }

    function script:Get-DummyArgs([string]$Name) {
        $cmd = Get-Command $Name
        $a = @{ RepoId = 'MyRepo' }
        foreach ($p in ($cmd.ParameterSets[0].Parameters | Where-Object IsMandatory)) {
            if ($a.ContainsKey($p.Name)) { continue }
            $vs = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
            $a[$p.Name] = if ($vs) { $vs.ValidValues[0] } elseif ($p.ParameterType -eq [int]) { 42 } else { 'x' }
        }
        if ($cmd.Parameters.ContainsKey('PullRequestId')) { $a['PullRequestId'] = 42 }
        if ($Name -eq 'New-AdoPullRequest') { $a['SourceBranch'] = 'f'; $a['TargetBranch'] = 'main'; $a['Title'] = 't' }
        if ($Name -eq 'Set-AdoPullRequest') { $a['Title'] = 't' }
        if ($cmd.Parameters.ContainsKey('Confirm')) { $a['Confirm'] = $false }
        $a
    }
}

Describe 'V38 routes, methods, bodies (7.1 docs)' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Fake $Method $Uri $Body $Headers }
        Mock Write-Host { }
        $script:AdoSession = New-Sess
    }

    It 'Complete: GET PR then PATCH status=completed with lastMergeSourceCommit and completionOptions' {
        Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -MergeStrategy squash -DeleteSourceBranch -TransitionWorkItems -MergeCommitMessage 'm' -Confirm:$false | Out-Null
        $w = Writes; $w.Count | Should -Be 1
        $w[0].Method | Should -Be 'PATCH'
        $w[0].Uri | Should -BeExactly "$script:Pr`?api-version=7.1"
        $b = Json $w[0]
        $b.status | Should -BeExactly 'completed'
        $b.lastMergeSourceCommit.commitId | Should -Be 'abc123'
        $b.completionOptions.mergeStrategy | Should -BeExactly 'squash'
        $b.completionOptions.deleteSourceBranch | Should -BeTrue
        $b.completionOptions.transitionWorkItems | Should -BeTrue
        $b.completionOptions.mergeCommitMessage | Should -Be 'm'
    }

    It 'Complete with explicit commit id does not GET the PR' {
        Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'fff' -Confirm:$false | Out-Null
        $script:Calls.Count | Should -Be 1
        (Json $script:Calls[0]).completionOptions.mergeStrategy | Should -BeExactly 'noFastForward'
    }

    It 'Complete canonicalises -MergeStrategy casing (ValidateSet is case-insensitive)' {
        Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'fff' -MergeStrategy REBASEMERGE -Confirm:$false | Out-Null
        (Json $script:Calls[0]).completionOptions.mergeStrategy | Should -BeExactly 'rebaseMerge'
    }

    It 'AutoComplete enable: autoCompleteSetBy.id = current user + completionOptions' {
        Set-AdoPullRequestAutoComplete -RepoId MyRepo -PullRequestId 42 -MergeStrategy squash -Confirm:$false | Out-Null
        $w = Writes; $w.Count | Should -Be 1; $w[0].Method | Should -Be 'PATCH'
        $b = Json $w[0]
        $b.autoCompleteSetBy.id | Should -Be $script:UserA
        $b.completionOptions.mergeStrategy | Should -BeExactly 'squash'
    }

    It 'AutoComplete disable: empty GUID, no completionOptions, no connectionData call' {
        Set-AdoPullRequestAutoComplete -RepoId MyRepo -PullRequestId 42 -Disable -Confirm:$false | Out-Null
        $script:Calls.Count | Should -Be 1
        $b = Json $script:Calls[0]
        $b.autoCompleteSetBy.id | Should -Be '00000000-0000-0000-0000-000000000000'
        $b.PSObject.Properties['completionOptions'] | Should -BeNullOrEmpty
    }

    It 'Vote: PUT reviewers/{reviewerId} with body {id, vote} for <V>' -ForEach @(
        @{ V = 'Approve'; N = 10 }, @{ V = 'ApproveWithSuggestions'; N = 5 }, @{ V = 'NoVote'; N = 0 },
        @{ V = 'WaitForAuthor'; N = -5 }, @{ V = 'Reject'; N = -10 }) {
        Set-AdoPullRequestVote -RepoId MyRepo -PullRequestId 42 -Vote $V -Confirm:$false | Out-Null
        $w = Writes; $w.Count | Should -Be 1
        $w[0].Method | Should -Be 'PUT'
        $w[0].Uri | Should -BeExactly "$script:Pr/reviewers/$script:UserA`?api-version=7.1"
        $b = Json $w[0]; $b.vote | Should -Be $N; $b.id | Should -Be $script:UserA
    }

    It 'Approve-AdoPullRequest sends vote 10 as the current user' {
        Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null
        (Json (Writes)[0]).vote | Should -Be 10
    }

    It 'Add reviewer: PUT reviewers/{id}, isRequired; Remove: DELETE reviewers/{id}' {
        Add-AdoPullRequestReviewer -RepoId MyRepo -PullRequestId 42 -ReviewerId $script:UserB -Required -Confirm:$false | Out-Null
        Remove-AdoPullRequestReviewer -RepoId MyRepo -PullRequestId 42 -ReviewerId $script:UserB -Confirm:$false | Out-Null
        $w = Writes
        $w[0].Method | Should -Be 'PUT'; (Json $w[0]).isRequired | Should -BeTrue
        $w[0].Uri | Should -BeExactly "$script:Pr/reviewers/$script:UserB`?api-version=7.1"
        $w[1].Method | Should -Be 'DELETE'; $w[1].Uri | Should -BeExactly "$script:Pr/reviewers/$script:UserB`?api-version=7.1"
    }

    It 'Thread anchored to file/line (Right): threadContext.rightFileStart/End, leading slash added' {
        New-AdoPullRequestThread -RepoId MyRepo -PullRequestId 42 -Content 'c' -FilePath 'src/a.ps1' -Line 10 -EndLine 12 -Confirm:$false | Out-Null
        $c = (Writes)[0]
        $c.Method | Should -Be 'POST'; $c.Uri | Should -BeExactly "$script:Pr/threads?api-version=7.1"
        $b = Json $c
        $b.threadContext.filePath | Should -BeExactly '/src/a.ps1'
        $b.threadContext.rightFileStart.line | Should -Be 10
        $b.threadContext.rightFileEnd.line | Should -Be 12
        $b.threadContext.rightFileStart.offset | Should -Be 1
        @($b.comments).Count | Should -Be 1
        $b.comments[0].content | Should -Be 'c'
        $b.comments[0].commentType | Should -BeExactly 'text'
        $b.status | Should -BeExactly 'active'
    }

    It 'Thread on Left side uses leftFileStart/End; general thread has no threadContext' {
        New-AdoPullRequestThread -RepoId MyRepo -PullRequestId 42 -Content 'c' -FilePath '/a' -Line 3 -Side Left -Confirm:$false | Out-Null
        New-AdoPullRequestThread -RepoId MyRepo -PullRequestId 42 -Content 'g' -Confirm:$false | Out-Null
        $w = Writes
        (Json $w[0]).threadContext.leftFileStart.line | Should -Be 3
        (Json $w[0]).threadContext.PSObject.Properties['rightFileStart'] | Should -BeNullOrEmpty
        (Json $w[1]).PSObject.Properties['threadContext'] | Should -BeNullOrEmpty
    }

    It 'New thread canonicalises -Status casing' {
        New-AdoPullRequestThread -RepoId MyRepo -PullRequestId 42 -Content 'c' -Status WONTFIX -Confirm:$false | Out-Null
        (Json (Writes)[0]).status | Should -BeExactly 'wontFix'
    }

    It 'Reply: POST threads/{t}/comments with parentCommentId' {
        Add-AdoPullRequestComment -RepoId MyRepo -PullRequestId 42 -ThreadId 7 -Content 'r' -ParentCommentId 1 -Confirm:$false | Out-Null
        $c = (Writes)[0]
        $c.Uri | Should -BeExactly "$script:Pr/threads/7/comments?api-version=7.1"
        (Json $c).parentCommentId | Should -Be 1
    }

    It 'Thread status: PATCH threads/{t} with canonical status' {
        Set-AdoPullRequestThreadStatus -RepoId MyRepo -PullRequestId 42 -ThreadId 7 -Status BYDESIGN -Confirm:$false | Out-Null
        $c = (Writes)[0]; $c.Method | Should -Be 'PATCH'
        $c.Uri | Should -BeExactly "$script:Pr/threads/7?api-version=7.1"
        (Json $c).status | Should -BeExactly 'byDesign'
    }

    It 'Labels: POST labels {name}; DELETE labels/{escaped name}' {
        Add-AdoPullRequestLabel -RepoId MyRepo -PullRequestId 42 -Name 'needs qa' -Confirm:$false | Out-Null
        Remove-AdoPullRequestLabel -RepoId MyRepo -PullRequestId 42 -Name 'needs qa' -Confirm:$false | Out-Null
        $w = Writes
        $w[0].Uri | Should -BeExactly "$script:Pr/labels?api-version=7.1"; (Json $w[0]).name | Should -Be 'needs qa'
        $w[1].Method | Should -Be 'DELETE'; $w[1].Uri | Should -BeExactly "$script:Pr/labels/needs%20qa?api-version=7.1"
    }

    It 'Status: POST statuses with state, context{name,genre}, iterationId' {
        New-AdoPullRequestStatus -RepoId MyRepo -PullRequestId 42 -State SUCCEEDED -ContextName n -ContextGenre g -IterationId 2 -TargetUrl 'https://x' -Confirm:$false | Out-Null
        $c = (Writes)[0]; $c.Uri | Should -BeExactly "$script:Pr/statuses?api-version=7.1"
        $b = Json $c
        $b.state | Should -BeExactly 'succeeded'; $b.context.name | Should -Be 'n'; $b.context.genre | Should -Be 'g'; $b.iterationId | Should -Be 2
    }

    It 'Create: refs normalised, reviewers, workItemRefs, labels, isDraft' {
        New-AdoPullRequest -RepoId MyRepo -SourceBranch 'feature/x' -TargetBranch 'refs/heads/main' -Title t -Draft `
            -ReviewerIds 'r1' -RequiredReviewerIds 'r2' -WorkItemIds 5 -Labels 'l' -Confirm:$false | Out-Null
        $c = (Writes)[0]; $c.Method | Should -Be 'POST'; $c.Uri | Should -BeExactly "$script:Repo/pullrequests?api-version=7.1"
        $b = Json $c
        $b.sourceRefName | Should -BeExactly 'refs/heads/feature/x'
        $b.targetRefName | Should -BeExactly 'refs/heads/main'
        $b.isDraft | Should -BeTrue
        @($b.reviewers).Count | Should -Be 2
        ($b.reviewers | Where-Object id -eq 'r2').isRequired | Should -BeTrue
        $b.workItemRefs[0].id | Should -Be '5'
        $b.labels[0].name | Should -Be 'l'
    }

    It 'Stop/Restore: PATCH status abandoned / active' {
        Stop-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null
        Restore-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null
        $w = Writes
        (Json $w[0]).status | Should -BeExactly 'abandoned'
        (Json $w[1]).status | Should -BeExactly 'active'
    }

    It 'List: searchCriteria.* query, $top/$skip, api-version' {
        Get-AdoPullRequests -RepoId MyRepo -Status completed -TargetBranch main -SourceBranch 'f/a b' -CreatorId 'c1' | Out-Null
        $u = $script:Calls[0].Uri
        $u | Should -Match 'searchCriteria\.status=completed'
        $u | Should -Match 'searchCriteria\.targetRefName=refs%2Fheads%2Fmain'
        $u | Should -Match 'searchCriteria\.sourceRefName=refs%2Fheads%2Ff%2Fa%20b'
        $u | Should -Match 'searchCriteria\.creatorId=c1'
        $u | Should -Match 'api-version=7\.1'
        $u | Should -Match '\$top=100&\$skip=0'
    }

    It 'Changes default to the highest iteration id, not the last element' {
        Get-AdoPullRequestChanges -RepoId MyRepo -PullRequestId 42 | Out-Null
        ($script:Calls | Where-Object Uri -match '/iterations/3/changes') | Should -Not -BeNullOrEmpty
    }
}

Describe 'V38 branch normalisation and URL escaping' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Fake $Method $Uri $Body $Headers }
        Mock Write-Host { }
        $script:AdoSession = New-Sess
    }

    It 'ConvertTo-AdoRefName: <In> -> <Out>' -ForEach @(
        @{ In = 'main'; Out = 'refs/heads/main' }
        @{ In = 'refs/heads/main'; Out = 'refs/heads/main' }
        @{ In = 'feature/refs/heads/x'; Out = 'refs/heads/feature/refs/heads/x' }
        @{ In = 'Refs/Heads/main'; Out = 'refs/heads/Refs/Heads/main' }
        @{ In = 'refs/heads/refs/heads/x'; Out = 'refs/heads/refs/heads/x' }
    ) { ConvertTo-AdoRefName $In | Should -BeExactly $Out }

    It 'empty / whitespace branch is rejected' {
        { ConvertTo-AdoRefName '  ' } | Should -Throw
    }

    It 'repository name with space, #, ?, % and / is escaped in the path' {
        Get-AdoPullRequestReviewers -RepoId 'My Repo#1?%/x' -PullRequestId 42 | Out-Null
        $script:Calls[0].Uri | Should -BeExactly 'https://dev.azure.com/fakeorg/fakeproj/_apis/git/repositories/My%20Repo%231%3F%25%2Fx/pullrequests/42/reviewers?api-version=7.1'
    }

    It 'branch with + # & in a target ref is escaped in the query' {
        Get-AdoPullRequests -RepoId MyRepo -TargetBranch 'rel/1+2#x&y' | Out-Null
        $script:Calls[0].Uri | Should -Match 'targetRefName=refs%2Fheads%2Frel%2F1%2B2%23x%26y&'
    }

    # V38-006: project-name escaping is library-wide, fixed in #41 (Get-AdoProjectUrl).
    It 'project name with # does not truncate the request URL (library-wide convention)' {
        Get-AdoPullRequestReviewers -RepoId MyRepo -PullRequestId 42 -Project 'Proj#2' | Out-Null
        $script:Calls[0].Uri | Should -Not -Match '/Proj#2/'
        $script:Calls[0].Uri | Should -BeLike 'https://dev.azure.com/fakeorg/Proj%232/_apis/git/repositories/MyRepo/pullrequests/42/reviewers?*'
    }
}

Describe 'V38 paging termination' {
    BeforeEach { Mock Write-Host { }; $script:AdoSession = New-Sess }

    It 'skip-paging stops on an empty first page (1 request)' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; [pscustomobject]@{ value = @() } }
        @(Get-AdoPullRequests -RepoId MyRepo).Count | Should -Be 0
        $script:n | Should -Be 1
    }

    It 'skip-paging stops when the response has no value property' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; [pscustomobject]@{ count = 0 } }
        @(Get-AdoPullRequests -RepoId MyRepo).Count | Should -Be 0
        $script:n | Should -Be 1
    }

    It 'skip-paging collects full pages then stops on a short page' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; $c = if ($script:n -lt 3) { 2 } else { 1 }; [pscustomobject]@{ value = @(1..$c | ForEach-Object { [pscustomobject]@{ id = "$script:n-$_" } }) } }
        @(Get-AdoPullRequests -RepoId MyRepo -PageSize 2).Count | Should -Be 5
        $script:n | Should -Be 3
    }

    It '-Top caps both items and requests' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; [pscustomobject]@{ value = @(1..3 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
        @(Get-AdoPullRequests -RepoId MyRepo -Top 3).Count | Should -Be 3
        $script:n | Should -Be 1
    }

    It 'skip-paging terminates if the server ignores $skip and repeats a full page' {
        $script:n = 0
        Mock Invoke-RestMethod {
            $script:n++
            if ($script:n -gt 50) { throw 'runaway paging (more than 50 requests)' }
            [pscustomobject]@{ value = @(1..2 | ForEach-Object { [pscustomobject]@{ pullRequestId = $_ } }) }
        }
        { Get-AdoPullRequests -RepoId MyRepo -PageSize 2 } | Should -Not -Throw
    }

    It 'changes paging: stops when nextTop/nextSkip are 0 or absent, or do not advance' -ForEach @(
        @{ Case = 'zero';   R = @{ changeEntries = @(1); nextSkip = 0; nextTop = 0 } }
        @{ Case = 'absent'; R = @{ changeEntries = @(1) } }
        @{ Case = 'stuck';  R = @{ changeEntries = @(1); nextSkip = 0; nextTop = 100 } }
    ) {
        $script:n = 0; $script:R = $R
        Mock Invoke-RestMethod { $script:n++; if ($script:n -gt 20) { throw 'runaway' }; [pscustomobject]$script:R }
        @(Get-AdoPullRequestChanges -RepoId MyRepo -PullRequestId 42 -IterationId 1).Count | Should -Be 1
        $script:n | Should -Be 1
    }

    It 'changes paging follows nextSkip/nextTop and clamps $top to 2000' {
        $script:n = 0
        Mock Invoke-RestMethod {
            $script:n++
            $script:LastUri = if ($Uri -is [uri]) { $Uri.OriginalString } else { "$Uri" }
            if ($script:n -eq 1) { [pscustomobject]@{ changeEntries = @(1, 2); nextSkip = 2; nextTop = 5000 } }
            else { [pscustomobject]@{ changeEntries = @(3); nextSkip = 0; nextTop = 0 } }
        }
        @(Get-AdoPullRequestChanges -RepoId MyRepo -PullRequestId 42 -IterationId 1 -PageSize 2).Count | Should -Be 3
        $script:LastUri | Should -Match '\$top=2000&\$skip=2'
    }
}

Describe 'V38 connectionData caching' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Fake $Method $Uri $Body $Headers }
        Mock Write-Host { }
    }
    It 'is fetched once per session across several votes' {
        $script:AdoSession = New-Sess
        1..3 | ForEach-Object { Set-AdoPullRequestVote -RepoId MyRepo -PullRequestId 42 -Vote Approve -Confirm:$false | Out-Null }
        @($script:Calls | Where-Object Uri -match 'connectionData').Count | Should -Be 1
    }
    It 'a new session (re-init with another credential) re-fetches and uses the new user' {
        $script:AdoSession = New-Sess
        Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null
        $script:AdoSession = New-Sess -Auth 'Basic B'
        Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null
        $w = Writes
        $w[1].Uri | Should -Match "/reviewers/$script:UserB\?"
    }
    It 'explicit -Headers of another credential do not reuse the session user id' {
        $script:AdoSession = New-Sess
        Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null       # caches UserA
        Set-AdoPullRequestVote -RepoId MyRepo -PullRequestId 42 -Vote Approve -Headers @{ Authorization = 'Basic B' } -Confirm:$false | Out-Null
        $last = (Writes)[-1]
        $last.Auth | Should -Be 'Basic B'
        $last.Uri | Should -Match "/reviewers/$script:UserB\?"
    }
    It 'explicit -Headers of another credential do not overwrite the session cache' {
        $script:AdoSession = New-Sess
        Set-AdoPullRequestVote -RepoId MyRepo -PullRequestId 42 -Vote Approve -Headers @{ Authorization = 'Basic B' } -Confirm:$false | Out-Null
        Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false | Out-Null       # session credential (UserA)
        (Writes)[-1].Uri | Should -Match "/reviewers/$script:UserA\?"
    }
    It 'fails with a clear message when authenticatedUser.id is missing' {
        $script:AdoSession = New-Sess
        Mock Invoke-RestMethod { [pscustomobject]@{ authenticatedUser = $null } }
        { Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false } | Should -Throw '*authenticated user id*'
    }
    It 'connectionData 401 propagates as 401 and no vote is sent' {
        $script:AdoSession = New-Sess
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; throw (New-HttpError 401) }
        { Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false } | Should -Throw '*401*'
        $script:n | Should -Be 1
    }
}

Describe 'V38 Read session, -WhatIf, ConfirmImpact' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Fake $Method $Uri $Body $Headers }
        Mock Invoke-WebRequest { $script:Calls.Add([pscustomobject]@{ Method = 'GET'; Uri = "$Uri"; Body = $null; Auth = '' }); [pscustomobject]@{ Content = '{"value":[]}'; Headers = @{} } }
        Mock Write-Host { }
    }

    It 'enumerates the PR write functions (>= 16)' { $PrWriteCases.Count | Should -BeGreaterOrEqual 16 } -ForEach @(@{ PrWriteCases = $PrWriteCases })

    It '<Name> is refused on a Read session and sends no write' -ForEach $PrWriteCases {
        $script:AdoSession = New-Sess -Access Read
        $a = Get-DummyArgs $Name
        { & $Name @a } | Should -Throw -ErrorId 'AdoReadOnlySession'
        (Writes).Count | Should -Be 0
    }

    It '<Name> -WhatIf sends no write' -ForEach $PrWriteCases {
        $script:AdoSession = New-Sess
        $a = Get-DummyArgs $Name; $a.Remove('Confirm'); $a['WhatIf'] = $true
        & $Name @a | Out-Null
        (Writes).Count | Should -Be 0
    }

    It '<Name> -WhatIf sends no request at all (not even a read)' -ForEach $PrWriteCases {
        $script:AdoSession = New-Sess
        $a = Get-DummyArgs $Name; $a.Remove('Confirm'); $a['WhatIf'] = $true
        & $Name @a | Out-Null
        $script:Calls.Count | Should -Be 0
    }

    It 'ConfirmImpact is High on <_>' -ForEach 'Complete-AdoPullRequest', 'Stop-AdoPullRequest' {
        $attr = (Get-Command $_).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        "$($attr.ConfirmImpact)" | Should -Be 'High'
    }

    It 'reads work on a Read session: <_>' -ForEach 'Get-AdoPullRequests', 'Get-AdoPullRequest', 'Get-AdoPullRequestReviewers',
        'Get-AdoPullRequestThreads', 'Get-AdoPullRequestIterations', 'Get-AdoPullRequestChanges', 'Get-AdoPullRequestCommits',
        'Get-AdoPullRequestWorkItems', 'Get-AdoPullRequestLabels', 'Get-AdoPullRequestStatuses', 'Get-AdoCurrentUserId' {
        $script:AdoSession = New-Sess -Access Read
        $a = @{}
        $cmd = Get-Command $_
        if ($cmd.Parameters.ContainsKey('RepoId')) { $a.RepoId = 'MyRepo' }
        if ($cmd.Parameters.ContainsKey('PullRequestId')) { $a.PullRequestId = 42 }
        if ($_ -eq 'Get-AdoPullRequestChanges') { $a.IterationId = 1 }
        { & $_ @a | Out-Null } | Should -Not -Throw
    }
}

Describe 'V38 error propagation and secrets' {
    BeforeEach { Mock Write-Host { }; Mock Start-Sleep { }; $script:AdoSession = New-Sess }

    It 'Complete 409 -> AdoPullRequestConflict with server message, not retried' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; throw (New-HttpError 409 '{"message":"TF401192: merge conflicts"}') }
        $e = $null
        try { Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'abc' -Confirm:$false } catch { $e = $_ }
        $e.FullyQualifiedErrorId | Should -Match 'AdoPullRequestConflict'
        "$e" | Should -Match 'TF401192'
        $script:n | Should -Be 1
    }

    It 'Complete <S> propagates (not wrapped as conflict) and is not retried' -ForEach @(@{ S = 401 }, @{ S = 403 }, @{ S = 404 }) {
        $script:n = 0; $script:St = $S
        Mock Invoke-RestMethod { $script:n++; throw (New-HttpError $script:St) }
        $e = $null
        try { Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'abc' -Confirm:$false } catch { $e = $_ }
        "$e" | Should -Match "$S"
        $e.FullyQualifiedErrorId | Should -Not -Match 'AdoPullRequestConflict'
        $script:n | Should -Be 1
    }

    It '409 on another write (<_>) propagates with status 409, not retried' -ForEach 'Add-AdoPullRequestLabel', 'Add-AdoPullRequestReviewer' {
        $script:n = 0
        Mock Invoke-RestMethod { $script:n++; throw (New-HttpError 409) }
        $a = Get-DummyArgs $_
        $e = $null; try { & $_ @a } catch { $e = $_ }
        "$e" | Should -Not -Match 'Failed after'
        $script:n | Should -Be 1
    }

    It 'no credential value appears in errors, warnings or verbose output (409, 401, connectionData failure)' {
        $script:AdoSession = New-Sess -Auth "Basic $script:Secret"
        Mock Invoke-RestMethod { throw (New-HttpError 409 '{"message":"conflict"}') }
        $o1 = & { $VerbosePreference = 'Continue'; try { Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'a' -Confirm:$false -Verbose } catch { "E: $_"; $_ | Out-String } } *>&1 | Out-String
        Mock Invoke-RestMethod { [pscustomobject]@{} }
        $o2 = & { try { Approve-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -Confirm:$false } catch { "E: $_"; $_ | Out-String } } *>&1 | Out-String
        Mock Invoke-RestMethod { throw (New-HttpError 401) }
        $o3 = & { try { Get-AdoPullRequests -RepoId MyRepo } catch { "E: $_"; $_ | Out-String } } *>&1 | Out-String
        "$o1$o2$o3" | Should -Match 'E:'
        "$o1$o2$o3" | Should -Not -Match $script:Secret
    }
}

Describe 'V38 real 5.1 409 shape' -Tag 'Integration' {
    It 'Complete against a local listener returning 409 throws AdoPullRequestConflict with the server message' {
        $port = Get-Random -Minimum 40001 -Maximum 50000
        $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add("http://127.0.0.1:$port/"); $l.Start()
        $st = [hashtable]::Synchronized(@{ Count = 0 })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($l, $st) while ($l.IsListening) { try { $c = $l.GetContext() } catch { break }
            $st.Count++; $c.Response.StatusCode = 409; $c.Response.ContentType = 'application/json'
            $b = [Text.Encoding]::UTF8.GetBytes('{"message":"TF401181: The pull request cannot be completed"}')
            $c.Response.ContentLength64 = $b.Length; $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close() } }).AddArgument($l).AddArgument($st)
        $h = $ps.BeginInvoke()
        try {
            $script:AdoSession = [pscustomobject]@{ Org = 'o'; Project = 'p'; ApiV = '7.1'; BaseUrl = "http://127.0.0.1:$port"; Access = 'Write'; Headers = @{ Authorization = 'Basic eA==' } }
            Mock Write-Host { }
            $e = $null
            try { Complete-AdoPullRequest -RepoId MyRepo -PullRequestId 42 -LastMergeSourceCommitId 'abc' -Confirm:$false } catch { $e = $_ }
            $e.FullyQualifiedErrorId | Should -Match 'AdoPullRequestConflict'
            "$e" | Should -Match 'TF401181'
            $st.Count | Should -Be 1
        } finally { $l.Stop(); $l.Close(); try { [void]$ps.EndInvoke($h) } catch { }; $ps.Dispose(); $script:AdoSession = $null }
    }
}
