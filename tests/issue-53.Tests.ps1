#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #53: Azure DevOps only accepts the initial System.State when a work item
# is created, so New-AdoWorkItem / New-AdoTestCase -State must create first and then PATCH the state
# when it differs from the state the server assigned. Mocked HTTP only; no network access.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base.ps1', 'ado-workitems.ps1', 'ado-testing.ps1') {
        . (Join-Path $script:ScriptsDir $f)
    }

    function script:New-Sess([string]$Access = 'Write') {
        [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/fakeorg'
                           Access = $Access; AuthScheme = 'Basic'; Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
    }

    function script:Record($Method, $Uri, $Body) {
        $bodyText = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
        $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; Body = $bodyText })
    }
}

Describe 'Create with -State (issue #53)' {
    BeforeEach {
        Mock Write-Host { }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        $script:InitialState = 'Design'
        $script:FailPatch = $false
        Mock Invoke-RestMethod {
            Record $Method $Uri $Body
            if ($Method -eq 'POST') {
                return [pscustomobject]@{ id = 501; fields = [pscustomobject]@{ 'System.State' = $script:InitialState } }
            }
            if ($script:FailPatch) { throw 'simulated PATCH failure' }
            $newState = ($script:Calls[$script:Calls.Count - 1].Body | ConvertFrom-Json)[0].value
            return [pscustomobject]@{ id = 501; fields = [pscustomobject]@{ 'System.State' = $newState } }
        }
    }

    It 'makes a single POST without System.State when -State is not passed' {
        $r = New-AdoTestCase -Title 'tc' -Confirm:$false
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Method | Should -Be 'POST'
        $r.id | Should -Be 501
    }

    It 'makes a single POST when -State equals the initial state assigned by the server (case-insensitive)' {
        $r = New-AdoTestCase -Title 'tc' -State 'design' -Confirm:$false
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Method | Should -Be 'POST'
        $r.fields.'System.State' | Should -Be 'Design'
    }

    It 'never sends System.State on the create request' {
        New-AdoTestCase -Title 'tc' -State 'Ready' -Confirm:$false | Out-Null
        $script:Calls[0].Method | Should -Be 'POST'
        $script:Calls[0].Body | Should -Not -Match 'System\.State'
    }

    It 'creates and then PATCHes System.State when -State differs from the initial state' {
        $r = New-AdoTestCase -Title 'tc' -State 'Ready' -Confirm:$false
        $script:Calls.Count | Should -Be 2
        $script:Calls[1].Method | Should -Be 'PATCH'
        $script:Calls[1].Uri | Should -Match '/_apis/wit/workitems/501\?'
        $script:Calls[1].Body | Should -Match '/fields/System\.State'
        $r.fields.'System.State' | Should -Be 'Ready'
    }

    It 'applies the same two-step flow to New-AdoWorkItem (Task -State Active)' {
        $script:InitialState = 'New'
        $r = New-AdoWorkItem -Type 'Task' -Title 't' -State 'Active' -Confirm:$false
        $script:Calls.Count | Should -Be 2
        $script:Calls[0].Method | Should -Be 'POST'
        $script:Calls[1].Method | Should -Be 'PATCH'
        $r.fields.'System.State' | Should -Be 'Active'
    }

    It 'surfaces the created work item id when the state update fails' {
        $script:FailPatch = $true
        $err = $null
        try { New-AdoTestCase -Title 'tc' -State 'Ready' -Confirm:$false } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.FullyQualifiedErrorId | Should -BeLike 'AdoWorkItemStateUpdateFailed*'
        $err.Exception.Message | Should -Match '501'
        $err.Exception.Message | Should -Match 'Ready'
        $err.Exception.Message | Should -Match 'simulated PATCH failure'
        $err.TargetObject.id | Should -Be 501
        $script:Calls.Count | Should -Be 2
    }

    It 'makes no request at all with -WhatIf' {
        New-AdoTestCase -Title 'tc' -State 'Ready' -WhatIf | Out-Null
        $script:Calls.Count | Should -Be 0
    }

    It 'makes no request on a read-only session' {
        $script:AdoSession = New-Sess -Access 'Read'
        { New-AdoTestCase -Title 'tc' -State 'Ready' -Confirm:$false } | Should -Throw '*Access Read*'
        $script:Calls.Count | Should -Be 0
    }
}
