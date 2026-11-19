#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #12: Get-AdoWorkItemsBatch errorPolicy. Network-free: mocks only.

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
}

Describe 'M5 - Get-AdoWorkItemsBatch errorPolicy' {
    BeforeAll { Mock Start-Sleep { } }

    It 'sends errorPolicy "Omit" by default' {
        $script:CapturedBody = $null
        Mock Invoke-AdoRequest {
            $script:CapturedBody = $Body
            [pscustomobject]@{ count = 1; value = @([pscustomobject]@{ id = 1 }) }
        }
        $null = Get-AdoWorkItemsBatch -Ids 1, 2 -Headers $script:FakeHeaders -WarningAction SilentlyContinue
        ($script:CapturedBody | ConvertFrom-Json).errorPolicy | Should -Be 'Omit'
    }

    It 'sends errorPolicy "Fail" when -ErrorPolicy Fail is given' {
        $script:CapturedBody = $null
        Mock Invoke-AdoRequest {
            $script:CapturedBody = $Body
            [pscustomobject]@{ count = 2; value = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }) }
        }
        $null = Get-AdoWorkItemsBatch -Ids 1, 2 -ErrorPolicy Fail -Headers $script:FakeHeaders
        ($script:CapturedBody | ConvertFrom-Json).errorPolicy | Should -Be 'Fail'
    }

    It 'rejects an invalid -ErrorPolicy value' {
        { Get-AdoWorkItemsBatch -Ids 1 -ErrorPolicy Bogus -Headers $script:FakeHeaders } | Should -Throw
    }

    It 'filters null entries returned for omitted ids' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ count = 3; value = @([pscustomobject]@{ id = 1 }, $null, [pscustomobject]@{ id = 3 }) }
        }
        $r = Get-AdoWorkItemsBatch -Ids 1, 2, 3 -Headers $script:FakeHeaders -WarningAction SilentlyContinue
        $r.Count | Should -Be 2
        @($r | ForEach-Object { $_.id }) | Should -Be @(1, 3)
    }

    It 'warns listing the omitted ids' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ count = 3; value = @([pscustomobject]@{ id = 1 }, $null, [pscustomobject]@{ id = 3 }) }
        }
        $null = Get-AdoWorkItemsBatch -Ids 1, 2, 3 -Headers $script:FakeHeaders `
                    -WarningVariable warn -WarningAction SilentlyContinue
        @($warn).Count | Should -Be 1
        # The id list follows the last colon; only id 2 was omitted.
        (($warn -join ' ') -split ':')[-1].Trim() | Should -Be '2'
    }

    It 'does not warn when nothing was omitted' {
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ count = 2; value = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }) }
        }
        $null = Get-AdoWorkItemsBatch -Ids 1, 2 -Headers $script:FakeHeaders `
                    -WarningVariable warn -WarningAction SilentlyContinue
        @($warn).Count | Should -Be 0
    }
}
