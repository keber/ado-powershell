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

Describe 'Source scan: no raw project/team interpolation into a URL' {
    # Flags an expandable string that interpolates $Project / $Team / $AdoSession.Project directly
    # (as "$Project" or "$($x.Project)") AND looks like a URL ("_apis", "://" or Get-AdoBaseUrl).
    # Non-URL strings such as cache keys ("$Org/$Project/$Type") are not flagged.
    BeforeAll {
        function script:Test-RawSegment($e) {
            if ($e -is [System.Management.Automation.Language.VariableExpressionAst]) {
                return (($e.VariablePath.UserPath -replace '^(script|global|local):', '') -in @('Project', 'Team'))
            }
            if ($e -is [System.Management.Automation.Language.MemberExpressionAst]) {
                return ($e.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $e.Member.Value -eq 'Project')
            }
            if ($e -is [System.Management.Automation.Language.SubExpressionAst]) {
                $stmts = @($e.SubExpression.Statements)
                if ($stmts.Count -eq 1 -and $stmts[0] -is [System.Management.Automation.Language.PipelineAst]) {
                    $els = @($stmts[0].PipelineElements)
                    if ($els.Count -eq 1 -and $els[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                        return (Test-RawSegment $els[0].Expression)
                    }
                }
            }
            return $false
        }
        function script:Find-RawUrlInterpolation($Ast) {
            @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) |
                Where-Object { $_.Value -match '_apis|://|Get-AdoBaseUrl' } |
                Where-Object { @($_.NestedExpressions | Where-Object { Test-RawSegment $_ }).Count -gt 0 } |
                ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" })
        }
    }

    It '<Name> builds every project/team URL segment through an escaping helper' -TestCases $ScriptCases {
        param($Name, $Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        Find-RawUrlInterpolation $ast | Should -BeNullOrEmpty
    }

    It 'the scan flags raw interpolations and ignores escaped segments and non-URL strings (self-check)' {
        $src = @'
function X { param($Org, $Project, $Team)
  $a = "$(Get-AdoBaseUrl $Org)/$Project/_apis/x"
  $b = "https://h/$($script:AdoSession.Project)/_apis/y"
  $c = "$(Get-AdoBaseUrl $Org)/x$teamSeg/$Team/_apis/z"
  $d = "$Org/$Project/cache-key"
  $e = "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/ok"
  $f = "$(Get-AdoBaseUrl $Org)/_apis/projects/$([Uri]::EscapeDataString($Project))/teams"
}
'@
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $hits = @(Find-RawUrlInterpolation $ast)
        $hits.Count | Should -Be 3
        $hits[0] | Should -BeLike 'line 2:*'
        $hits[1] | Should -BeLike 'line 3:*'
        $hits[2] | Should -BeLike 'line 4:*'
    }
}
