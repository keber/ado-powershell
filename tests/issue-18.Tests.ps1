#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Tests for issue #18: read/write credential split, Bearer token support and
# Conditional Access (VS403463) diagnostics. No network access: all HTTP calls are mocked.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    . (Join-Path $script:ScriptsDir 'ado-testing.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pipelines.ps1')

    $script:EnvNames = 'ADO_ORG', 'ADO_PROJECT', 'ADO_API_VER', 'ADO_PAT', 'AZURE_DEVOPS_EXT_PAT',
                       'ADO_PAT_READ', 'ADO_PAT_WRITE', 'ADO_PROJECT_READ', 'ADO_PROJECT_WRITE',
                       'SYSTEM_ACCESSTOKEN', 'ADO_ACCESS'
    $script:SavedEnv = @{}
    foreach ($n in $script:EnvNames) {
        $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }

    function script:Clear-AdoTestEnv {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }

    function script:ConvertTo-Basic([string]$Pat) {
        'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    }

    function script:New-FakeSession([string]$Access) {
        $s = [pscustomobject]@{
            Org     = 'fakeorg'
            Project = 'fakeproj'
            ApiV    = '7.1'
            BaseUrl = 'https://dev.azure.com/fakeorg'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' }
        }
        if ($Access) { $s | Add-Member -NotePropertyName Access -NotePropertyValue $Access }
        $s
    }

    # Builds the error record Invoke-RestMethod / Invoke-WebRequest throw for an HTTP error.
    function script:New-HttpError([int]$Status, [hashtable]$Headers = @{}, [string]$Body = $null) {
        $ex   = [System.Exception]::new("The remote server returned an error: ($Status).")
        $resp = [pscustomobject]@{ StatusCode = $Status; Headers = $Headers }
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
        $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        if ($Body) { $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
        $er
    }

    $script:CaMessage = 'VS403463: The conditional access policy defined by your Azure Active Directory administrator has failed.'
}

AfterAll {
    foreach ($n in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n], 'Process')
    }
}

Describe 'Issue 18 - Read/Write credential resolution' {
    BeforeEach {
        Clear-AdoTestEnv
        $env:ADO_ORG = 'myorg'
    }

    It 'without -Access keeps the legacy behaviour (ADO_PAT / ADO_PROJECT, Write session)' {
        $env:ADO_PAT     = 'legacy-pat'
        $env:ADO_PROJECT = 'LegacyProj'
        $s = Initialize-AdoSession
        $s.Access                | Should -Be 'Write'
        $s.Project               | Should -Be 'LegacyProj'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It 'without -Access still honours AZURE_DEVOPS_EXT_PAT' {
        $env:AZURE_DEVOPS_EXT_PAT = 'ext-pat'
        $env:ADO_PROJECT          = 'P'
        (Initialize-AdoSession).Headers.Authorization | Should -Be (ConvertTo-Basic 'ext-pat')
    }

    It '-Access Read prefers ADO_PAT_READ and ADO_PROJECT_READ' {
        $env:ADO_PAT          = 'legacy-pat'
        $env:ADO_PAT_READ     = 'read-pat'
        $env:ADO_PAT_WRITE    = 'write-pat'
        $env:ADO_PROJECT      = 'LegacyProj'
        $env:ADO_PROJECT_READ = 'ReadProj'
        $s = Initialize-AdoSession -Access Read
        $s.Access                | Should -Be 'Read'
        $s.Project               | Should -Be 'ReadProj'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'read-pat')
    }

    It '-Access Write prefers ADO_PAT_WRITE and ADO_PROJECT_WRITE and ignores the READ pair' {
        $env:ADO_PAT           = 'legacy-pat'
        $env:ADO_PAT_READ      = 'read-pat'
        $env:ADO_PAT_WRITE     = 'write-pat'
        $env:ADO_PROJECT_READ  = 'ReadProj'
        $env:ADO_PROJECT_WRITE = 'WriteProj'
        $s = Initialize-AdoSession -Access Write
        $s.Access                | Should -Be 'Write'
        $s.Project               | Should -Be 'WriteProj'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'write-pat')
    }

    It '-Access Read falls back to ADO_PAT / ADO_PROJECT' {
        $env:ADO_PAT     = 'legacy-pat'
        $env:ADO_PROJECT = 'LegacyProj'
        $s = Initialize-AdoSession -Access Read
        $s.Access                | Should -Be 'Read'
        $s.Project               | Should -Be 'LegacyProj'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It '-Access Read falls back to AZURE_DEVOPS_EXT_PAT last' {
        $env:AZURE_DEVOPS_EXT_PAT = 'ext-pat'
        $env:ADO_PROJECT          = 'P'
        (Initialize-AdoSession -Access Read).Headers.Authorization | Should -Be (ConvertTo-Basic 'ext-pat')
    }

    It '-Access Read never picks up ADO_PAT_WRITE' {
        $env:ADO_PAT_WRITE = 'write-pat'
        $env:ADO_PROJECT   = 'P'
        { Initialize-AdoSession -Access Read } | Should -Throw '*ADO_PAT_READ*'
    }

    It 'explicit -Pat and -Project win over the access-specific variables' {
        $env:ADO_PAT_READ     = 'read-pat'
        $env:ADO_PROJECT_READ = 'ReadProj'
        $s = Initialize-AdoSession -Access Read -Pat 'explicit-pat' -Project 'ExplicitProj'
        $s.Project               | Should -Be 'ExplicitProj'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'explicit-pat')
    }

    It 'rejects an unknown -Access value' {
        $env:ADO_PAT = 'x'; $env:ADO_PROJECT = 'P'
        { Initialize-AdoSession -Access Admin } | Should -Throw
    }

    It 'Resolve-AdoConfig reports the Access it resolved for' {
        $env:ADO_PAT_READ = 'read-pat'; $env:ADO_PROJECT = 'P'
        (Resolve-AdoConfig -Access Read).Access | Should -Be 'Read'
    }

    It 'names the missing variables for the requested access and never prints a secret' {
        $env:ADO_PAT_READ = 'SUPER-SECRET-VALUE'
        $err = $null
        try { Initialize-AdoSession -Access Write } catch { $err = "$_" }
        $err | Should -Match 'ADO_PAT_WRITE'
        $err | Should -Match 'ADO_PROJECT_WRITE'
        $err | Should -Not -Match 'SUPER-SECRET-VALUE'
    }

    It 'does not store the raw secret on the session object' {
        $env:ADO_PAT = 'legacy-pat'; $env:ADO_PROJECT = 'P'
        $s = Initialize-AdoSession -Access Read
        $s.PSObject.Properties.Name | Should -Not -Contain 'Pat'
        $s.PSObject.Properties.Name | Should -Not -Contain 'Token'
        ($s | ConvertTo-Json -Depth 4) | Should -Not -Match 'legacy-pat'
    }
}

