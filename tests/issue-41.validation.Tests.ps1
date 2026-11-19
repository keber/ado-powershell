#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Independent validation of PR #43 (issue #41: escape the project name in request URLs).
# Mocked HTTP; the tests that use a local HttpListener (127.0.0.1) are tagged Integration.
# Every URL is recorded as the raw string the code produced ([Uri].ToString() unescapes %XX).

BeforeDiscovery {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    # Not request builders, or pure string helpers covered separately.
    $notUrlBuilders = 'Initialize-AdoSession', 'Resolve-AdoConfig', 'Get-AdoProjectUrl', 'Get-AdoPullRequestRepoUri', 'Get-AdoPullRequestUri'
    $ProjectFunctionCases = @(
        foreach ($f in Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                Where-Object { $_.Body.ParamBlock -and @($_.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Project' }).Count -gt 0 } |
                Where-Object { $_.Name -notin $notUrlBuilders } |
                ForEach-Object { @{ Name = $_.Name; Script = $f.Name } }
        }
    )
}

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1') { . $f.FullName }

    $script:Base = 'https://dev.azure.com/o'
    function script:New-Sess([string]$Access = 'Write', [string]$Project = 'p', [string]$BaseUrl = 'https://dev.azure.com/o') {
        [pscustomobject]@{ Org = 'o'; Project = $Project; ApiV = '7.1'; BaseUrl = $BaseUrl
                           Access = $Access; AuthScheme = 'Basic'; Headers = @{ Authorization = 'Basic eA==' } }
    }
    function script:Raw($Uri) { if ($Uri -is [uri]) { $Uri.OriginalString } else { [string]$Uri } }
    function script:Record($Method, $Uri) { $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = (Raw $Uri) }) }

    $script:Unicode = "$([char]0xDC)n$([char]0xEF)c$([char]0xF6)d$([char]0xE9)"   # Unicode project name
    $script:ProjectNames = @('QA #1', 'R&D?', '100% done', 'Proj/Sub', $script:Unicode, ' lead and trail ')

    function script:Set-HttpMocks {
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Invoke-RestMethod {
            Record $Method $Uri
            [pscustomobject]@{ id = 1; name = 'n'; state = 'inProgress'; value = @([pscustomobject]@{ id = 1 }); workItems = @(); count = 0
                               authenticatedUser = [pscustomobject]@{ id = 'u1' }; fields = [pscustomobject]@{}
                               lastMergeSourceCommit = [pscustomobject]@{ commitId = 'abc' }
                               url = 'https://dev.azure.com/o/_apis/wit/attachments/x' }
        }
        Mock Invoke-WebRequest {
            Record $Method $Uri
            [pscustomobject]@{ Headers = @{}; RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"value":[{"id":1}]}'))
                               Content = '{"value":[{"id":1}]}' }
        }
    }

    # Minimal arguments for the mandatory parameters of the default parameter set.
    function script:Get-MinimalArgs([string]$Name, [string]$Project, [string]$TempFile) {
        $cmd = Get-Command $Name
        $set = @($cmd.ParameterSets | Where-Object IsDefault)
        if ($set.Count -eq 0) { $set = @($cmd.ParameterSets)[0] } else { $set = $set[0] }
        $a = @{ Project = $Project }
        foreach ($p in $set.Parameters) {
            if (-not $p.IsMandatory -or $a.ContainsKey($p.Name)) { continue }
            $vs = @($cmd.Parameters[$p.Name].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
            $v = if ($vs.Count -gt 0) { $vs[0].ValidValues[0] }
                 else {
                    switch ($p.ParameterType.Name) {
                        'Int32'     { 7 }
                        'Int32[]'   { , @(7) }
                        'String[]'  { , @('x') }
                        'Hashtable' { @{ a = 1 } }
                        'Hashtable[]' { , @(@{ outcome = 'Passed'; testCaseId = 1 }) }
                        'Object[]'  { , @(@{ outcome = 'Passed'; testCaseId = 1 }) }
                        'SwitchParameter' { $true }
                        default     { 'x' }
                    }
                 }
            if ($p.Name -eq 'FilePath') { $v = $TempFile }
            $a[$p.Name] = $v
        }
        # A few functions refuse to send anything without one optional argument.
        switch ($Name) {
            'Update-AdoWorkItem'      { $a.Title = 't' }
            'Set-AdoPullRequest'      { $a.Title = 't' }
            'Complete-AdoPullRequest' { $a.LastMergeSourceCommitId = 'abc' }
        }
        if ($cmd.Parameters.ContainsKey('Confirm')) { $a.Confirm = $false }
        return $a
    }

    # The scanner from tests/issue-41.Tests.ps1, copied verbatim, to probe its precision.
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

Describe 'V41: every function with -Project sends the project escaped exactly once (enumerated from source)' {
    BeforeAll { $script:TempFile = (New-TemporaryFile).FullName }
    AfterAll  { Remove-Item -LiteralPath $script:TempFile -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        Set-HttpMocks
    }

    It '<Name> (<Script>) escapes every tricky project name once' -TestCases $ProjectFunctionCases {
        param($Name, $Script)
        foreach ($proj in $script:ProjectNames) {
            $script:Calls.Clear()
            $a = Get-MinimalArgs -Name $Name -Project $proj -TempFile $script:TempFile
            try { & $Name @a *> $null } catch { }   # a failure after the request is irrelevant here
            $script:Calls.Count | Should -BeGreaterThan 0 -Because "$Name must send at least one request for project '$proj'"
            $enc = [Uri]::EscapeDataString($proj)
            foreach ($c in $script:Calls) {
                if ($c.Uri -like "$script:Base/_apis/*") { continue }   # org-level helper call (connectionData)
                $c.Uri | Should -BeLike "$script:Base/$enc/_apis/*" -Because "$Name, project '$proj'"
                $c.Uri | Should -Not -BeLike '*%2525*' -Because 'no double escaping'
                ($c.Uri -split '\?', 2)[0] | Should -Not -Match '[ #]' -Because 'no raw space or # before the query'
            }
        }
    }
}

Describe 'V41: fallback, paging and reused URLs keep a single escape' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess -Project 'R&D?'
        Set-HttpMocks
    }

    It 'Get-AdoTestSuites: all 4 fallback URL shapes carry the escaped project' {
        Mock Invoke-AdoGet { Record GET $Uri; throw '404 Not Found - resource not found: x' }
        { Get-AdoTestSuites -PlanId 3 } | Should -Throw '*404*'
        $script:Calls.Count | Should -Be 4
        $script:Calls | ForEach-Object { $_.Uri | Should -BeLike "$script:Base/R%26D%3F/_apis/test*/Plans/3/Suites?api-version=*" }
    }

    It 'Get-AdoTestCases: all 5 fallback URL shapes carry the escaped project' {
        Mock Invoke-AdoGet { Record GET $Uri; throw '404 Not Found - resource not found: x' }
        { Get-AdoTestCases -PlanId 3 -SuiteId 4 } | Should -Throw '*404*'
        $script:Calls.Count | Should -Be 5
        $script:Calls | ForEach-Object { $_.Uri | Should -BeLike "$script:Base/R%26D%3F/_apis/test*" }
    }

    It 'Invoke-AdoGetPaged continuation request reuses the escaped first-page URL verbatim' {
        $script:Page = 0
        Mock Invoke-WebRequest {
            Record GET $Uri
            $script:Page++
            $json = if ($script:Page -eq 1) { '{"value":[{"id":1}],"continuationToken":"a b&c"}' } else { '{"value":[{"id":2}]}' }
            [pscustomobject]@{ Headers = @{}; RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json)); Content = $json }
        }
        $items = @(Get-AdoPipelines -Project '100% done')
        $items.Count | Should -Be 2
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/100%25%20done/_apis/pipelines?api-version=7.1"
        $script:Calls[1].Uri | Should -BeExactly "$script:Base/100%25%20done/_apis/pipelines?api-version=7.1&continuationToken=a%20b%26c"
    }

    It 'Get-AdoPullRequests skip paging keeps the escaped project and repository on page 2' {
        $script:Page = 0
        Mock Invoke-RestMethod {
            Record GET $Uri
            $script:Page++
            if ($script:Page -eq 1) { [pscustomobject]@{ value = @([pscustomobject]@{ pullRequestId = 1 }, [pscustomobject]@{ pullRequestId = 2 }) } }
            else { [pscustomobject]@{ value = @() } }
        }
        Get-AdoPullRequests -RepoId 'My Repo#1' -PageSize 2 | Out-Null
        $script:Calls.Count | Should -BeGreaterOrEqual 2
        $script:Calls | ForEach-Object { $_.Uri | Should -BeLike "$script:Base/R%26D%3F/_apis/git/repositories/My%20Repo%231/pullrequests?*" }
    }
}

