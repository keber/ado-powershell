#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #48: the service only accepts $timeframe=current, so
# Get-AdoIterations must send that parameter only for 'current' and filter 'past'/'future'
# client-side on attributes.timeFrame. Mocked HTTP only; no network access.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base.ps1', 'ado-git.ps1') {
        . (Join-Path $script:ScriptsDir $f)
    }

    function script:New-Iter([string]$Name, [string]$TimeFrame) {
        [pscustomobject]@{ id = $Name; name = $Name; path = "fakeproj\$Name"
                           attributes = [pscustomobject]@{ timeFrame = $TimeFrame } }
    }
}

Describe 'Get-AdoIterations -TimeFrame (issue #48)' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:AdoSession = [pscustomobject]@{ Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
            BaseUrl = 'https://dev.azure.com/fakeorg'; Access = 'Read'; AuthScheme = 'Basic'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' } }
        $script:All = @(
            (New-Iter 'S1' 'past'), (New-Iter 'S2' 'past'), (New-Iter 'S3' 'Past'),
            (New-Iter 'S4' 'current'), (New-Iter 'S5' 'future'))
        Mock Invoke-AdoGet {
            $script:Calls.Add([string]$Uri)
            # Emulate the service: only $timeframe=current is accepted.
            if ($Uri -match 'timeframe=(?!current$)') { throw '400 Bad Request' }
            $v = if ($Uri -match 'timeframe=current$') { @($script:All | Where-Object { $_.attributes.timeFrame -eq 'current' }) } else { $script:All }
            [pscustomobject]@{ value = $v }
        }
    }

    It 'current sends $timeframe=current and returns the server result' {
        $r = @(Get-AdoIterations -TimeFrame current)
        $script:Calls.Count | Should -Be 1
        $script:Calls[0] | Should -BeLike '*/_apis/work/teamsettings/iterations?api-version=7.1&$timeframe=current'
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'S4'
    }

    It 'no TimeFrame sends no $timeframe and returns everything' {
        $r = @(Get-AdoIterations)
        $script:Calls[0] | Should -Not -BeLike '*timeframe*'
        $r.Count | Should -Be 5
    }

    It 'past does not send $timeframe and filters client-side (N matches, case-insensitive)' {
        $r = @(Get-AdoIterations -TimeFrame past)
        $script:Calls.Count | Should -Be 1
        $script:Calls[0] | Should -Not -BeLike '*timeframe*'
        @($r.name) | Should -Be @('S1', 'S2', 'S3')
    }

    It 'future does not send $timeframe and returns the single match' {
        $r = @(Get-AdoIterations -TimeFrame future)
        $script:Calls[0] | Should -Not -BeLike '*timeframe*'
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'S5'
    }

    It 'returns an empty result (no error) when nothing matches' {
        $script:All = @((New-Iter 'S4' 'current'))
        $r = @(Get-AdoIterations -TimeFrame future)
        $r.Count | Should -Be 0
    }

    It 'ignores iterations without attributes.timeFrame when filtering' {
        $script:All = @([pscustomobject]@{ name = 'X'; attributes = [pscustomobject]@{} },
                        [pscustomobject]@{ name = 'Y' }, (New-Iter 'S1' 'past'))
        $r = @(Get-AdoIterations -TimeFrame past)
        @($r.name) | Should -Be @('S1')
    }

    It 'keeps the escaped team segment when filtering client-side' {
        Get-AdoIterations -Team 'Team A&B #2' -TimeFrame past | Out-Null
        $script:Calls[0] | Should -BeLike 'https://dev.azure.com/fakeorg/fakeproj/Team%20A%26B%20%232/_apis/work/teamsettings/iterations?*'
    }

    It 'still rejects a value outside past/current/future before sending' {
        { Get-AdoIterations -TimeFrame 'current&x=1' } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }
}
