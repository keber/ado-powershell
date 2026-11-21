#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #47: every HTTP call must pass -TimeoutSec so a stalled connection cannot
# block a session indefinitely. Mocked HTTP only; no network access.

BeforeDiscovery {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    $ScriptCases = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base.ps1', 'ado-workitems.ps1', 'ado-testing.ps1', 'ado-pipelines.ps1', 'ado-git.ps1', 'ado-pullrequests.ps1') {
        . (Join-Path $script:ScriptsDir $f)
    }

    function script:New-Sess([hashtable]$Extra = @{}) {
        $s = [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/fakeorg'
                                Access = 'Write'; AuthScheme = 'Basic'; Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
        foreach ($k in $Extra.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }
        $s
    }

    function script:New-TimeoutException { [System.Net.WebException]::new('The operation has timed out.', [System.Net.WebExceptionStatus]::Timeout) }
}

Describe 'Initialize-AdoSession timeouts' {
    BeforeEach {
        $script:SavedPat = $env:ADO_PAT; $script:SavedT = $env:ADO_TIMEOUT_SEC; $script:SavedTT = $env:ADO_TRANSFER_TIMEOUT_SEC
        $env:ADO_PAT = 'fake-pat-for-tests'
        $env:ADO_TIMEOUT_SEC = $null; $env:ADO_TRANSFER_TIMEOUT_SEC = $null
    }
    AfterEach {
        $env:ADO_PAT = $script:SavedPat; $env:ADO_TIMEOUT_SEC = $script:SavedT; $env:ADO_TRANSFER_TIMEOUT_SEC = $script:SavedTT
    }

    It 'defaults to 100 s for requests and 300 s for transfers' {
        $s = Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj'
        $s.TimeoutSec | Should -Be 100
        $s.TransferTimeoutSec | Should -Be 300
    }

    It 'honours -TimeoutSec and -TransferTimeoutSec' {
        $s = Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' -TimeoutSec 20 -TransferTimeoutSec 45
        $s.TimeoutSec | Should -Be 20
        $s.TransferTimeoutSec | Should -Be 45
    }

    It 'reads ADO_TIMEOUT_SEC and ADO_TRANSFER_TIMEOUT_SEC; an explicit parameter wins' {
        $env:ADO_TIMEOUT_SEC = '33'; $env:ADO_TRANSFER_TIMEOUT_SEC = '66'
        $s = Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj'
        $s.TimeoutSec | Should -Be 33
        $s.TransferTimeoutSec | Should -Be 66
        (Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' -TimeoutSec 9).TimeoutSec | Should -Be 9
    }

    It 'rejects 0 (infinite) and negative values' {
        { Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' -TimeoutSec 0 } | Should -Throw
        { Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' -TransferTimeoutSec -5 } | Should -Throw
    }

    It 'rejects an invalid environment value by name' {
        $env:ADO_TIMEOUT_SEC = 'abc'
        { Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' } | Should -Throw '*ADO_TIMEOUT_SEC*'
        $env:ADO_TIMEOUT_SEC = '0'
        { Initialize-AdoSession -Org 'fakeorg' -Project 'fakeproj' } | Should -Throw '*ADO_TIMEOUT_SEC*'
    }
}

Describe '-TimeoutSec is passed on every HTTP path' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Start-Sleep { }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:AdoSession = New-Sess
        Mock Invoke-RestMethod {
            $script:Calls.Add([pscustomobject]@{ Bound = ($null -ne $TimeoutSec -and $TimeoutSec -gt 0); TimeoutSec = $TimeoutSec; Method = [string]$Method })
            [pscustomobject]@{ id = 1; url = 'https://dev.azure.com/fakeorg/_apis/wit/attachments/abc'; value = @() }
        }
        Mock Invoke-WebRequest {
            $script:Calls.Add([pscustomobject]@{ Bound = ($null -ne $TimeoutSec -and $TimeoutSec -gt 0); TimeoutSec = $TimeoutSec; Method = 'GET' })
            [pscustomobject]@{ Headers = @{ 'Content-Type' = 'application/octet-stream' }
                               RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"value":[{"id":1}]}'))
                               Content = '{"value":[{"id":1}]}' }
        }
    }

    It 'Invoke-AdoRequest <Method> uses the default 100 s' -TestCases @(
        @{ Method = 'GET' }, @{ Method = 'POST' }, @{ Method = 'PATCH' }
    ) {
        Invoke-AdoRequest -Method $Method -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Body '{}' | Out-Null
        $script:Calls[0].Bound | Should -BeTrue
        $script:Calls[0].TimeoutSec | Should -Be 100
    }

    It 'Invoke-AdoRequest uses the session TimeoutSec' {
        $script:AdoSession = New-Sess @{ TimeoutSec = 30; TransferTimeoutSec = 90 }
        Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/_apis/x' | Out-Null
        $script:Calls[0].TimeoutSec | Should -Be 30
    }

    It 'Invoke-AdoRequest -TimeoutSec overrides the session value' {
        $script:AdoSession = New-Sess @{ TimeoutSec = 30 }
        Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/_apis/x' -TimeoutSec 7 | Out-Null
        $script:Calls[0].TimeoutSec | Should -Be 7
    }

    It 'Invoke-AdoGet forwards -TimeoutSec' {
        Invoke-AdoGet -Uri 'https://dev.azure.com/fakeorg/_apis/x' -TimeoutSec 11 | Out-Null
        $script:Calls[0].TimeoutSec | Should -Be 11
    }

    It 'Invoke-AdoRequest works without any session (default 100 s)' {
        $script:AdoSession = $null
        Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Headers @{ Authorization = 'Basic ZmFrZQ==' } | Out-Null
        $script:Calls[0].TimeoutSec | Should -Be 100
    }

    It 'Invoke-AdoGetPaged uses the default and a custom value' {
        Invoke-AdoGetPaged -Uri 'https://dev.azure.com/fakeorg/_apis/x?api-version=7.1' | Out-Null
        $script:Calls[0].TimeoutSec | Should -Be 100
        Invoke-AdoGetPaged -Uri 'https://dev.azure.com/fakeorg/_apis/x?api-version=7.1' -TimeoutSec 15 | Out-Null
        $script:Calls[1].TimeoutSec | Should -Be 15
    }

    It 'Invoke-AdoDownload uses the transfer timeout (default 300 s), the session value and an override' {
        $out = Join-Path $TestDrive 'f.bin'
        Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/_apis/x' -OutFile $out
        $script:Calls[0].TimeoutSec | Should -Be 300
        $script:AdoSession = New-Sess @{ TimeoutSec = 30; TransferTimeoutSec = 90 }
        Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/_apis/x' -OutFile $out
        $script:Calls[1].TimeoutSec | Should -Be 90
        Invoke-AdoDownload -Uri 'https://dev.azure.com/fakeorg/_apis/x' -OutFile $out -TimeoutSec 5
        $script:Calls[2].TimeoutSec | Should -Be 5
    }

    It 'Add-AdoWorkItemAttachment: the upload uses the transfer timeout, the PATCH the request timeout' {
        $file = Join-Path $TestDrive 'a.txt'
        Set-Content -LiteralPath $file -Value 'hello'
        $script:AdoSession = New-Sess @{ TimeoutSec = 30; TransferTimeoutSec = 90 }
        Add-AdoWorkItemAttachment -Id 5 -FilePath $file -Headers $script:AdoSession.Headers | Out-Null
        $script:Calls.Count | Should -Be 2
        $script:Calls[0].Method | Should -Be 'POST'
        $script:Calls[0].TimeoutSec | Should -Be 90
        $script:Calls[1].Method | Should -Be 'PATCH'
        $script:Calls[1].TimeoutSec | Should -Be 30
    }

    It 'a hand-built session without timeout properties falls back to the defaults' {
        $script:AdoSession = New-Sess
        $script:AdoSession.PSObject.Properties['TimeoutSec'] | Should -BeNullOrEmpty
        Get-AdoTimeoutSec | Should -Be 100
        Get-AdoTimeoutSec -Transfer | Should -Be 300
    }
}

Describe 'Timeout and retry policy' {
    BeforeEach {
        Mock Write-Warning { }
        Mock Start-Sleep { }
        $script:Attempts = 0
        $script:AdoSession = New-Sess
        Mock Invoke-RestMethod { $script:Attempts++; throw (New-TimeoutException) }
    }

    It 'retries a timed-out GET and then fails with the attempt count' {
        { Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/_apis/x' } | Should -Throw '*Failed after 3 attempts*'
        $script:Attempts | Should -Be 3
    }

    It 'does not retry a timed-out POST or PATCH (the write may have been committed)' -TestCases @(
        @{ Method = 'POST' }, @{ Method = 'PATCH' }
    ) {
        { Invoke-AdoRequest -Method $Method -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Body '{}' } | Should -Throw '*timed out*'
        $script:Attempts | Should -Be 1
    }

    It 'retries a timed-out POST only with -RetryNonIdempotent' {
        { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Body '{}' -RetryNonIdempotent -ReadOnly } | Should -Throw
        $script:Attempts | Should -Be 3
    }
}

Describe 'Every web cmdlet call in the scripts sets a timeout' {
    It '<Name>: each Invoke-RestMethod / Invoke-WebRequest passes -TimeoutSec (directly or in its splat)' -ForEach $ScriptCases {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $Path -Raw
        $calls = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in 'Invoke-RestMethod', 'Invoke-WebRequest', 'iwr', 'irm', 'curl', 'wget' }, $true)
        foreach ($c in $calls) {
            $direct = [bool]($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'TimeoutSec' })
            $splat  = [bool]($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
            $inSplat = $splat -and ($text -match '(?m)^\s*TimeoutSec\s*=' -or $text -match '\$\w+\.TimeoutSec\s*=')
            ($direct -or $inSplat) | Should -BeTrue -Because "line $($c.Extent.StartLineNumber) of $Name calls $($c.GetCommandName()) without -TimeoutSec"
        }
    }
}
