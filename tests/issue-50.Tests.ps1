#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Tests for issue #50: 401/403 are thrown as ErrorRecords with stable ErrorIds
# (AdoUnauthorized / AdoForbidden), like AdoSignInPage. No network access: HTTP is mocked.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')

    $script:Uri         = 'https://dev.azure.com/fakeorg/fakeproj/_apis/x?api-version=7.1'
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }

    # Builds the error record Invoke-RestMethod / Invoke-WebRequest throw for an HTTP error.
    function script:New-HttpError([int]$Status) {
        $ex = [System.Exception]::new("The remote server returned an error: ($Status).")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = @{} })
        [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
    }
    function script:Get-Thrown([scriptblock]$Block) {
        try { & $Block } catch { return $_ }
    }
}

Describe 'Issue 50 - stable ErrorIds for 401 / 403' {
    BeforeAll { Mock Start-Sleep { } }
    BeforeEach { $script:Calls = 0 }

    It 'Invoke-AdoRequest <S> -> <Id> / <Cat>, one request, message kept' -ForEach @(
        @{ S = 401; Id = 'AdoUnauthorized'; Cat = 'AuthenticationError'; Msg = '401 Unauthorized - check ADO_PAT.' }
        @{ S = 403; Id = 'AdoForbidden';    Cat = 'PermissionDenied';    Msg = '403 Forbidden - PAT does not have sufficient permissions for: *' }
    ) {
        Mock Invoke-RestMethod { $script:Calls++; throw (New-HttpError $S) }
        $err = Get-Thrown { Invoke-AdoRequest -Method GET -Uri $script:Uri -Headers $script:FakeHeaders }
        $err.FullyQualifiedErrorId | Should -Be $Id
        $err.CategoryInfo.Category | Should -Be $Cat
        $err.Exception.Message     | Should -BeLike $Msg
        $script:Calls              | Should -Be 1
    }

    It 'Invoke-AdoGetPaged <S> -> <Id> / <Cat>, one request' -ForEach @(
        @{ S = 401; Id = 'AdoUnauthorized'; Cat = 'AuthenticationError' }
        @{ S = 403; Id = 'AdoForbidden';    Cat = 'PermissionDenied' }
    ) {
        Mock Invoke-WebRequest { $script:Calls++; throw (New-HttpError $S) }
        $err = Get-Thrown { Invoke-AdoGetPaged -Uri $script:Uri -Headers $script:FakeHeaders }
        $err.FullyQualifiedErrorId | Should -Be $Id
        $err.CategoryInfo.Category | Should -Be $Cat
        $script:Calls              | Should -Be 1
    }

    It 'Invoke-AdoDownload <S> -> <Id> / <Cat>, one request' -ForEach @(
        @{ S = 401; Id = 'AdoUnauthorized'; Cat = 'AuthenticationError' }
        @{ S = 403; Id = 'AdoForbidden';    Cat = 'PermissionDenied' }
    ) {
        Mock Invoke-WebRequest { $script:Calls++; throw (New-HttpError $S) }
        $out = Join-Path $TestDrive 'f.bin'
        $err = Get-Thrown { Invoke-AdoDownload -Uri $script:Uri -OutFile $out -Headers $script:FakeHeaders }
        $err.FullyQualifiedErrorId | Should -Be $Id
        $err.CategoryInfo.Category | Should -Be $Cat
        $script:Calls              | Should -Be 1
    }

    It 'messages never contain the Authorization header value' {
        Mock Invoke-RestMethod { throw (New-HttpError 401) }
        $err = Get-Thrown { Invoke-AdoRequest -Method GET -Uri $script:Uri -Headers $script:FakeHeaders }
        $err.Exception.Message | Should -Not -Match 'ZmFrZQ'
    }

    It 'other statuses are unchanged (404 keeps its plain message)' {
        Mock Invoke-RestMethod { throw (New-HttpError 404) }
        $err = Get-Thrown { Invoke-AdoRequest -Method GET -Uri $script:Uri -Headers $script:FakeHeaders }
        $err.Exception.Message     | Should -BeLike '404 Not Found*'
        $err.FullyQualifiedErrorId | Should -Not -Match '^Ado(Unauthorized|Forbidden)$'
    }
}
