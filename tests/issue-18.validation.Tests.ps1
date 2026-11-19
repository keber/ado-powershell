#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Independent validation tests for issue #18 (credential model): back-compat, read/write
# resolution, write refusal on a Read session, Bearer, VS403463 and secret hygiene.
# No external network: HTTP is mocked, or answered by a local HttpListener on 127.0.0.1 to get
# the real Windows PowerShell 5.1 error shapes (WebException / HttpWebResponse).

BeforeDiscovery {
    $CaHeader = 'VS403463%3a+The+conditional+access+policy+defined+by+your+Azure+Active+Directory+administrator+has+failed.'
    $CaBody   = '{"$id":"1","message":"VS403463: The conditional access policy defined by your Azure Active Directory administrator has failed.","typeKey":"UnauthorizedRequestException","errorCode":0}'
    $skillScripts = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base', 'ado-workitems', 'ado-testing', 'ado-pipelines', 'ado-git', 'ado-content') {
        . (Join-Path $skillScripts "$f.ps1")
    }
    # Every SupportsShouldProcess function of the skill, except Save-AdoInlineImage (it only writes
    # local files and downloads with GET, so it is a read against Azure DevOps).
    $WriteFunctionCases = @(
        Get-Command -CommandType Function |
            Where-Object { $_.ScriptBlock.File -and $_.ScriptBlock.File -like '*ado-powershell*scripts*' -and
                           $_.Parameters.ContainsKey('WhatIf') -and $_.Name -ne 'Save-AdoInlineImage' } |
            Sort-Object Name |
            ForEach-Object { @{ Name = $_.Name } }
    )
}

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    foreach ($f in 'ado-base', 'ado-workitems', 'ado-testing', 'ado-pipelines', 'ado-git', 'ado-content') {
        . (Join-Path $script:ScriptsDir "$f.ps1")
    }

    $script:EnvNames = 'ADO_ORG', 'ADO_PROJECT', 'ADO_API_VER', 'ADO_PAT', 'AZURE_DEVOPS_EXT_PAT',
                       'ADO_PAT_READ', 'ADO_PAT_WRITE', 'ADO_PROJECT_READ', 'ADO_PROJECT_WRITE',
                       'SYSTEM_ACCESSTOKEN', 'ADO_ACCESS'
    $script:SavedEnv = @{}
    foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

    function script:Clear-ValEnv { foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } }
    function script:Restore-ValEnv { foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n], 'Process') } }
    function script:Basic([string]$Pat) { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat")) }

    function script:New-ValSession([string]$Access) {
        $s = [pscustomobject]@{
            Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/fakeorg'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' }
        }
        if ($Access) { $s | Add-Member -NotePropertyName Access -NotePropertyValue $Access }
        $s
    }

    # Builds dummy arguments for a function's mandatory parameters.
    function script:New-DummyArgs([string]$Name, [string]$TempFile) {
        $cmd = Get-Command $Name
        $a   = @{}
        $set = $cmd.ParameterSets | Select-Object -First 1
        foreach ($p in ($set.Parameters | Where-Object IsMandatory)) {
            $vs = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
            $a[$p.Name] = if ($vs) { $vs.ValidValues[0] }
                          elseif ($p.Name -eq 'FilePath') { $TempFile }
                          elseif ($p.ParameterType -eq [int]) { 1 }
                          elseif ($p.ParameterType -eq [int[]]) { @(1) }
                          elseif ($p.ParameterType -eq [hashtable[]]) { @(@{ id = 1; outcome = 'Passed' }) }
                          elseif ($p.ParameterType -eq [hashtable]) { @{ a = 1 } }
                          else { 'x' }
        }
        # Update-AdoWorkItem with no field returns early without a request; give it one field.
        if ($Name -eq 'Update-AdoWorkItem') { $a['Title'] = 't' }
        if ($cmd.Parameters.ContainsKey('Confirm')) { $a['Confirm'] = $false }
        $a
    }

    # Local HttpListener on 127.0.0.1 that answers every request with the same canned response.
    function script:Start-LocalHttp([int]$Status, [hashtable]$ExtraHeaders = @{}, [string]$Body = '') {
        $port = Get-Random -Minimum 20000 -Maximum 40000
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://127.0.0.1:$port/")
        $l.Start()
        $state = [hashtable]::Synchronized(@{ Count = 0; Auth = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($l, $status, $hdrs, $body, $state)
            while ($l.IsListening) {
                try { $ctx = $l.GetContext() } catch { break }
                $state.Count++
                [void]$state.Auth.Add([string]$ctx.Request.Headers['Authorization'])
                $ctx.Response.StatusCode = $status
                foreach ($k in $hdrs.Keys) { $ctx.Response.Headers.Add($k, $hdrs[$k]) }
                $ctx.Response.ContentType = 'application/json; charset=utf-8'
                $b = [Text.Encoding]::UTF8.GetBytes($body)
                $ctx.Response.ContentLength64 = $b.Length
                if ($b.Length) { $ctx.Response.OutputStream.Write($b, 0, $b.Length) }
                $ctx.Response.Close()
            }
        }).AddArgument($l).AddArgument($Status).AddArgument($ExtraHeaders).AddArgument($Body).AddArgument($state)
        $h = $ps.BeginInvoke()
        [pscustomobject]@{ L = $l; PS = $ps; H = $h; State = $state; Base = "http://127.0.0.1:$port" }
    }
    function script:Stop-LocalHttp($srv) {
        try { $srv.L.Stop(); $srv.L.Close() } catch { }
        try { [void]$srv.PS.EndInvoke($srv.H) } catch { }
        $srv.PS.Dispose()
    }

    # Runs a script in a fresh powershell.exe (-File) with a controlled environment.
    function script:Invoke-Fresh([hashtable]$Env, [string]$Script) {
        $saved = @{}
        foreach ($n in $script:EnvNames) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process'); [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
        try {
            foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
            $load = Join-Path $script:SkillRoot 'load.ps1'
            $file = Join-Path $TestDrive ("fresh-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $file -Encoding UTF8 -Value ". '$load' *>&1 | ForEach-Object { `"OUT: `$_`" }`n$Script"
            (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | Out-String)
        } finally {
            foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
        }
    }

    $script:SecretPat   = 'VALSECRETPAT0123456789abcdef'
    $script:SecretWrite = 'VALWRITEPAT9876543210zyxwvu'
    $script:SecretTok   = 'VALSECRETTOKEN.eyJhbGciOi.signature'
    $script:CaHeader    = 'VS403463%3a+The+conditional+access+policy+defined+by+your+Azure+Active+Directory+administrator+has+failed.'
}

AfterAll {
    Restore-ValEnv
    $script:AdoSession = $null
}

Describe 'V18 backward compatibility' {
    BeforeEach { Clear-ValEnv; $env:ADO_ORG = 'myorg'; $script:AdoSession = $null }
    AfterAll  { Restore-ValEnv }

    It 'only ADO_PAT + ADO_PROJECT: Write session, Basic header, legacy project' {
        $env:ADO_PAT = 'p1'; $env:ADO_PROJECT = 'Legacy'
        $s = Initialize-AdoSession
        $s.Access | Should -Be 'Write'; $s.AuthScheme | Should -Be 'Basic'
        $s.Project | Should -Be 'Legacy'; $s.Headers.Authorization | Should -Be (Basic 'p1')
    }

    It 'only AZURE_DEVOPS_EXT_PAT: Write session with that PAT' {
        $env:AZURE_DEVOPS_EXT_PAT = 'ext'; $env:ADO_PROJECT = 'P'
        (Initialize-AdoSession).Headers.Authorization | Should -Be (Basic 'ext')
    }

    It 'ADO_PAT wins over AZURE_DEVOPS_EXT_PAT (unchanged order)' {
        $env:ADO_PAT = 'p1'; $env:AZURE_DEVOPS_EXT_PAT = 'ext'; $env:ADO_PROJECT = 'P'
        (Initialize-AdoSession).Headers.Authorization | Should -Be (Basic 'p1')
    }

    It 'config file supplies org/project; legacy pat key is still honoured' {
        Clear-ValEnv
        $cfg = Join-Path $TestDrive 'cfg.json'
        '{ "org": "cfgorg", "project": "cfgproj", "apiVersion": "7.0", "pat": "cfgpat" }' | Set-Content -LiteralPath $cfg
        $s = Initialize-AdoSession -ConfigPath $cfg
        $s.Org | Should -Be 'cfgorg'; $s.Project | Should -Be 'cfgproj'; $s.ApiV | Should -Be '7.0'
        $s.Headers.Authorization | Should -Be (Basic 'cfgpat')
        $s.Access | Should -Be 'Write'
    }

    It 'config file without pat + ADO_PAT env works' {
        Clear-ValEnv; $env:ADO_PAT = 'envpat'
        $cfg = Join-Path $TestDrive 'cfg2.json'
        '{ "org": "o", "project": "p", "apiVersion": "", "baseUrl": "" }' | Set-Content -LiteralPath $cfg
        (Initialize-AdoSession -ConfigPath $cfg).Headers.Authorization | Should -Be (Basic 'envpat')
    }

    It 'New-AdoHeaders with no arguments still returns Basic from ADO_PAT' {
        $env:ADO_PAT = 'p1'
        (New-AdoHeaders).Authorization | Should -Be (Basic 'p1')
    }

    It 'New-AdoHeaders -Pat explicit wins over SYSTEM_ACCESSTOKEN' {
        $env:SYSTEM_ACCESSTOKEN = 'sys'
        (New-AdoHeaders -Pat 'x').Authorization | Should -Be (Basic 'x')
    }

    It 'a legacy session (no Access) still writes' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 5 } }
        Mock Write-Host { }
        $script:AdoSession = New-ValSession
        (New-AdoWorkItem -Type Task -Title 't' -Confirm:$false).id | Should -Be 5
    }
}