Describe 'V41: other free-text segments and query values' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess -Project 'QA #1'
        Set-HttpMocks
    }

    It 'PR label name is escaped exactly once on top of the escaped project' {
        Remove-AdoPullRequestLabel -RepoId 'My Repo' -PullRequestId 4 -Name 'a b#?%' -Confirm:$false | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/QA%20%231/_apis/git/repositories/My%20Repo/pullrequests/4/labels/a%20b%23%3F%25?api-version=7.1"
    }

    It 'PR reviewer id is escaped exactly once' {
        Remove-AdoPullRequestReviewer -RepoId 'r' -PullRequestId 4 -ReviewerId 'a b' -Confirm:$false | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/QA%20%231/_apis/git/repositories/r/pullrequests/4/reviewers/a%20b?api-version=7.1"
    }

    It 'branch filters are escaped as query values' {
        Get-AdoPullRequests -RepoId 'r' -SourceBranch 'feature/a&b #1' -Top 1 | Out-Null
        $script:Calls[0].Uri | Should -BeLike "*searchCriteria.sourceRefName=refs%2Fheads%2Ffeature%2Fa%26b%20%231&*"
    }

    It 'work item type keeps the literal $ prefix and escapes the name once' {
        New-AdoWorkItem -Type 'User Story #2' -Title 't' -Confirm:$false | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/QA%20%231/_apis/wit/workitems/`$User%20Story%20%232?api-version=7.1"
    }

    It 'work item type in Get-AdoWorkItemTypeFields is escaped once' {
        $script:AdoWorkItemTypeFieldCache = @{}
        Get-AdoWorkItemTypeFields -Type 'Test Case' | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/QA%20%231/_apis/wit/workitemtypes/Test%20Case/fields?api-version=7.1"
    }

    It 'attachment file name is escaped as a query value' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "v41-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 'r&d #1.txt'
        Set-Content -LiteralPath $file -Value 'x'
        try { Add-AdoWorkItemAttachment -Id 7 -FilePath $file -Confirm:$false | Out-Null }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/QA%20%231/_apis/wit/attachments?fileName=r%26d%20%231.txt&api-version=7.1"
    }

    It 'team segment in Get-AdoIterations is escaped once ("Proj/Sub"-style team)' {
        Get-AdoIterations -Team 'A/B 100%' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:Base/QA%20%231/A%2FB%20100%25/_apis/work/teamsettings/iterations?*"
    }

    It 'V41-003 Get-AdoIterations -TimeFrame is escaped as a query value' {
        Get-AdoIterations -TimeFrame 'current&x=1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike '*$timeframe=current%26x%3D1'
    }

    It 'V41-003 Get-AdoWorkItem -Expand is escaped as a query value' {
        Get-AdoWorkItem -Id 7 -Expand 'All&x=1' | Out-Null
        $script:Calls[0].Uri | Should -BeLike '*$expand=All%26x%3D1&api-version=7.1'
    }
}

Describe 'V41: dot segments in project/repository' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        Set-HttpMocks
    }

    It 'V41-002 project ".." does not climb out of the organization after URI normalisation' {
        Get-AdoRepositories -Project '..' | Out-Null
        ([uri]$script:Calls[0].Uri).AbsolutePath | Should -BeLike '/o/*/_apis/*'
    }

    It 'V41-002 repository ".." does not replace the repository route' {
        Get-AdoPullRequestReviewers -RepoId '..' -PullRequestId 4 | Out-Null
        ([uri]$script:Calls[0].Uri).AbsolutePath | Should -BeLike '/o/p/_apis/git/repositories/*/pullrequests/4/reviewers'
    }
}

Describe 'V41: org-level APIs and empty project' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Set-HttpMocks
    }

    It 'Get-AdoProjects works with an empty session project (org level)' {
        $script:AdoSession = New-Sess -Project ''
        { Get-AdoProjects | Out-Null } | Should -Not -Throw
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/_apis/projects?api-version=7.1"
    }

    It 'Get-AdoCurrentUserId (connectionData) works with an empty session project' {
        $script:AdoSession = New-Sess -Project ''
        Get-AdoCurrentUserId -Force | Should -Be 'u1'
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/_apis/connectionData"
    }

    It 'Get-AdoTeams escapes the project in the org-level projects route' {
        $script:AdoSession = New-Sess -Project 'R&D?'
        Get-AdoTeams | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/_apis/projects/R%26D%3F/teams?api-version=7.1"
    }

    It 'V41-004 Get-AdoTeams with an empty project does not send "projects//teams"' {
        $script:AdoSession = New-Sess -Project ''
        try { Get-AdoTeams | Out-Null } catch { }
        @($script:Calls | Where-Object { $_.Uri -like '*/projects//teams*' }).Count | Should -Be 0
    }

    It 'a project-scoped function with an empty project throws before sending' {
        $script:AdoSession = New-Sess -Project ''
        { Get-AdoRepositories } | Should -Throw '*project*'
        $script:Calls.Count | Should -Be 0
    }

    It 'a whitespace-only project throws before sending' {
        $script:AdoSession = New-Sess
        { Get-AdoWorkItem -Id 1 -Project '   ' } | Should -Throw '*project*'
        $script:Calls.Count | Should -Be 0
    }

    It 'a project id (GUID) is unchanged' {
        $script:AdoSession = New-Sess
        $g = '0fa1e2b3-0000-4000-8000-000000000001'
        Get-AdoRepositories -Project $g | Out-Null
        $script:Calls[0].Uri | Should -BeExactly "$script:Base/$g/_apis/git/repositories?api-version=7.1"
    }

    It 'a custom ADO Server BaseUrl is kept and only the project is escaped' {
        $script:AdoSession = New-Sess -Project 'QA #1' -BaseUrl 'https://ado.contoso.local/tfs/Coll'
        Get-AdoRepositories | Out-Null
        $script:Calls[0].Uri | Should -BeExactly 'https://ado.contoso.local/tfs/Coll/QA%20%231/_apis/git/repositories?api-version=7.1'
    }
}

Describe 'V41: write guards with escaped project across scripts' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Set-HttpMocks
    }

    It 'Read session refuses <Name> and sends nothing' -TestCases @(
        @{ Name = 'New-AdoWorkItem';            FnArgs = @{ Type = 'Bug'; Title = 't' } }
        @{ Name = 'New-AdoTestRun';             FnArgs = @{ Name = 'r'; PlanId = 1 } }
        @{ Name = 'Invoke-AdoPipelineRun';      FnArgs = @{ PipelineId = 1 } }
        @{ Name = 'Remove-AdoPullRequestLabel'; FnArgs = @{ RepoId = 'r'; PullRequestId = 1; Name = 'l' } }
    ) {
        param($Name, $FnArgs)
        $script:AdoSession = New-Sess -Access 'Read' -Project 'R&D?'
        { & $Name @FnArgs -Confirm:$false } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }

    It '-WhatIf on <Name> sends nothing' -TestCases @(
        @{ Name = 'New-AdoWorkItem';            FnArgs = @{ Type = 'Bug'; Title = 't' } }
        @{ Name = 'New-AdoTestRun';             FnArgs = @{ Name = 'r'; PlanId = 1 } }
        @{ Name = 'Invoke-AdoPipelineRun';      FnArgs = @{ PipelineId = 1 } }
        @{ Name = 'Remove-AdoPullRequestLabel'; FnArgs = @{ RepoId = 'r'; PullRequestId = 1; Name = 'l' } }
    ) {
        param($Name, $FnArgs)
        $script:AdoSession = New-Sess -Project 'R&D?'
        & $Name @FnArgs -WhatIf *> $null
        $script:Calls.Count | Should -Be 0
    }

    It 'Read session still allows the read-only WIQL POST with an escaped project' {
        $script:AdoSession = New-Sess -Access 'Read' -Project 'R&D?'
        Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' | Out-Null
        $script:Calls[0].Uri | Should -BeLike "$script:Base/R%26D%3F/_apis/wit/wiql?*"
    }
}

Describe 'V41-001: source scan precision (scanner copied from issue-41.Tests.ps1)' {
    It 'flags <Label>' -TestCases @(
        @{ Label = 'the original pre-fix team segment "/$Team"';               Src = '$teamSeg = if ($Team) { "/$Team" } else { "" }' }
        @{ Label = 'a project segment built without a URL marker';             Src = '$root = Get-AdoBaseUrl $Org; $u = "$root/$Project"' }
        @{ Label = 'string formatting with -f';                                Src = '$u = "{0}/{1}/_apis/x" -f (Get-AdoBaseUrl $Org), $Project' }
        @{ Label = 'concatenation with +';                                     Src = '$u = (Get-AdoBaseUrl $Org) + "/" + $Project + "/_apis/x"' }
        @{ Label = 'a method call on the project ($Project.Trim())';           Src = '$u = "$(Get-AdoBaseUrl $Org)/$($Project.Trim())/_apis/x"' }
        @{ Label = 'an index into the session ($AdoSession[''Project''])';    Src = '$u = "$(Get-AdoBaseUrl $Org)/$($AdoSession[''Project''])/_apis/x"' }
        @{ Label = 'a differently named variable ($proj)';                     Src = '$proj = $Project; $u = "$(Get-AdoBaseUrl $Org)/$proj/_apis/x"' }
    ) {
        param($Label, $Src)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Src, [ref]$null, [ref]$null)
        @(Find-RawUrlInterpolation $ast).Count | Should -BeGreaterThan 0 -Because "the scan should catch $Label"
    }
}

Describe 'V41: on-the-wire request line (local HttpListener)' -Tag 'Integration' {
    It 'project <Project> reaches the server as <Expected>' -TestCases @(
        @{ Project = 'QA #1';     Expected = '/o/QA%20%231/_apis/git/repositories?api-version=7.1' }
        @{ Project = 'R&D?';      Expected = '/o/R%26D%3F/_apis/git/repositories?api-version=7.1' }
        @{ Project = '100% done'; Expected = '/o/100%25%20done/_apis/git/repositories?api-version=7.1' }
        @{ Project = 'Proj/Sub';  Expected = '/o/Proj%2FSub/_apis/git/repositories?api-version=7.1' }
        @{ Project = 'UNICODE';   Expected = '/o/%C3%9Cn%C3%AFc%C3%B6d%C3%A9/_apis/git/repositories?api-version=7.1' }
    ) {
        param($Project, $Expected)
        if ($Project -eq 'UNICODE') { $Project = $script:Unicode }
        $port = Get-Random -Minimum 20000 -Maximum 40000
        $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add("http://127.0.0.1:$port/"); $l.Start()
        $st = [hashtable]::Synchronized(@{ Raw = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($l, $st) while ($l.IsListening) { try { $c = $l.GetContext() } catch { break }
            [void]$st.Raw.Add($c.Request.RawUrl); $c.Response.StatusCode = 200; $c.Response.ContentType = 'application/json'
            $b = [Text.Encoding]::UTF8.GetBytes('{"value":[]}'); $c.Response.ContentLength64 = $b.Length
            $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close() } }).AddArgument($l).AddArgument($st)
        $h = $ps.BeginInvoke()
        try {
            $script:AdoSession = New-Sess -Project 'p' -BaseUrl "http://127.0.0.1:$port/o"
            Get-AdoRepositories -Project $Project | Out-Null
            @($st.Raw)[0] | Should -BeExactly $Expected
        } finally { $l.Stop(); $l.Close(); try { [void]$ps.EndInvoke($h) } catch { }; $ps.Dispose(); $script:AdoSession = $null }
    }
}
