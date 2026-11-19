#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #41: the project name (and the team name in Get-AdoIterations) must be
# escaped as a URL path segment, so names containing '#', '?', '%', '&' or spaces build correct
# request URLs. Mocked HTTP only; no network access.

BeforeDiscovery {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    $ScriptCases = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base.ps1', 'ado-workitems.ps1', 'ado-testing.ps1', 'ado-pipelines.ps1', 'ado-git.ps1', 'ado-pullrequests.ps1') {
        . (Join-Path $script:ScriptsDir $f)
    }

    function script:New-Sess([string]$Access = 'Write', [string]$Project = 'fakeproj', [string]$BaseUrl = 'https://dev.azure.com/fakeorg') {
        [pscustomobject]@{ Org = 'fakeorg'; Project = $Project; ApiV = '7.1'; BaseUrl = $BaseUrl
                           Access = $Access; AuthScheme = 'Basic'; Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
    }

    # Records the raw URI string the code passed (OriginalString: [Uri].ToString() unescapes %XX).
    function script:Record($Method, $Uri) {
        $u = if ($Uri -is [uri]) { $Uri.OriginalString } else { [string]$Uri }
        $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = $u })
    }

    $script:QaBase = 'https://dev.azure.com/fakeorg/QA%20%231'
    $script:RdBase = 'https://dev.azure.com/fakeorg/R%26D%3F'
}

Describe 'Get-AdoProjectUrl' {
    BeforeEach { $script:AdoSession = New-Sess }

    It 'escapes <Project> as a single path segment' -TestCases @(
        @{ Project = 'QA #1';    Expected = 'https://dev.azure.com/fakeorg/QA%20%231' }
        @{ Project = 'R&D?';     Expected = 'https://dev.azure.com/fakeorg/R%26D%3F' }
        @{ Project = '100% done'; Expected = 'https://dev.azure.com/fakeorg/100%25%20done' }
        @{ Project = 'fakeproj'; Expected = 'https://dev.azure.com/fakeorg/fakeproj' }
    ) {
        Get-AdoProjectUrl -Project $Project | Should -BeExactly $Expected
    }

    It 'defaults to the session project and honours a custom session BaseUrl' {
        $script:AdoSession = New-Sess -Project 'QA #1' -BaseUrl 'https://ado.contoso.local/tfs/Coll'
        Get-AdoProjectUrl | Should -BeExactly 'https://ado.contoso.local/tfs/Coll/QA%20%231'
    }

    It 'uses dev.azure.com for an org other than the session org' {
        Get-AdoProjectUrl -Org 'otherorg' -Project 'R&D?' | Should -BeExactly 'https://dev.azure.com/otherorg/R%26D%3F'
    }

    It 'throws on an empty project instead of building a "//_apis" URL' {
        { Get-AdoProjectUrl -Project '' } | Should -Throw '*project*'
    }
}