Describe 'V18 load.ps1 auto-init in a fresh process' {
    It 'legacy ADO_PAT/ADO_PROJECT/ADO_ORG: Write/Basic session, no secret in output' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT = $script:SecretPat } '"ACCESS=$($AdoSession.Access) SCHEME=$($AdoSession.AuthScheme) AUTHOK=$($AdoSession.Headers.Authorization -like ''Basic *'')"'
        $o | Should -Match 'ACCESS=Write SCHEME=Basic AUTHOK=True'
        $o | Should -Not -Match $script:SecretPat
    }

    It 'only AZURE_DEVOPS_EXT_PAT: auto-initialises (unchanged)' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; AZURE_DEVOPS_EXT_PAT = $script:SecretPat } '"ACCESS=$($AdoSession.Access)"'
        $o | Should -Match 'ACCESS=Write'
    }

    It 'no credential at all: no session, names missing vars only' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o' } '"HASSESSION=$([bool](Get-Variable AdoSession -ErrorAction SilentlyContinue))"'
        $o | Should -Match 'Missing env vars'
        $o | Should -Match 'HASSESSION=False'
    }

    It 'does not leak helper variables into the caller scope' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT = 'x' } '"LEAK=$(@(Get-Variable adoLoad* -ErrorAction SilentlyContinue).Count)"'
        $o | Should -Match 'LEAK=0'
    }

    It 'only ADO_PAT_READ: Read session and writes are refused end-to-end' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT_READ = $script:SecretPat } @'