Describe 'Issue 18 - Write refusal on a Read session' {
    BeforeEach {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1; value = @(); workItems = @() } }
        Mock Write-Host { }
        $script:AdoSession = New-FakeSession -Access 'Read'
    }
    AfterAll {
        $script:AdoSession = $null
    }

    It 'New-AdoWorkItem (POST) is refused with ErrorId AdoReadOnlySession and sends nothing' {
        $err = $null
        try { New-AdoWorkItem -Type Task -Title 't' -Confirm:$false } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.FullyQualifiedErrorId | Should -Match 'AdoReadOnlySession'
        "$err" | Should -Match 'Read'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Update-AdoWorkItem (PATCH) is refused' {
        { Update-AdoWorkItem -Id 1 -Title 't' -Confirm:$false } | Should -Throw '*Read*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Remove-AdoTestCaseFromSuite (DELETE) is refused' {
        { Remove-AdoTestCaseFromSuite -PlanId 1 -SuiteId 2 -TestCaseId 3 -Confirm:$false } | Should -Throw '*Read*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Invoke-AdoPipelineRun (POST) is refused' {
        { Invoke-AdoPipelineRun -PipelineId 7 -Confirm:$false } | Should -Throw '*Read*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Add-AdoWorkItemAttachment refuses before uploading the file' {
        $f = Join-Path $TestDrive 'a.txt'
        Set-Content -LiteralPath $f -Value 'x'
        { Add-AdoWorkItemAttachment -Id 1 -FilePath $f -Confirm:$false } | Should -Throw '*Read*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Invoke-AdoRequest refuses a raw POST on a Read session' {
        { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Body '{}' } |
            Should -Throw '*Read*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'Invoke-AdoRequest -ReadOnly allows a read-only POST on a Read session' {
        Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/fakeorg/_apis/x' -Body '{}' -ReadOnly | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'Invoke-AdoWiql (read-only POST) keeps working on a Read session' {
        { Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'Get-AdoWorkItemsBatch (read-only POST) keeps working on a Read session' {
        { Get-AdoWorkItemsBatch -Ids 1, 2 } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'GET functions keep working on a Read session' {
        { Get-AdoWorkItem -Id 1 } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It '-WhatIf on a Read session sends nothing and does not throw' {
        { New-AdoWorkItem -Type Task -Title 't' -WhatIf } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'a Write session can write' {
        $script:AdoSession = New-FakeSession -Access 'Write'
        New-AdoWorkItem -Type Task -Title 't' -Confirm:$false | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'a legacy session object without Access can still write (backward compatibility)' {
        $script:AdoSession = New-FakeSession
        New-AdoWorkItem -Type Task -Title 't' -Confirm:$false | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'no session at all does not block writes made with explicit headers' {
        $script:AdoSession = $null
        Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/o/_apis/x' -Body '{}' `
            -Headers @{ Authorization = 'Basic eA==' } | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
}

Describe 'Issue 18 - Bearer token support' {
    BeforeEach {
        Clear-AdoTestEnv
        $env:ADO_ORG = 'myorg'; $env:ADO_PROJECT = 'P'
    }

    It 'New-AdoHeaders -Token builds a Bearer header' {
        (New-AdoHeaders -Token 'tok-123').Authorization | Should -Be 'Bearer tok-123'
    }

    It 'New-AdoHeaders uses SYSTEM_ACCESSTOKEN as Bearer when no PAT is set' {
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        (New-AdoHeaders).Authorization | Should -Be 'Bearer sys-tok'
    }

    It 'a PAT variable takes precedence over SYSTEM_ACCESSTOKEN (backward compatibility)' {
        $env:ADO_PAT            = 'legacy-pat'
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        (New-AdoHeaders).Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It 'New-AdoHeaders -Bearer forces SYSTEM_ACCESSTOKEN even when ADO_PAT is set' {
        $env:ADO_PAT            = 'legacy-pat'
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        (New-AdoHeaders -Bearer).Authorization | Should -Be 'Bearer sys-tok'
    }

    It 'New-AdoHeaders -Bearer without SYSTEM_ACCESSTOKEN names the variable only' {
        $env:ADO_PAT = 'SUPER-SECRET-VALUE'
        $err = $null
        try { New-AdoHeaders -Bearer } catch { $err = "$_" }
        $err | Should -Match 'SYSTEM_ACCESSTOKEN'
        $err | Should -Not -Match 'SUPER-SECRET-VALUE'
    }

    It 'New-AdoHeaders rejects -Pat together with -Token' {
        { New-AdoHeaders -Pat 'a' -Token 'b' } | Should -Throw
    }

    It 'New-AdoHeaders without any credential names every variable it looked at' {
        $err = $null
        try { New-AdoHeaders } catch { $err = "$_" }
        $err | Should -Match 'ADO_PAT'
        $err | Should -Match 'AZURE_DEVOPS_EXT_PAT'
        $err | Should -Match 'SYSTEM_ACCESSTOKEN'
    }

    It 'Initialize-AdoSession -Token builds a Bearer session' {
        $env:ADO_PAT = 'legacy-pat'
        $s = Initialize-AdoSession -Token 'entra-tok'
        $s.Headers.Authorization | Should -Be 'Bearer entra-tok'
        $s.AuthScheme            | Should -Be 'Bearer'
    }

    It 'Initialize-AdoSession uses SYSTEM_ACCESSTOKEN when no PAT is available' {
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        $s = Initialize-AdoSession
        $s.Headers.Authorization | Should -Be 'Bearer sys-tok'
        $s.AuthScheme            | Should -Be 'Bearer'
    }

    It 'Initialize-AdoSession -Bearer prefers SYSTEM_ACCESSTOKEN over ADO_PAT' {
        $env:ADO_PAT            = 'legacy-pat'
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        (Initialize-AdoSession -Bearer).Headers.Authorization | Should -Be 'Bearer sys-tok'
    }

    It 'an access-specific PAT wins over SYSTEM_ACCESSTOKEN' {
        $env:ADO_PAT_READ       = 'read-pat'
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        $s = Initialize-AdoSession -Access Read
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'read-pat')
        $s.AuthScheme            | Should -Be 'Basic'
    }

    It 'a PAT session records AuthScheme Basic' {
        $env:ADO_PAT = 'legacy-pat'
        (Initialize-AdoSession).AuthScheme | Should -Be 'Basic'
    }

    It 'Initialize-AdoSession rejects -Pat together with -Token' {
        { Initialize-AdoSession -Pat 'a' -Token 'b' } | Should -Throw
    }
}

Describe 'Issue 18 - Conditional Access (VS403463) diagnostics' {
    BeforeAll {
        Mock Start-Sleep { }
        $script:AdoSession = New-FakeSession -Access 'Write'
        $script:CaUri = 'https://dev.azure.com/fakeorg/fakeproj/_apis/wit/workitems/1?api-version=7.1'
        $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    AfterAll { $script:AdoSession = $null }

    It 'Invoke-AdoRequest detects VS403463 in the X-TFS-ServiceError header and does not retry' {
        Mock Invoke-RestMethod {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = [uri]::EscapeDataString($script:CaMessage) })
        }
        $err = $null
        try { Invoke-AdoGet -Uri $script:CaUri -Headers $script:FakeHeaders } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
        "$err" | Should -Match 'VS403463'
        "$err" | Should -Match 'Conditional Access'
        "$err" | Should -Match 'regenerat'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'Invoke-AdoRequest detects VS403463 in the response body (ErrorDetails)' {
        Mock Invoke-RestMethod {
            throw (New-HttpError -Status 403 -Body ('{"message":"' + $script:CaMessage + '"}'))
        }
        $err = $null
        try { Invoke-AdoGet -Uri $script:CaUri -Headers $script:FakeHeaders } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
    }

    It 'Invoke-AdoRequest detects VS403463 on a header collection exposing GetValues (PowerShell 7 shape)' {
        Mock Invoke-RestMethod {
            $h = [pscustomobject]@{}
            $h | Add-Member -MemberType ScriptMethod -Name GetValues -Value {
                param($name)
                if ($name -eq 'X-TFS-ServiceError') { , @('VS403463%3A%20conditional%20access') } else { throw 'absent' }
            }
            $ex   = [System.Exception]::new('401')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401; Headers = $h })
            throw ([System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null))
        }
        $err = $null
        try { Invoke-AdoGet -Uri $script:CaUri -Headers $script:FakeHeaders } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
    }

    It 'a plain 401 keeps the existing message' {
        Mock Invoke-RestMethod { throw (New-HttpError -Status 401) }
        { Invoke-AdoGet -Uri $script:CaUri -Headers $script:FakeHeaders } | Should -Throw '401 Unauthorized*'
    }

    It 'a POST rejected by Conditional Access is reported the same way' {
        Mock Invoke-RestMethod {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = $script:CaMessage })
        }
        $err = $null
        try { Invoke-AdoRequest -Method POST -Uri $script:CaUri -Body '{}' -Headers $script:FakeHeaders } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
    }

    It 'Invoke-AdoGetPaged detects VS403463 and does not retry' {
        Mock Invoke-WebRequest {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = [uri]::EscapeDataString($script:CaMessage) })
        }
        $err = $null
        try { Invoke-AdoGetPaged -Uri $script:CaUri -Headers @{ Authorization = 'Basic eA==' } } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'the Conditional Access message never echoes the Authorization header' {
        Mock Invoke-RestMethod {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = $script:CaMessage })
        }
        $err = $null
        try { Invoke-AdoGet -Uri $script:CaUri -Headers @{ Authorization = 'Basic U0VDUkVULVRPS0VO' } } catch { $err = "$_" }
        $err | Should -Not -Match 'U0VDUkVULVRPS0VO'
    }
}

Describe 'Issue 18 - load.ps1 auto-initialisation' {
    BeforeEach {
        Clear-AdoTestEnv
        $env:ADO_ORG = 'myorg'; $env:ADO_PROJECT = 'P'
        Mock Write-Host { }
    }

    It 'auto-initialises a Read session when only ADO_PAT_READ is set' {
        $env:ADO_PAT_READ = 'read-pat'
        . (Join-Path $script:SkillRoot 'load.ps1')
        $AdoSession.Access                | Should -Be 'Read'
        $AdoSession.Headers.Authorization | Should -Be (ConvertTo-Basic 'read-pat')
    }

    It 'auto-initialises a Write session from legacy ADO_PAT (unchanged behaviour)' {
        $env:ADO_PAT = 'legacy-pat'
        . (Join-Path $script:SkillRoot 'load.ps1')
        $AdoSession.Access                | Should -Be 'Write'
        $AdoSession.Headers.Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It 'honours ADO_ACCESS=Read' {
        $env:ADO_PAT    = 'legacy-pat'
        $env:ADO_ACCESS = 'Read'
        . (Join-Path $script:SkillRoot 'load.ps1')
        $AdoSession.Access | Should -Be 'Read'
    }

    It 'auto-initialises a Bearer session from SYSTEM_ACCESSTOKEN' {
        $env:SYSTEM_ACCESSTOKEN = 'sys-tok'
        . (Join-Path $script:SkillRoot 'load.ps1')
        $AdoSession.Headers.Authorization | Should -Be 'Bearer sys-tok'
    }
}

Describe 'Issue 18 - Review follow-ups (V18-001..004)' {
    BeforeEach {
        Clear-AdoTestEnv
        $env:ADO_ORG = 'myorg'; $env:ADO_PROJECT = 'P'
        Mock Start-Sleep { }
        Mock Write-Host { }
    }
    AfterEach { $script:AdoSession = $null }

    It 'V18-001 Invoke-AdoRequest without -Headers uses the session headers, not env vars' {
        $env:ADO_PAT_READ = 'read-pat'; $env:ADO_PAT = 'broad-pat'
        $script:AdoSession = Initialize-AdoSession -Access Read
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1 } }
        Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/myorg/_apis/projects' | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers.Authorization -eq (ConvertTo-Basic 'read-pat') }
    }

    It 'V18-001 Invoke-AdoGetPaged without -Headers uses the session headers' {
        $env:ADO_PAT_READ = 'read-pat'; $env:ADO_PAT = 'broad-pat'
        $script:AdoSession = Initialize-AdoSession -Access Read
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"value":[1]}'; Headers = @{} } }
        @(Invoke-AdoGetPaged -Uri 'https://dev.azure.com/myorg/_apis/x').Count | Should -Be 1
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Headers.Authorization -eq (ConvertTo-Basic 'read-pat') }
    }

    It 'V18-001 Invoke-AdoDownload without -Headers uses the session headers' {
        $env:ADO_PAT_READ = 'read-pat'; $env:ADO_PAT = 'broad-pat'
        $script:AdoSession = Initialize-AdoSession -Access Read
        Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ 'Content-Type' = 'image/png' } } }
        Invoke-AdoDownload -Uri 'https://dev.azure.com/myorg/_apis/wit/attachments/1' -OutFile (Join-Path $TestDrive 'f.png')
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Headers.Authorization -eq (ConvertTo-Basic 'read-pat') }
    }

    It 'V18-001 without a session the env-var headers are still used (backward compatibility)' {
        $env:ADO_PAT = 'legacy-pat'
        $script:AdoSession = $null
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1 } }
        Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/myorg/_apis/projects' | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Headers.Authorization -eq (ConvertTo-Basic 'legacy-pat') }
    }

    It 'V18-002 a malformed config file is reported by path without echoing its content' {
        $p = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $p -Value '{ "org": "o", "pat": "FILE-SECRET-PAT" '
        $env:ADO_PAT = 'legacy-pat'
        # Resolve-AdoConfig is not an advanced function: capture the warning stream by redirection.
        $w = @(Resolve-AdoConfig -ConfigPath $p 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $w.Count | Should -Be 1
        "$w" | Should -Match ([regex]::Escape($p))
        "$w" | Should -Not -Match 'FILE-SECRET-PAT'
    }

    It 'V18-003 a whitespace-only -Token is treated as absent (scheme matches header)' {
        $env:ADO_PAT = 'legacy-pat'
        $s = Initialize-AdoSession -Token '   '
        $s.AuthScheme            | Should -Be 'Basic'
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It 'V18-003 a whitespace-only -Pat with -Token is not reported as ambiguous' {
        $s = Initialize-AdoSession -Pat ' ' -Token 'tok'
        $s.AuthScheme            | Should -Be 'Bearer'
        $s.Headers.Authorization | Should -Be 'Bearer tok'
    }

    It 'V18-003 whitespace-only env PAT is skipped in favour of the next source' {
        $env:ADO_PAT_READ = '  '; $env:ADO_PAT = 'legacy-pat'
        $s = Initialize-AdoSession -Access Read
        $s.Headers.Authorization | Should -Be (ConvertTo-Basic 'legacy-pat')
    }

    It 'V18-004 Invoke-AdoDownload maps VS403463 to AdoConditionalAccess' {
        Mock Invoke-WebRequest {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = $script:CaMessage })
        }
        $err = $null
        try {
            Invoke-AdoDownload -Uri 'https://dev.azure.com/myorg/_apis/wit/attachments/1' `
                -OutFile (Join-Path $TestDrive 'g.png') -Headers @{ Authorization = 'Basic eA==' }
        } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
    }

    It 'V18-004 the attachment upload maps VS403463 to AdoConditionalAccess' {
        $script:AdoSession = New-FakeSession -Access 'Write'
        Mock Invoke-RestMethod {
            throw (New-HttpError -Status 401 -Headers @{ 'X-TFS-ServiceError' = $script:CaMessage })
        }
        $f = Join-Path $TestDrive 'up.txt'; Set-Content -LiteralPath $f -Value 'x'
        $err = $null
        try { Add-AdoWorkItemAttachment -Id 1 -FilePath $f -Confirm:$false } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
}
