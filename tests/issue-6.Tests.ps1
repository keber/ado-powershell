#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #6 (shipped config template baseUrl lacks the organization).
# No network access: all HTTP calls are mocked.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    . (Join-Path $scriptsDir 'ado-base.ps1')

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

Describe 'H4 - Shipped config template baseUrl' {
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }

    It 'config-file baseUrl without org still yields org in the base URL' {
        $template = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\references\config.json'
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ado-h4-{0}.json" -f [guid]::NewGuid())
        try {
            Copy-Item $template $tmp
            $cfg = Resolve-AdoConfig -ConfigPath $tmp -Pat 'fake-pat'
            $cfg.Org | Should -Be 'ado-organization'
            $cfg.BaseUrl.TrimEnd('/') | Should -Be 'https://dev.azure.com/ado-organization'
        }
        finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'shipped template does not contain a pat key' {
        $template = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\references\config.json'
        $json = Get-Content $template -Raw | ConvertFrom-Json
        $json.PSObject.Properties.Name | Should -Not -Contain 'pat'
    }

    It 'bare host baseUrl "<url>" gets the org appended' -ForEach @(
        @{ url = 'https://dev.azure.com' }
        @{ url = 'https://dev.azure.com/' }
    ) {
        $p = Join-Path $TestDrive 'bare.json'
        (@{ org = 'myorg'; project = 'p'; baseUrl = $url } | ConvertTo-Json) | Set-Content $p
        (Resolve-AdoConfig -ConfigPath $p -Pat 'x').BaseUrl | Should -Be 'https://dev.azure.com/myorg'
    }

    It 'full baseUrl is kept and trailing slash trimmed' {
        $p = Join-Path $TestDrive 'full.json'
        (@{ org = 'myorg'; project = 'p'; baseUrl = 'https://tfs.contoso.com/tfs/Coll/' } | ConvertTo-Json) | Set-Content $p
        (Resolve-AdoConfig -ConfigPath $p -Pat 'x').BaseUrl | Should -Be 'https://tfs.contoso.com/tfs/Coll'
    }
}
