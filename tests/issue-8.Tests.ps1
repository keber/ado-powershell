#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for MEDIUM-severity review findings (M1-M10).
# These tests describe the CORRECT behaviour; they are expected to fail until the
# corresponding issue is fixed. No network access: all HTTP calls are mocked.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    . (Join-Path $script:ScriptsDir 'ado-content.ps1')
    . (Join-Path $script:ScriptsDir 'ado-testing.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pipelines.ps1')
    . (Join-Path $script:ScriptsDir 'ado-git.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }

    $script:SignInHtml = '<html><head><title>Azure DevOps Services | Sign In</title></head>' +
                         '<body><form action="/_signin"></form></body></html>'
}

Describe 'M1 - Test-AdoSignInResponse treats legitimate raw text as a sign-in page' {
    BeforeAll { Mock Start-Sleep { } }

    It 'does not flag plain text that merely mentions "sign in"' {
        Test-AdoSignInResponse -Response 'Step 3: ask the user to sign in again and retry.' |
            Should -BeFalse
    }

    It 'does not flag a raw HTML fragment that is not the ADO login page' {
        Test-AdoSignInResponse -Response '<html><body><p>Release notes</p></body></html>' |
            Should -BeFalse
    }

    It 'does not flag plain text containing sign-in markers outside an HTML document' {
        Test-AdoSignInResponse -Response 'Docs: the form posts to /_signin and uses __RequestVerificationToken.' |
            Should -BeFalse
    }

    It 'does not flag an HTML document that only mentions "sign in" in the body' {
        Test-AdoSignInResponse -Response '<html><head><title>Help</title></head><body>Please sign in.</body></html>' |
            Should -BeFalse
    }

    It 'Invoke-AdoGet returns raw text content mentioning "sign in" instead of throwing' {
        Mock Invoke-RestMethod { 'README: users must sign in with SSO before using the tool.' }
        { Invoke-AdoGet -Uri 'https://dev.azure.com/fakeorg/_apis/some/text' -Headers $script:FakeHeaders } |
            Should -Not -Throw
    }

    It 'still flags the real ADO sign-in page (guard against over-correction)' {
        Test-AdoSignInResponse -Response $script:SignInHtml | Should -BeTrue
    }

    It 'flags a sign-in page with BOM, leading whitespace and DOCTYPE' {
        $page = [string][char]0xFEFF + "`r`n  <!DOCTYPE html><html><body><input name=`"__RequestVerificationToken`"></body></html>"
        Test-AdoSignInResponse -Response $page | Should -BeTrue
    }

    It 'flags an HTML page redirecting to login.microsoftonline.com' {
        Test-AdoSignInResponse -Response '<html><body><a href="https://login.microsoftonline.com/x">go</a></body></html>' |
            Should -BeTrue
    }

    It 'does not flag a parsed object that merely contains the words "sign in"' {
        Test-AdoSignInResponse -Response ([pscustomobject]@{ text = 'please sign in' }) | Should -BeFalse
    }

    It 'throws the sign-in error after exactly one Invoke-RestMethod call (no retries)' {
        Mock Invoke-RestMethod { $script:SignInHtml }
        { Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Headers $script:FakeHeaders } |
            Should -Throw '*sign-in page*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}