Describe 'Escaped project in request URLs (one function per script)' {
    BeforeEach {
        Mock Write-Host { }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        Mock Invoke-RestMethod { Record $Method $Uri; [pscustomobject]@{ id = 1; value = @([pscustomobject]@{ id = 1 }) } }
        Mock Invoke-WebRequest {
            Record $Method $Uri
            [pscustomobject]@{ Headers = @{}; RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"value":[{"id":1}]}'))
                               Content = '{"value":[{"id":1}]}' }
        }
    }

    It 'ado-workitems: Get-AdoWorkItem with project "QA #1"' {
        Get-AdoWorkItem -Id 7 -Project 'QA #1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/wit/workitems/7?*"
    }

    It 'ado-workitems: Get-AdoTeams escapes the project in _apis/projects/{project}/teams' {
        Get-AdoTeams -Project 'R&D?' | Out-Null
        $script:Calls[0].Uri | Should -BeLike 'https://dev.azure.com/fakeorg/_apis/projects/R%26D%3F/teams?*'
    }

    It 'ado-workitems: Update-AdoWorkItem (write) with project "R&D?"' {
        Update-AdoWorkItem -Id 7 -Title 'x' -Project 'R&D?' -Confirm:$false | Out-Null
        $script:Calls[0].Method | Should -Be 'PATCH'
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/wit/workitems/7?api-version=*"
    }

    It 'ado-workitems: the session project is escaped when -Project is not passed' {
        $script:AdoSession = New-Sess -Project 'QA #1'
        Get-AdoWorkItem -Id 7 | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/wit/workitems/7?*"
    }

    It 'ado-testing: Get-AdoTestPlans with project "QA #1"' {
        Get-AdoTestPlans -Project 'QA #1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/testplan/plans?*"
    }

    It 'ado-testing: Get-AdoTestSuites with project "R&D?" (fallback base URL)' {
        Get-AdoTestSuites -PlanId 3 -Project 'R&D?' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/test/plans/3/suites?*"
    }

    It 'ado-pipelines: Get-AdoPipelines with project "R&D?"' {
        Get-AdoPipelines -Project 'R&D?' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/pipelines?*"
    }

    It 'ado-git: Get-AdoRepositories with project "QA #1"' {
        Get-AdoRepositories -Project 'QA #1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/git/repositories?*"
    }

    It 'ado-git: Get-AdoIterations escapes both the project and the team segment' {
        Get-AdoIterations -Project 'QA #1' -Team 'Team A&B #2' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/Team%20A%26B%20%232/_apis/work/teamsettings/iterations?*"
    }

    It 'ado-git: Get-AdoIterations without a team keeps the project-level route' {
        Get-AdoIterations -Project 'R&D?' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/work/teamsettings/iterations?*"
    }

    It 'ado-git: Get-AdoBranches escapes a repository name passed as -RepoId' {
        Get-AdoBranches -RepoId 'My Repo#1' -Project 'QA #1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/git/repositories/My%20Repo%231/refs?*"
    }

    It 'ado-workitems: New-AdoWorkItem escapes the project and the work item type' {
        New-AdoWorkItem -Type 'User Story' -Title 'x' -Project 'R&D?' -Confirm:$false | Out-Null
        $script:Calls[0].Method | Should -Be 'POST'
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/wit/workitems/`$User%20Story?api-version=*"
    }

    It 'ado-pullrequests: Get-AdoPullRequestReviewers with project "QA #1"' {
        Get-AdoPullRequestReviewers -RepoId MyRepo -PullRequestId 42 -Project 'QA #1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:QaBase/_apis/git/repositories/MyRepo/pullrequests/42/reviewers?*"
    }

    It 'ado-pullrequests: Get-AdoPullRequest project-level route with project "R&D?"' {
        Get-AdoPullRequest -PullRequestId 42 -Project 'R&D?' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:RdBase/_apis/git/pullrequests/42?*"
    }

    It 'a plain project name is unchanged' {
        Get-AdoWorkItem -Id 7 -Project 'fakeproj' | Out-Null
        $script:Calls[0].Uri | Should -BeLike 'https://dev.azure.com/fakeorg/fakeproj/_apis/wit/workitems/7?*'
    }
}

Describe 'Write guards still apply with an escaped project' {
    BeforeEach {
        Mock Write-Host { }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod { Record $Method $Uri; [pscustomobject]@{ id = 1 } }
    }

    It 'a Read session refuses the write and sends nothing' {
        $script:AdoSession = New-Sess -Access 'Read' -Project 'R&D?'
        { Update-AdoWorkItem -Id 7 -Title 'x' -Confirm:$false } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }

    It '-WhatIf sends nothing' {
        $script:AdoSession = New-Sess -Project 'R&D?'
        Update-AdoWorkItem -Id 7 -Title 'x' -WhatIf | Out-Null
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Source scan: no raw free-text value interpolated into a URL' {
    # Scanner shared with tests/issue-41.validation.Tests.ps1 (tests/helpers/UrlSegmentScan.ps1).
    BeforeAll { . (Join-Path $PSScriptRoot 'helpers\UrlSegmentScan.ps1') }

    It '<Name> builds every free-text URL segment through an escaping helper' -TestCases $ScriptCases {
        param($Name, $Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        Find-RawUrlInterpolation $ast | Should -BeNullOrEmpty
    }

    It 'flags <Label>' -TestCases @(
        @{ Label = 'a raw project in an _apis URL';        Src = '$a = "$(Get-AdoBaseUrl $Org)/$Project/_apis/x"' }
        @{ Label = 'a session project member';             Src = '$b = "https://h/$($script:AdoSession.Project)/_apis/y"' }
        @{ Label = 'a raw team segment without _apis';     Src = '$t = if ($Team) { "/$Team" } else { "" }' }
        @{ Label = 'a raw repository id';                  Src = '$r = "$base/repositories/$RepoId/refs"' }
        @{ Label = 'a raw work item type';                 Src = '$w = "$base/workitems/`$$Type"' }
        @{ Label = 'a raw label name';                     Src = '$l = "labels/$Name"' }
        @{ Label = 'a raw reviewer id';                    Src = '$v = "$pr/reviewers/$($ReviewerId)"' }
        @{ Label = 'a method call on the project';         Src = '$u = "$base/$($Project.Trim())/_apis/x"' }
        @{ Label = 'an index into the session';            Src = '$u = "$base/$($AdoSession[''Project''])/_apis/x"' }
        @{ Label = 'a cast of the project';                Src = '$u = "$base/$([string]$Project)/_apis/x"' }
        @{ Label = 'string formatting with -f';            Src = '$u = "{0}/{1}/_apis/x" -f (Get-AdoBaseUrl $Org), $Project' }
        @{ Label = 'single-argument -f';                   Src = '$u = ''x/{0}'' -f $Team' }
        @{ Label = 'concatenation with +';                 Src = '$u = (Get-AdoBaseUrl $Org) + "/" + $Project + "/_apis/x"' }
        @{ Label = 'an alias of the project';              Src = '$proj = $Project; $u = "$(Get-AdoBaseUrl $Org)/$proj/_apis/x"' }
        @{ Label = 'an alias of an alias';                 Src = '$p1 = $script:AdoSession.Project; $p2 = $p1; $u = "$base/$p2/x"' }
    ) {
        param($Label, $Src)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Src, [ref]$null, [ref]$null)
        @(Find-RawUrlInterpolation $ast).Count | Should -BeGreaterThan 0 -Because "the scan should catch $Label"
    }

    It 'does not flag <Label>' -TestCases @(
        @{ Label = 'the project URL helper';               Src = '$e = "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/ok"' }
        @{ Label = 'EscapeDataString on the project';      Src = '$f = "$(Get-AdoBaseUrl $Org)/_apis/projects/$([Uri]::EscapeDataString($Project))/teams"' }
        @{ Label = 'the path-segment helper';              Src = '$g = "$base/$(ConvertTo-AdoPathSegment -Value $Team -Name Team)/_apis"' }
        @{ Label = 'a non-URL message without /';          Src = '$m = "POST - Create ${Type}: ''$Title''"' }
        @{ Label = 'a cache key without /';                Src = '$k = "$Org|$Project|$Type"' }
        @{ Label = 'an escaped alias';                     Src = '$seg = [Uri]::EscapeDataString($Project); $u = "$base/$seg/_apis"' }
        @{ Label = 'an untracked variable';                Src = '$u = "$base/fields/$k"' }
        @{ Label = '-f without a raw value';               Src = '$u = "{0}/_apis/{1}" -f $base, $Id' }
        @{ Label = '+ with an escaped value';              Src = '$u = $base + "/" + [Uri]::EscapeDataString($Project)' }
    ) {
        param($Label, $Src)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Src, [ref]$null, [ref]$null)
        Find-RawUrlInterpolation $ast | Should -BeNullOrEmpty -Because "$Label is safe"
    }
}

