#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #14 (Add-AdoWorkItemAttachment path and name handling).
# No network access: all HTTP calls are mocked.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
}

Describe 'M7 - Add-AdoWorkItemAttachment file name and path handling' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Invoke-AdoRequest { [pscustomobject]@{ id = 1234 } }
        Mock Write-Host { }
        Mock Invoke-RestMethod {
            # Mocked -Uri is typed [Uri]; ToString() would unescape %26/%2B, so use OriginalString
            $script:UploadUri   = ([Uri]$Uri).OriginalString
            $script:UploadBytes = $Body
            [pscustomobject]@{ id = 'att-1'; url = 'https://dev.azure.com/fakeorg/_apis/wit/attachments/att-1' }
        }
    }

    BeforeEach {
        $script:UploadUri   = $null
        $script:UploadBytes = $null
    }

    It 'URL-encodes reserved characters (#, &, +) in fileName' {
        $file = Join-Path $TestDrive 'a#b&c+d.txt'
        [IO.File]::WriteAllText($file, 'x')
        $null = Add-AdoWorkItemAttachment -Id 1234 -FilePath $file -Headers $script:FakeHeaders -Confirm:$false
        $script:UploadUri | Should -Match 'fileName=a%23b%26c%2Bd\.txt&'
    }

    It 'accepts a file whose name contains wildcard characters ([1])' {
        $file = Join-Path $TestDrive 'report[1].txt'
        [IO.File]::WriteAllText($file, 'x')
        { Add-AdoWorkItemAttachment -Id 1234 -FilePath $file -Headers $script:FakeHeaders -Confirm:$false } |
            Should -Not -Throw
        [Text.Encoding]::ASCII.GetString([byte[]]$script:UploadBytes) | Should -Be 'x'
    }

    It 'resolves a relative path against $PWD, not the process working directory' {
        $sub = Join-Path $TestDrive 'rel'
        $null = New-Item -ItemType Directory -Path $sub -Force
        [IO.File]::WriteAllText((Join-Path $sub 'relative-only.txt'), 'hello')
        Push-Location $sub
        try {
            { Add-AdoWorkItemAttachment -Id 1234 -FilePath 'relative-only.txt' -Headers $script:FakeHeaders -Confirm:$false } |
                Should -Not -Throw
            [Text.Encoding]::ASCII.GetString([byte[]]$script:UploadBytes) | Should -Be 'hello'
        } finally {
            Pop-Location
        }
    }

    It 'throws a clear error when FilePath is a directory' {
        $dir = Join-Path $TestDrive 'adir'
        $null = New-Item -ItemType Directory -Path $dir -Force
        { Add-AdoWorkItemAttachment -Id 1234 -FilePath $dir -Headers $script:FakeHeaders -Confirm:$false } |
            Should -Throw -ExpectedMessage '*not a file*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'throws File not found for a missing path' {
        $missing = Join-Path $TestDrive 'nope.txt'
        { Add-AdoWorkItemAttachment -Id 1234 -FilePath $missing -Headers $script:FakeHeaders -Confirm:$false } |
            Should -Throw -ExpectedMessage '*File not found*'
    }
}
