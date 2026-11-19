#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #9 (M2): an HTML sign-in page served with HTTP 200 must not be
# saved as an image. No network access: all HTTP calls are mocked.

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
    $script:ImgHtml = '<img src="https://dev.azure.com/fakeorg/_apis/wit/attachments/abc?fileName=m.png">'
}

Describe 'M2 - Downloads do not detect an HTML sign-in page served with HTTP 200' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value $script:SignInHtml -Encoding UTF8
            # Like the real cmdlet, -OutFile emits nothing unless -PassThru is given.
            if ($PassThru) { [pscustomobject]@{
                StatusCode = 200
                Headers    = @{ 'Content-Type' = 'text/html; charset=utf-8' }
                Content    = $script:SignInHtml
            } }
        }
    }

    It 'Invoke-AdoDownload throws when the downloaded content is a sign-in page' {
        $out = Join-Path $TestDrive 'dl-signin.png'
        { Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/_apis/wit/attachments/abc?fileName=a.png' `
              -OutFile $out -Headers $script:FakeHeaders } | Should -Throw '*ADO_PAT*'
    }

    It 'Invoke-AdoDownload deletes the file it wrote' {
        $out = Join-Path $TestDrive 'dl-signin2.png'
        try { Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/_apis/wit/attachments/abc' `
                -OutFile $out -Headers $script:FakeHeaders } catch { }
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'Save-AdoInlineImage does not report a sign-in page as a saved image' {
        $dir   = Join-Path $TestDrive 'm2'
        $files = Save-AdoInlineImage -Html $script:ImgHtml -OutDirectory $dir -Headers $script:FakeHeaders `
                    -WarningAction SilentlyContinue
        @($files).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $dir 'inline-1.png') | Should -BeFalse
    }
}

Describe 'M2 - Save-AdoInlineImage sniffs image signatures' {
    BeforeAll { Mock Start-Sleep { } }

    It 'discards HTML served with a non-html Content-Type, with a warning' {
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value $script:SignInHtml -Encoding UTF8
            if ($PassThru) { [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/octet-stream' } } }
        }
        $dir   = Join-Path $TestDrive 'sniff-html'
        $files = Save-AdoInlineImage -Html $script:ImgHtml -OutDirectory $dir -Headers $script:FakeHeaders `
                    -WarningVariable w -WarningAction SilentlyContinue
        @($files).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $dir 'inline-1.png') | Should -BeFalse
        ($w -join ' ') | Should -Match 'not an image'
    }

    It 'still saves a real PNG' {
        Mock Invoke-WebRequest {
            [IO.File]::WriteAllBytes($OutFile, [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0,0))
            if ($PassThru) { [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'image/png' } } }
        }
        $dir   = Join-Path $TestDrive 'png'
        $files = Save-AdoInlineImage -Html $script:ImgHtml -OutDirectory $dir -Headers $script:FakeHeaders
        @($files).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $dir 'inline-1.png') | Should -BeTrue
    }

    It 'accepts <name> content' -ForEach @(
        @{ name = 'JPEG';             bytes = [byte[]](0xFF,0xD8,0xFF,0xE0,0,0) }
        @{ name = 'GIF';              bytes = [byte[]](0x47,0x49,0x46,0x38,0x39,0x61) }
        @{ name = 'BMP';              bytes = [byte[]](0x42,0x4D,0,0,0,0) }
        @{ name = 'WEBP';             bytes = [byte[]](0x52,0x49,0x46,0x46,1,2,3,4,0x57,0x45,0x42,0x50) }
        @{ name = 'SVG';              bytes = [Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg"/>') }
        @{ name = 'XML-prefixed SVG'; bytes = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><svg/>') }
    ) {
        $script:CaseBytes = $bytes
        Mock Invoke-WebRequest {
            [IO.File]::WriteAllBytes($OutFile, $script:CaseBytes)
            if ($PassThru) { [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'image/x' } } }
        }
        $dir   = Join-Path $TestDrive "sig-$name"
        $files = Save-AdoInlineImage -Html $script:ImgHtml -OutDirectory $dir -Headers $script:FakeHeaders
        @($files).Count | Should -Be 1
    }
}
