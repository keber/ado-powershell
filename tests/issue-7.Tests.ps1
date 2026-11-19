#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #7: Invoke-AdoRequest must not retry non-idempotent
# methods (POST/PATCH) on timeouts / 5xx. No network access: all HTTP calls are mocked.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scriptsDir 'ado-base.ps1')
    . (Join-Path $scriptsDir 'ado-workitems.ps1')
    . (Join-Path $scriptsDir 'ado-testing.ps1')
    . (Join-Path $scriptsDir 'ado-pipelines.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }

    # Save ADO_* env vars so tests can clear them and restore afterwards
    $script:EnvNames = 'ADO_ORG', 'ADO_PROJECT', 'ADO_API_VER', 'ADO_PAT', 'AZURE_DEVOPS_EXT_PAT'
    $script:SavedEnv = @{}
    foreach ($n in $script:EnvNames) {
        $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }
}

AfterAll {
    foreach ($n in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n], 'Process')
    }
}

Describe 'H5 - Invoke-AdoRequest retry policy for non-idempotent methods' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Write-Warning { }

        # Builds an exception carrying an HTTP status (and optional Retry-After header)
        function New-HttpError([int]$Status, [string]$RetryAfter) {
            $headers = @{}
            if ($RetryAfter) { $headers['Retry-After'] = $RetryAfter }
            $ex = [System.Exception]::new("HTTP $Status")
            Add-Member -InputObject $ex -NotePropertyName Response `
                -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = $headers })
            return $ex
        }
        $script:Uri = 'https://dev.azure.com/fakeorg/fakeproj/_apis/wit/workitems/$Task?api-version=7.1'
    }

    It 'does not retry <Method> on a timeout' -TestCases @(
        @{ Method = 'POST' }
        @{ Method = 'PATCH' }
    ) {
        param($Method)
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('The operation has timed out') }
        { Invoke-AdoRequest -Method $Method -Uri 'https://dev.azure.com/fakeorg/fakeproj/_apis/wit/workitems/$Task?api-version=7.1' `
            -Body '[]' -ContentType 'application/json-patch+json' -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'still retries GET on a timeout (guard)' {
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('The operation has timed out') }
        { Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/fakeorg/fakeproj/_apis/projects' `
            -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'rethrows the original error for <Method> on a timeout' -TestCases @(
        @{ Method = 'POST' }
        @{ Method = 'PATCH' }
    ) {
        param($Method)
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('The operation has timed out') }
        { Invoke-AdoRequest -Method $Method -Uri $script:Uri -Body '[]' -Headers $script:FakeHeaders } |
            Should -Throw '*timed out*'
    }

    It 'does not retry <Method> on HTTP 500 or 503' -TestCases @(
        @{ Method = 'POST'; Status = 500 }
        @{ Method = 'POST'; Status = 503 }
        @{ Method = 'PATCH'; Status = 500 }
        @{ Method = 'PATCH'; Status = 503 }
    ) {
        param($Method, $Status)
        $script:err = New-HttpError $Status
        Mock Invoke-RestMethod { throw $script:err }
        { Invoke-AdoRequest -Method $Method -Uri $script:Uri -Body '[]' -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'still retries <Method> on HTTP 429 (rejected before processing)' -TestCases @(
        @{ Method = 'POST' }
        @{ Method = 'PATCH' }
    ) {
        param($Method)
        $script:err = New-HttpError 429
        Mock Invoke-RestMethod { throw $script:err }
        { Invoke-AdoRequest -Method $Method -Uri $script:Uri -Body '[]' -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'honours Retry-After on 429' {
        $script:err = New-HttpError 429 '7'
        Mock Invoke-RestMethod { throw $script:err }
        { Invoke-AdoRequest -Method POST -Uri $script:Uri -Body '[]' -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 7 } -Times 3 -Exactly
    }

    It 'retries a POST on timeout when -RetryNonIdempotent is set' {
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('The operation has timed out') }
        { Invoke-AdoRequest -Method POST -Uri $script:Uri -Body '{}' -Headers $script:FakeHeaders -RetryNonIdempotent } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'still retries <Method> on a timeout' -TestCases @(
        @{ Method = 'PUT' }
        @{ Method = 'DELETE' }
    ) {
        param($Method)
        Mock Invoke-RestMethod { throw [System.Net.WebException]::new('The operation has timed out') }
        { Invoke-AdoRequest -Method $Method -Uri $script:Uri -Headers $script:FakeHeaders } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'read-only POST callers opt in to retries' {
        Mock Invoke-AdoRequest { [pscustomobject]@{ workItems = @() } }
        Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' -IdsOnly | Out-Null
        Should -Invoke Invoke-AdoRequest -Times 1 -Exactly -ParameterFilter { $RetryNonIdempotent }
    }
}
