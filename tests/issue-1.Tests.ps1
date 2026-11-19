#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #1. No network: every HTTP entry point is mocked.
# Run: Invoke-Pester -Path tests/issue-1.Tests.ps1 -Output Detailed

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scripts 'ado-base.ps1')
    . (Join-Path $scripts 'ado-content.ps1')

    $script:FakeHeaders = @{ Authorization = 'Basic FAKE-TEST-TOKEN'; 'Content-Type' = 'application/json' }
    $script:AdoSession = [pscustomobject]@{
        Org     = 'contoso'
        Project = 'MyApp'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/contoso'
        Headers = $script:FakeHeaders
    }
}

Describe 'C1 - Save-AdoInlineImage must not leak ADO credentials to third-party hosts' {
    BeforeEach {
        Mock Invoke-AdoDownload {
            [IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3))
        }
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $common = @{
            OutDirectory = $out
            Org          = 'contoso'
            ApiV         = '7.1'
            Headers      = $script:FakeHeaders
            Confirm      = $false
            WarningAction = 'SilentlyContinue'
        }
    }

    It 'does not send the Authorization header to a non-ADO host' {
        $html = '<p>x</p><img src="https://example.invalid/x.png">'

        $null = Save-AdoInlineImage -Html $html @common

        Should -Invoke Invoke-AdoDownload -Times 0 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -ne 'dev.azure.com' -and $Headers -and $Headers.ContainsKey('Authorization')
        }
    }

    It 'still sends the Authorization header to the ADO attachment endpoint (control)' {
        $html = '<img src="/contoso/_apis/wit/attachments/abc?fileName=a.png">'

        $null = Save-AdoInlineImage -Html $html @common

        Should -Invoke Invoke-AdoDownload -Times 1 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -eq 'dev.azure.com' -and $Headers.ContainsKey('Authorization')
        }
    }

    It 'skips (does not download) third-party hosts, warning once' {
        $html = '<img src="https://example.invalid/x.png">'
        $common.WarningAction = 'Continue'
        $r = Save-AdoInlineImage -Html $html @common -WarningVariable w 3>$null
        Should -Invoke Invoke-AdoDownload -Times 0 -Exactly
        @($r).Count | Should -Be 0
        @($w).Count | Should -Be 1
    }

    It 'rejects plain http even for the ADO host' {
        $html = '<img src="http://dev.azure.com/contoso/_apis/wit/attachments/abc">'
        $null = Save-AdoInlineImage -Html $html @common
        Should -Invoke Invoke-AdoDownload -Times 0 -Exactly
    }

    It 'rejects lookalike hosts (suffix and userinfo tricks)' {
        $html = '<img src="https://dev.azure.com.evil.invalid/a.png"><img src="https://notvisualstudio.com/a.png"><img src="https://dev.azure.com@evil.invalid/a.png">'
        $null = Save-AdoInlineImage -Html $html @common
        Should -Invoke Invoke-AdoDownload -Times 0 -Exactly
    }

    It 'allows absolute https URLs on dev.azure.com and *.visualstudio.com' {
        $html = '<img src="https://dev.azure.com/contoso/_apis/wit/attachments/a">' +
                '<img src="https://contoso.visualstudio.com/_apis/wit/attachments/b">'
        $null = Save-AdoInlineImage -Html $html @common
        Should -Invoke Invoke-AdoDownload -Times 2 -Exactly
    }
}