"ACCESS=$($AdoSession.Access)"
try { New-AdoWorkItem -Type Task -Title t -Confirm:$false; 'WROTE' } catch { "ERRID=$($_.FullyQualifiedErrorId)" }
'@
        $o | Should -Match 'ACCESS=Read'
        $o | Should -Match 'ERRID=AdoReadOnlySession'
        $o | Should -Not -Match $script:SecretPat
    }

    It 'ADO_ACCESS=Write with only ADO_PAT_READ: init fails without printing the read PAT' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT_READ = $script:SecretPat; ADO_ACCESS = 'Write' } '"DONE"'
        $o | Should -Match 'could not be initialised'
        $o | Should -Not -Match $script:SecretPat
    }

    It 'ADO_ACCESS invalid value is ignored with a warning' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT = 'x'; ADO_ACCESS = 'Admin' } '"ACCESS=$($AdoSession.Access)"'
        $o | Should -Match 'ADO_ACCESS must be Read or Write'
        $o | Should -Match 'ACCESS=Write'
    }

    It 'ADO_PAT_READ + ADO_PAT_WRITE without ADO_ACCESS: Write session using the WRITE PAT' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT_READ = 'r'; ADO_PAT_WRITE = 'w' } '"ACCESS=$($AdoSession.Access) H=$($AdoSession.Headers.Authorization)"'
        $o | Should -Match "ACCESS=Write H=$([regex]::Escape((Basic 'w')))"
    }

    It 'guard sees the session when the user script re-initialises Read at top level' {
        $o = Invoke-Fresh @{ ADO_ORG = 'o'; ADO_PROJECT = 'p'; ADO_PAT = 'x' } @'
$AdoSession = Initialize-AdoSession -Access Read
try { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/o/p/_apis/x' -Body '{}'; 'SENT' } catch { "ERRID=$($_.FullyQualifiedErrorId)" }
'@
        $o | Should -Match 'ERRID=AdoReadOnlySession'
    }
}