Describe 'Dot segments, empty segments and query values (V41-002/003/004)' {
    BeforeEach {
        Mock Write-Host { }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        Mock Invoke-RestMethod { Record $Method $Uri; [pscustomobject]@{ id = 1; value = @() } }
        Mock Invoke-WebRequest {
            Record $Method $Uri
            [pscustomobject]@{ Headers = @{}; RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"value":[]}'))
                               Content = '{"value":[]}' }
        }
    }

    It 'ConvertTo-AdoPathSegment escapes a value once' {
        ConvertTo-AdoPathSegment -Value 'A/B #1?' -Name 'Team' | Should -BeExactly 'A%2FB%20%231%3F'
    }

    It 'ConvertTo-AdoPathSegment rejects "<Value>"' -TestCases @(
        @{ Value = '.' }, @{ Value = '..' }, @{ Value = ' .. ' }, @{ Value = '' }, @{ Value = '   ' }
    ) {
        param($Value)
        { ConvertTo-AdoPathSegment -Value $Value -Name 'Team' } | Should -Throw '*Team*'
    }

    It 'Get-AdoProjectUrl rejects the dot segment "<Value>"' -TestCases @(@{ Value = '.' }, @{ Value = '..' }, @{ Value = ' . ' }) {
        param($Value)
        { Get-AdoProjectUrl -Project $Value } | Should -Throw '*project*'
    }

    It 'a dot segment throws before any request (<Label>)' -TestCases @(
        @{ Label = 'project';    Call = { Get-AdoRepositories -Project '..' } }
        @{ Label = 'repository'; Call = { Get-AdoPullRequestReviewers -RepoId '..' -PullRequestId 4 } }
        @{ Label = 'branches';   Call = { Get-AdoBranches -RepoId '.' } }
        @{ Label = 'team';       Call = { Get-AdoIterations -Team '..' } }
        @{ Label = 'type';       Call = { New-AdoWorkItem -Type '..' -Title 't' -Confirm:$false } }
        @{ Label = 'label';      Call = { Remove-AdoPullRequestLabel -RepoId 'r' -PullRequestId 4 -Name '..' -Confirm:$false } }
        @{ Label = 'reviewer';   Call = { Remove-AdoPullRequestReviewer -RepoId 'r' -PullRequestId 4 -ReviewerId '..' -Confirm:$false } }
        @{ Label = 'teams';      Call = { Get-AdoTeams -Project '..' } }
    ) {
        param($Label, $Call)
        { & $Call } | Should -Throw '*dot segment*'
        $script:Calls.Count | Should -Be 0
    }

    It 'V41-004 Get-AdoTeams with an empty project throws and sends nothing' {
        $script:AdoSession = New-Sess -Project ''
        { Get-AdoTeams } | Should -Throw '*project*'
        $script:Calls.Count | Should -Be 0
    }

    It 'V41-003 Get-AdoIterations -TimeFrame accepts <Value>' -TestCases @(@{ Value = 'past' }, @{ Value = 'current' }, @{ Value = 'future' }) {
        param($Value)
        Get-AdoIterations -TimeFrame $Value | Out-Null
        $script:Calls[0].Uri | Should -BeLike "*&`$timeframe=$Value"
    }

    It 'V41-003 Get-AdoIterations -TimeFrame rejects a value outside past/current/future' {
        { Get-AdoIterations -TimeFrame 'current&x=1' } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }

    It 'V41-003 Get-AdoWorkItem -Expand accepts <Value>' -TestCases @(
        @{ Value = 'None' }, @{ Value = 'Relations' }, @{ Value = 'Fields' }, @{ Value = 'Links' }, @{ Value = 'All' }
    ) {
        param($Value)
        Get-AdoWorkItem -Id 7 -Expand $Value | Out-Null
        $script:Calls[0].Uri | Should -BeLike "*/_apis/wit/workitems/7?`$expand=$Value&api-version=7.1"
    }

    It 'V41-003 Get-AdoWorkItem -Expand rejects a value outside the WorkItemExpand enum' {
        { Get-AdoWorkItem -Id 7 -Expand 'All&x=1' } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }
}
