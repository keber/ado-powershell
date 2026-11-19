BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    . (Join-Path $script:ScriptsDir 'ado-content.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
}

Describe 'M8 - Saved inline image extension is not restricted to image types' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Invoke-AdoDownload {
            [IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='))
        }
        $script:ImageExt = @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg')
    }

    It 'never returns a non-image extension from fileName=' {
        Get-AdoImageExtension -Url 'https://dev.azure.com/fakeorg/_apis/wit/attachments/abc?fileName=notes.ps1' |
            Should -Be 'png'
    }

    It 'rejects an alternate data stream suffix in fileName= (a.png:evil)' {
        $e = Get-AdoImageExtension -Url 'https://dev.azure.com/fakeorg/_apis/wit/attachments/abc?fileName=a.png:evil'
        $e | Should -BeIn $script:ImageExt
        $e | Should -Not -Match '[^a-z0-9]'
    }

    It 'rejects a non-image data: URI MIME subtype (data:image/hta)' {
        Get-AdoImageExtension -Url 'data:image/hta;base64,QUJD' | Should -Be 'png'
    }

    It 'maps image/svg+xml to svg' {
        Get-AdoImageExtension -Url 'data:image/svg+xml;base64,QUJD' | Should -Be 'svg'
    }

    It 'keeps allow-listed extensions, case-insensitively' {
        Get-AdoImageExtension -Url 'https://x/y?fileName=Shot.WEBP' | Should -Be 'webp'
        Get-AdoImageExtension -Url 'data:image/jpeg;base64,QUJD'    | Should -Be 'jpg'
    }

    It 'Save-AdoInlineImage writes only files with image extensions' {
        $dir  = Join-Path $TestDrive 'm8'
        $html = '<img src="https://dev.azure.com/fakeorg/_apis/wit/attachments/abc?fileName=notes.ps1">' +
                '<img src="https://dev.azure.com/fakeorg/_apis/wit/attachments/abd?fileName=a.png:evil">' +
                '<img src="data:image/hta;base64,QUJD">'
        $null = Save-AdoInlineImage -Html $html -OutDirectory $dir -Headers $script:FakeHeaders `
                    -WarningAction SilentlyContinue
        $files = @(Get-ChildItem -LiteralPath $dir -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) { $f.Extension.TrimStart('.') | Should -BeIn $script:ImageExt }
    }

    It 'Save-AdoInlineImage keeps a hostile -BaseName inside the output directory' {
        $dir  = Join-Path $TestDrive 'm8-base'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $html = '<img src="data:image/png;base64,QUJD">'
        $out  = @(Save-AdoInlineImage -Html $html -OutDirectory $dir -BaseName '..\x' -Headers $script:FakeHeaders `
                    -WarningAction SilentlyContinue)
        $out.Count | Should -Be 1
        $full = [IO.Path]::GetFullPath($out[0])
        [IO.Path]::GetDirectoryName($full) | Should -Be ([IO.Path]::GetFullPath($dir).TrimEnd('\'))
        [IO.Path]::GetFileName($full)      | Should -Not -Match '\.\.|[:\\/]'
        Test-Path -LiteralPath (Join-Path $TestDrive 'x-1.png') | Should -BeFalse
    }
}