Describe 'V18 resolution order and fallback' {
    BeforeEach { Clear-ValEnv; $env:ADO_ORG = 'myorg'; $script:AdoSession = $null }
    AfterAll  { Restore-ValEnv; $script:AdoSession = $null }

    It 'Read: ADO_PAT_READ > ADO_PAT > AZURE_DEVOPS_EXT_PAT' {
        $env:ADO_PROJECT = 'P'
        $env:AZURE_DEVOPS_EXT_PAT = 'ext'
        (Resolve-AdoConfig -Access Read).Pat | Should -Be 'ext'
        $env:ADO_PAT = 'gen'
        (Resolve-AdoConfig -Access Read).Pat | Should -Be 'gen'
        $env:ADO_PAT_READ = 'rd'
        (Resolve-AdoConfig -Access Read).Pat | Should -Be 'rd'
    }

    It 'Write: ADO_PAT_WRITE > ADO_PAT, ignores ADO_PAT_READ' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT_READ = 'rd'; $env:ADO_PAT = 'gen'
        (Resolve-AdoConfig -Access Write).Pat | Should -Be 'gen'
        $env:ADO_PAT_WRITE = 'wr'
        (Resolve-AdoConfig -Access Write).Pat | Should -Be 'wr'
    }

    It 'Read never picks ADO_PAT_WRITE nor ADO_PROJECT_WRITE, even as the only values' {
        $env:ADO_PAT_WRITE = $script:SecretWrite; $env:ADO_PROJECT_WRITE = 'WP'
        $err = $null
        try { Resolve-AdoConfig -Access Read } catch { $err = $_ }
        "$err" | Should -Match 'ADO_PAT_READ'
        "$err" | Should -Match 'ADO_PROJECT_READ'
        "$err" | Should -Not -Match $script:SecretWrite
    }

    It 'Read with ADO_PAT_WRITE + SYSTEM_ACCESSTOKEN uses the pipeline token, not the WRITE PAT' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT_WRITE = 'wr'; $env:SYSTEM_ACCESSTOKEN = 'sys'
        $s = Initialize-AdoSession -Access Read
        $s.Headers.Authorization | Should -Be 'Bearer sys'
    }

    It 'Project: ADO_PROJECT_READ > ADO_PROJECT > config file, for Read' {
        $cfg = Join-Path $TestDrive 'c.json'
        '{ "org": "o", "project": "FileProj" }' | Set-Content -LiteralPath $cfg
        $env:ADO_PAT = 'x'
        (Resolve-AdoConfig -Access Read -ConfigPath $cfg).Project | Should -Be 'FileProj'
        $env:ADO_PROJECT = 'Gen'
        (Resolve-AdoConfig -Access Read -ConfigPath $cfg).Project | Should -Be 'Gen'
        $env:ADO_PROJECT_READ = 'Rd'
        (Resolve-AdoConfig -Access Read -ConfigPath $cfg).Project | Should -Be 'Rd'
    }

    It 'ADO_PAT_READ wins over a legacy config-file pat' {
        $cfg = Join-Path $TestDrive 'c2.json'
        '{ "org": "o", "project": "p", "pat": "filepat" }' | Set-Content -LiteralPath $cfg
        $env:ADO_PAT_READ = 'rd'
        (Resolve-AdoConfig -Access Read -ConfigPath $cfg).Pat | Should -Be 'rd'
    }

    It '-Access is case-insensitive and canonicalised' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT_READ = 'rd'
        $s = Initialize-AdoSession -Access read
        $s.Access | Should -BeExactly 'Read'
        $s.Headers.Authorization | Should -Be (Basic 'rd')
    }

    It 'session AuthScheme matches the header actually built (blank -Token)' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT = 'gen'
        $s = $null
        try { $s = Initialize-AdoSession -Token '   ' } catch { }
        if ($s) {
            # Either reject the blank token or keep scheme and header consistent.
            ($s.Headers.Authorization -split ' ')[0] | Should -Be $s.AuthScheme
        }
    }

    It 'Invoke-AdoGet without -Headers on a Read session built from ADO_PAT_READ uses the read PAT' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT_READ = 'rd'
        $script:AdoSession = Initialize-AdoSession -Access Read
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = 1 } }
        $null = Invoke-AdoGet -Uri 'https://dev.azure.com/myorg/_apis/projects'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq (Basic 'rd') }
    }

    It 'Invoke-AdoGet without -Headers on a Read session does not send the broader ADO_PAT' {
        $env:ADO_PROJECT = 'P'; $env:ADO_PAT_READ = 'rd'; $env:ADO_PAT = 'broad'
        $script:AdoSession = Initialize-AdoSession -Access Read
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = 1 } }
        $null = Invoke-AdoGet -Uri 'https://dev.azure.com/myorg/_apis/projects'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Headers.Authorization -eq (Basic 'broad') }
    }
}

