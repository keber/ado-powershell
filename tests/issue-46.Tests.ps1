#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #46: Invoke-WebRequest must always be called with -UseBasicParsing.
# On Windows PowerShell 5.1 without the Internet Explorer engine it otherwise throws a
# NullReferenceException (so Save-AdoInlineImage saved nothing). Mocked HTTP only; no network access.

BeforeDiscovery {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    $ScriptCases = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
}

Describe 'Invoke-AdoDownload' {
    BeforeEach {
        $script:AdoSession = [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
            BaseUrl = 'https://dev.azure.com/fakeorg'; Access = 'Read'; AuthScheme = 'Basic'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Content-Type' = 'image/png' } } }
    }

    It 'passes -UseBasicParsing to Invoke-WebRequest' {
        Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/p/_apis/wit/attachments/1' -OutFile (Join-Path $TestDrive 'img.bin')
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $UseBasicParsing.IsPresent }
    }

    It 'still refuses untrusted hosts before any request (issue #1 allow-list intact)' {
        { Invoke-AdoDownload -Uri 'https://evil.example.com/x' -OutFile (Join-Path $TestDrive 'x.bin') } | Should -Throw '*refusing*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Static scan: every Invoke-WebRequest uses -UseBasicParsing' {
    It '<Name>' -TestCases $ScriptCases {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -match '^(Invoke-WebRequest|iwr|curl|wget)$'
        }, $true)
        $missing = @($calls | Where-Object {
            -not ($_.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -eq 'UseBasicParsing' })
        } | ForEach-Object { "line $($_.Extent.StartLineNumber)" })
        $missing | Should -BeNullOrEmpty -Because 'Invoke-WebRequest without -UseBasicParsing fails on Windows PowerShell 5.1 without IE'
    }
}