Describe 'V18 write refusal on a Read session (all ShouldProcess functions)' {
    BeforeAll {
        $script:TmpFile = Join-Path $TestDrive 'up.txt'
        Set-Content -LiteralPath $script:TmpFile -Value 'x'
    }
    BeforeEach {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1; value = @(); workItems = @(); url = 'https://dev.azure.com/fakeorg/_apis/wit/attachments/1'; count = 0 } }
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"value":[]}'; Headers = @{}; StatusCode = 200 } }
        Mock Write-Host { }
        $script:AdoSession = New-ValSession -Access 'Read'
    }
    AfterAll { $script:AdoSession = $null }

    It 'at least the 14 known write functions are enumerated' {
        $WriteFunctionCases.Count | Should -BeGreaterOrEqual 14
    } -ForEach @(@{ WriteFunctionCases = $WriteFunctionCases })

    It '<Name> is refused with AdoReadOnlySession and sends no write' -ForEach $WriteFunctionCases {
        $a = New-DummyArgs -Name $Name -TempFile $script:TmpFile
        $err = $null
        try { & $Name @a | Out-Null } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty -Because "$Name must not succeed on a Read session"
        $err.FullyQualifiedErrorId | Should -Match 'AdoReadOnlySession'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -and "$Method" -notin 'Get', 'Default' }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -and "$Method" -notin 'Get', 'Default' }
    }

    It '<Name> still works on a Write session' -ForEach $WriteFunctionCases {
        $script:AdoSession = New-ValSession -Access 'Write'
        $a = New-DummyArgs -Name $Name -TempFile $script:TmpFile
        $err = $null
        try { & $Name @a | Out-Null } catch { $err = $_ }
        if ($err) { $err.FullyQualifiedErrorId | Should -Not -Match 'AdoReadOnlySession' }
    }

    It 'Invoke-AdoRequest refuses <_> on a Read session' -ForEach 'POST', 'PATCH', 'PUT', 'DELETE' {
        { Invoke-AdoRequest -Method $_ -Uri 'https://dev.azure.com/o/_apis/x' -Body '{}' -Headers @{ Authorization = 'Basic eA==' } } |
            Should -Throw -ErrorId 'AdoReadOnlySession'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'explicit -Headers do not bypass the Read guard' {
        { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/o/_apis/x' -Body '{}' -Headers (New-AdoHeaders -Pat 'other') } |
            Should -Throw -ErrorId 'AdoReadOnlySession'
    }

    It 'design note: the guard is ambient, headers of an earlier Write session are refused while the current session is Read' {
        $w = New-ValSession -Access 'Write'
        { New-AdoWorkItem -Type Task -Title t -Headers $w.Headers -Confirm:$false } | Should -Throw -ErrorId 'AdoReadOnlySession'
    }

    It 'GET via Invoke-AdoRequest / Invoke-AdoGetPaged / Invoke-AdoDownload is allowed on Read' {
        { Invoke-AdoRequest -Method GET -Uri 'https://dev.azure.com/o/_apis/x' -Headers @{ Authorization = 'x' } } | Should -Not -Throw
        { Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x' -Headers @{ Authorization = 'x' } } | Should -Not -Throw
        { Invoke-AdoDownload -Uri 'https://dev.azure.com/o/_apis/x' -OutFile (Join-Path $TestDrive 'd.bin') -Headers @{ Authorization = 'x' } } | Should -Not -Throw
    }

    It 'Invoke-AdoWiql and Get-AdoWorkItemsBatch (read-only POSTs) work on Read' {
        { Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' } | Should -Not -Throw
        { Get-AdoWorkItemsBatch -Ids 1, 2 } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { "$Method" -eq 'Post' }
    }

    It 'every non-GET HTTP call site outside a ShouldProcess function is declared -ReadOnly' {
        $offenders = @()
        foreach ($file in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $fns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($fn in $fns) {
                $ssp = $fn.Body.ParamBlock -and ($fn.Body.ParamBlock.Attributes | Where-Object {
                    $_.TypeName.Name -eq 'CmdletBinding' -and ($_.NamedArguments | Where-Object ArgumentName -eq 'SupportsShouldProcess') })
                $calls = $fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                                            $args[0].GetCommandName() -in 'Invoke-AdoRequest', 'Invoke-RestMethod', 'Invoke-WebRequest' }, $true)
                foreach ($c in $calls) {
                    $t = $c.Extent.Text
                    if ($t -match '(?i)-Method\s+(POST|PATCH|PUT|DELETE)' -and -not $ssp -and $t -notmatch '(?i)-ReadOnly') {
                        $offenders += "$($file.Name):$($c.Extent.StartLineNumber) $($fn.Name)"
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'design note: -ReadOnly is caller-declared, a write POST marked -ReadOnly is sent on Read' {
        { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/o/p/_apis/wit/workitems/$Task' -Body '[]' -Headers @{ Authorization = 'x' } -ReadOnly } |
            Should -Not -Throw
    }
}

Describe 'V18 Bearer and credential exclusivity' {
    BeforeEach { Clear-ValEnv; $env:ADO_ORG = 'o'; $env:ADO_PROJECT = 'p'; $script:AdoSession = $null }
    AfterAll  { Restore-ValEnv }

    It 'Bearer header shape is exactly "Bearer <token>"' {
        (New-AdoHeaders -Token 'abc.def').Authorization | Should -BeExactly 'Bearer abc.def'
        $env:SYSTEM_ACCESSTOKEN = 'sys'
        (New-AdoHeaders -Bearer).Authorization | Should -BeExactly 'Bearer sys'
    }

    It 'New-AdoHeaders rejects <Combo>' -ForEach @(
        @{ Combo = '-Pat -Token';    A = @{ Pat = 'a'; Token = 'b' } }
        @{ Combo = '-Pat -Bearer';   A = @{ Pat = 'a'; Bearer = $true } }
        @{ Combo = '-Token -Bearer'; A = @{ Token = 'b'; Bearer = $true } }
    ) {
        $env:SYSTEM_ACCESSTOKEN = 'sys'
        { New-AdoHeaders @A } | Should -Throw '*only one*'
    }

    It 'Initialize-AdoSession rejects <Combo>' -ForEach @(
        @{ Combo = '-Pat -Bearer';   A = @{ Pat = 'a'; Bearer = $true } }
        @{ Combo = '-Token -Bearer'; A = @{ Token = 'b'; Bearer = $true } }
    ) {
        $env:SYSTEM_ACCESSTOKEN = 'sys'
        { Initialize-AdoSession @A } | Should -Throw '*only one*'
    }

    It 'SYSTEM_ACCESSTOKEN: below ADO_PAT and AZURE_DEVOPS_EXT_PAT; -Bearer forces it' {
        $env:SYSTEM_ACCESSTOKEN = 'sys'
        (Initialize-AdoSession).Headers.Authorization | Should -Be 'Bearer sys'
        $env:AZURE_DEVOPS_EXT_PAT = 'ext'
        (Initialize-AdoSession).Headers.Authorization | Should -Be (Basic 'ext')
        $env:ADO_PAT = 'gen'
        (Initialize-AdoSession).Headers.Authorization | Should -Be (Basic 'gen')
        (Initialize-AdoSession -Bearer).Headers.Authorization | Should -Be 'Bearer sys'
    }

    It '-Bearer without SYSTEM_ACCESSTOKEN fails and does not fall back to ADO_PAT' {
        $env:ADO_PAT = 'gen'
        { Initialize-AdoSession -Bearer } | Should -Throw '*SYSTEM_ACCESSTOKEN*'
    }

    It 'Bearer header is what goes on the wire (local listener, real 5.1 stack)' -Tag Integration {
        $srv = Start-LocalHttp -Status 200 -Body '{"ok":1}'
        try {
            $null = Invoke-AdoRequest -Method GET -Uri "$($srv.Base)/x" -Headers (New-AdoHeaders -Token 'wire-tok')
            $srv.State.Auth[0] | Should -BeExactly 'Bearer wire-tok'
        } finally { Stop-LocalHttp $srv }
    }
}

Describe 'V18 VS403463 detection' {
    BeforeAll { Mock Start-Sleep { }; $script:AdoSession = New-ValSession -Access 'Write' }
    AfterAll  { $script:AdoSession = $null }

    It 'Invoke-AdoRequest, real 5.1 WebException, <Where>: AdoConditionalAccess, not retried' -Tag Integration -ForEach @(
        @{ Where = 'header only (401)'; Status = 401; H = @{ 'X-TFS-ServiceError' = $CaHeader }; B = '' }
        @{ Where = 'body only (401)';   Status = 401; H = @{}; B = $CaBody }
        @{ Where = 'header (403)';      Status = 403; H = @{ 'X-TFS-ServiceError' = $CaHeader }; B = $CaBody }
        @{ Where = 'body (400)';        Status = 400; H = @{}; B = $CaBody }
        @{ Where = 'header (503)';      Status = 503; H = @{ 'X-TFS-ServiceError' = $CaHeader }; B = '' }
    ) {
        $srv = Start-LocalHttp -Status $Status -ExtraHeaders $H -Body $B
        try {
            $err = $null
            try { Invoke-AdoRequest -Method GET -Uri "$($srv.Base)/x" -Headers (New-AdoHeaders -Token $script:SecretTok) -RetryDelaySec 0 } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
            "$err" | Should -Not -Match ([regex]::Escape($script:SecretTok))
            $srv.State.Count | Should -Be 1
        } finally { Stop-LocalHttp $srv }
    }

    It 'Invoke-AdoRequest POST (-RetryNonIdempotent -ReadOnly) with VS403463 is not retried' -Tag Integration {
        $srv = Start-LocalHttp -Status 401 -ExtraHeaders @{ 'X-TFS-ServiceError' = $script:CaHeader }
        try {
            { Invoke-AdoRequest -Method POST -Uri "$($srv.Base)/wiql" -Body '{}' -Headers @{ Authorization = 'x' } -RetryNonIdempotent -ReadOnly -RetryDelaySec 0 } |
                Should -Throw -ErrorId 'AdoConditionalAccess'
            $srv.State.Count | Should -Be 1
        } finally { Stop-LocalHttp $srv }
    }

    It 'Invoke-AdoGetPaged, real 5.1 WebException, <Where>: AdoConditionalAccess, not retried' -Tag Integration -ForEach @(
        @{ Where = 'header (401)'; Status = 401; H = @{ 'X-TFS-ServiceError' = $CaHeader }; B = '' }
        @{ Where = 'body (401)';   Status = 401; H = @{}; B = $CaBody }
        @{ Where = 'header (503)'; Status = 503; H = @{ 'X-TFS-ServiceError' = $CaHeader }; B = '' }
    ) {
        $srv = Start-LocalHttp -Status $Status -ExtraHeaders $H -Body $B
        try {
            { Invoke-AdoGetPaged -Uri "$($srv.Base)/x" -Headers @{ Authorization = 'x' } -RetryDelaySec 0 } | Should -Throw -ErrorId 'AdoConditionalAccess'
            $srv.State.Count | Should -Be 1
        } finally { Stop-LocalHttp $srv }
    }

    It 'PS7-like shape (headers object with GetValues, no string indexer) is detected' {
        Add-Type -AssemblyName System.Net.Http
        $hdr = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized).Headers
        $hdr.TryAddWithoutValidation('X-TFS-ServiceError', $script:CaHeader) | Out-Null
        $ex = [System.Exception]::new('Response status code does not indicate success: 401 (Unauthorized).')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401; Headers = $hdr })
        $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        Test-AdoConditionalAccessError -ErrorRecord $er | Should -BeTrue
    }

    It 'a plain 401 without VS403463 is not reported as Conditional Access' -Tag Integration {
        $srv = Start-LocalHttp -Status 401 -Body '{"message":"TF400813: not authorized"}'
        try {
            $err = $null
            try { Invoke-AdoRequest -Method GET -Uri "$($srv.Base)/x" -Headers @{ Authorization = 'x' } } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -Not -Match 'AdoConditionalAccess'
            "$err" | Should -Match '401'
        } finally { Stop-LocalHttp $srv }
    }

    It 'Invoke-AdoDownload reports VS403463 as Conditional Access (beyond the issue scope)' -Tag Integration {
        $srv = Start-LocalHttp -Status 401 -ExtraHeaders @{ 'X-TFS-ServiceError' = $script:CaHeader }
        try {
            $err = $null
            try { Invoke-AdoDownload -Uri "$($srv.Base)/f" -OutFile (Join-Path $TestDrive 'f.bin') -Headers @{ Authorization = 'x' } } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -Match 'AdoConditionalAccess'
        } finally { Stop-LocalHttp $srv }
    }
}

Describe 'V18 secret hygiene (all streams)' {
    BeforeEach { Clear-ValEnv; $env:ADO_ORG = 'o'; $env:ADO_PROJECT = 'p'; $script:AdoSession = $null; Mock Start-Sleep { } }
    AfterAll  { Restore-ValEnv; $script:AdoSession = $null }

    It 'the session object exposes no secret outside Headers, and its default rendering hides it' {
        $env:ADO_PAT = $script:SecretPat
        $s = Initialize-AdoSession
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:SecretPat)"))
        foreach ($p in $s.PSObject.Properties | Where-Object Name -ne 'Headers') {
            "$($p.Value)" | Should -Not -Match $script:SecretPat
            "$($p.Value)" | Should -Not -Match ([regex]::Escape($b64))
        }
        ($s | Out-String) | Should -Not -Match ([regex]::Escape($b64))
        ($s | Format-List * | Out-String) | Should -Not -Match ([regex]::Escape($b64))
    }

    It 'HTTP <S> errors, retries and warnings never contain the credential (Verbose/Debug/Warning captured)' -Tag Integration -ForEach @(
        @{ S = 401 }, @{ S = 403 }, @{ S = 404 }, @{ S = 500 }, @{ S = 503 }
    ) {
        $srv = Start-LocalHttp -Status $S -Body '{"message":"nope"}'
        try {
            $all = & {
                $VerbosePreference = 'Continue'; $DebugPreference = 'Continue'
                try { Invoke-AdoRequest -Method GET -Uri "$($srv.Base)/x" -Headers (New-AdoHeaders -Token $script:SecretTok) -MaxRetries 2 -RetryDelaySec 0 -Verbose }
                catch { "ERR: $_"; "ERRFULL: $($_ | Out-String)" }
                try { Invoke-AdoGetPaged -Uri "$($srv.Base)/x" -Headers (New-AdoHeaders -Pat $script:SecretPat) -MaxRetries 2 -RetryDelaySec 0 -Verbose }
                catch { "ERR: $_"; "ERRFULL: $($_ | Out-String)" }
            } *>&1 | Out-String
            $all | Should -Match 'ERR:'
            $all | Should -Not -Match ([regex]::Escape($script:SecretTok))
            $all | Should -Not -Match $script:SecretPat
            $all | Should -Not -Match ([regex]::Escape([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:SecretPat)"))))
        } finally { Stop-LocalHttp $srv }
    }

    It 'missing-credential / usage errors name variables only (<Case>)' -ForEach @(
        @{ Case = 'Read with only WRITE set'; Env = @{ ADO_PAT_WRITE = 'VALWRITEPAT9876543210zyxwvu' }; Call = { Initialize-AdoSession -Access Read } }
        @{ Case = 'Write with only READ set'; Env = @{ ADO_PAT_READ = 'VALWRITEPAT9876543210zyxwvu' }; Call = { Initialize-AdoSession -Access Write } }
        @{ Case = '-Bearer without token';    Env = @{ ADO_PAT = 'VALWRITEPAT9876543210zyxwvu' }; Call = { Initialize-AdoSession -Bearer } }
        @{ Case = 'exclusivity error';        Env = @{}; Call = { New-AdoHeaders -Pat 'VALWRITEPAT9876543210zyxwvu' -Token 'VALWRITEPAT9876543210zyxwvu' } }
    ) {
        foreach ($k in $Env.Keys) { Set-Item "env:$k" $Env[$k] }
        $out = & { try { & $Call } catch { "ERR: $_"; $_ | Out-String } } *>&1 | Out-String
        $out | Should -Match 'ERR:'
        $out | Should -Not -Match 'VALWRITEPAT9876543210zyxwvu'
    }

    It 'Read-session refusal error does not contain the Authorization value' {
        $script:AdoSession = New-ValSession -Access 'Read'
        $out = & { try { Invoke-AdoRequest -Method POST -Uri 'https://dev.azure.com/o/_apis/x' -Body '{}' -Headers (New-AdoHeaders -Token $script:SecretTok) } catch { $_ | Out-String } } *>&1 | Out-String
        $out | Should -Match 'Read'
        $out | Should -Not -Match ([regex]::Escape($script:SecretTok))
    }

    It 'a malformed legacy config file with a pat does not echo the pat in the warning' {
        $cfg = Join-Path $TestDrive 'bad.json'
        "{ `"org`": `"o`", `"pat`": `"$($script:SecretPat)`", oops }" | Set-Content -LiteralPath $cfg
        $env:ADO_PAT = 'x'
        $out = & { try { Resolve-AdoConfig -ConfigPath $cfg | Out-Null } catch { "ERR: $_" } } *>&1 | Out-String
        $out | Should -Not -Match $script:SecretPat
    }
}
