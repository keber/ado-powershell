#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #11: list functions ignore continuation tokens and truncate silently.
# No network access: all HTTP calls are mocked.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')
    . (Join-Path $script:ScriptsDir 'ado-workitems.ps1')
    . (Join-Path $script:ScriptsDir 'ado-content.ps1')
    . (Join-Path $script:ScriptsDir 'ado-testing.ps1')
    . (Join-Path $script:ScriptsDir 'ado-pipelines.ps1')
    . (Join-Path $script:ScriptsDir 'ado-git.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }

    function script:New-FakeWebResponse {
        param($Page, [hashtable]$Headers = @{})
        $h = @{ 'Content-Type' = 'application/json' }
        foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
        [pscustomobject]@{ StatusCode = 200; Headers = $h; Content = ($Page | ConvertTo-Json -Depth 6) }
    }
    function script:New-Items { param([string]$Prefix, [int]$From, [int]$To)
        @($From..$To | ForEach-Object { [pscustomobject]@{ name = "$Prefix$_" } })
    }
}

Describe 'M4 - Invoke-AdoGetPaged: header continuation token' {
    BeforeAll {
        Mock Start-Sleep { }
        $script:Uris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-WebRequest {
            $script:Uris.Add($Uri.OriginalString)
            if ($Uri.OriginalString -match 'continuationToken=tok%2B1') {
                New-FakeWebResponse -Page ([pscustomobject]@{ count = 2; value = (New-Items 'p' 3 4) })
            } else {
                New-FakeWebResponse -Page ([pscustomobject]@{ count = 2; value = (New-Items 'p' 1 2) }) `
                    -Headers @{ 'x-ms-continuationtoken' = 'tok+1' }
            }
        }
    }

    It 'Get-AdoProjects returns items from every page' {
        $projects = Get-AdoProjects -Headers $script:FakeHeaders
        @($projects | ForEach-Object name) | Should -Be @('p1', 'p2', 'p3', 'p4')
    }

    It 'sends the token URL-encoded on the second request' {
        $script:Uris.Count | Should -Be 2
        $script:Uris[1] | Should -Match 'api-version=7\.1&continuationToken=tok%2B1$'
    }

    It 'Get-AdoTeams, Get-AdoTestPlans, Get-AdoPipelines and Get-AdoBranches page as well' {
        @(Get-AdoTeams -Headers $script:FakeHeaders).Count          | Should -Be 4
        @(Get-AdoTestPlans -Headers $script:FakeHeaders).Count      | Should -Be 4
        @(Get-AdoPipelines -Headers $script:FakeHeaders).Count      | Should -Be 4
        @(Get-AdoBranches -RepoId 'r' -Headers $script:FakeHeaders).Count | Should -Be 4
    }
}

Describe 'M4 - Invoke-AdoGetPaged: body continuation token' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            if ($Uri -match 'continuationToken=c2') {
                New-FakeWebResponse -Page ([pscustomobject]@{ count = 1; comments = @([pscustomobject]@{ text = 'c3' }) })
            } elseif ($Uri -match 'continuationToken=c1') {
                New-FakeWebResponse -Page ([pscustomobject]@{ count = 1; comments = @([pscustomobject]@{ text = 'c2' }); continuationToken = 'c2' })
            } else {
                New-FakeWebResponse -Page ([pscustomobject]@{ count = 1; comments = @([pscustomobject]@{ text = 'c1' }); continuationToken = 'c1' })
            }
        }
    }

    It 'Get-AdoWorkItemComments follows continuationToken from the body' {
        $c = Get-AdoWorkItemComments -Id 7 -Headers $script:FakeHeaders
        @($c | ForEach-Object text) | Should -Be @('c1', 'c2', 'c3')
    }
}

Describe 'M4 - Invoke-AdoGetPaged: MaxItems' {
    BeforeAll {
        Mock Start-Sleep { }
        $script:Calls = 0
        Mock Invoke-WebRequest {
            $script:Calls++
            New-FakeWebResponse -Page ([pscustomobject]@{ value = (New-Items 'x' 1 3) }) `
                -Headers @{ 'x-ms-continuationtoken' = "t$script:Calls" }
        }
    }

    It 'stops once MaxItems were collected and trims the surplus' {
        $r = Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' `
                -Headers $script:FakeHeaders -MaxItems 5
        @($r).Count | Should -Be 5
        $script:Calls | Should -Be 2
    }

    It 'stops (with a warning) if the server keeps returning the same token' {
        Mock Invoke-WebRequest {
            New-FakeWebResponse -Page ([pscustomobject]@{ value = (New-Items 'x' 1 1) }) `
                -Headers @{ 'x-ms-continuationtoken' = 'same' }
        }
        $r = Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' `
                -Headers $script:FakeHeaders -WarningAction SilentlyContinue
        @($r).Count | Should -Be 2
    }
}

Describe 'M4 - Invoke-AdoGetPaged: encoding and sign-in page' {
    BeforeAll { Mock Start-Sleep { } }

    It 'decodes the raw bytes as UTF-8' {
        $json  = '{"value":[{"name":"bot' + [char]0x00F3 + 'n"}]}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode       = 200
                Headers          = @{}
                Content          = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)  # what 5.1 would produce
                RawContentStream = [System.IO.MemoryStream]::new($bytes)
            }
        }
        $r = Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' -Headers $script:FakeHeaders
        @($r)[0].name | Should -Be ('bot' + [char]0x00F3 + 'n')
    }

    It 'throws on an HTML sign-in page served with HTTP 200' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}
                Content = '<html><head><title>Azure DevOps Services | Sign In</title></head></html>' }
        }
        { Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' -Headers $script:FakeHeaders } |
            Should -Throw '*sign-in page*'
    }
}

Describe 'M4 - Invoke-AdoGetPaged: 400 body on PowerShell 7 (ErrorDetails)' {
    BeforeAll { Mock Start-Sleep { } }

    It 'surfaces the JSON message from ErrorDetails and keeps the 400 prefix' {
        Mock Invoke-WebRequest {
            $ex = [System.Exception]::new('Response status code does not indicate success: 400 (Bad Request).')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 400 })
            $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"TF401320: Rule Error for field Title"}')
            throw $er
        }
        $err = try { Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' -Headers $script:FakeHeaders } catch { $_ }
        "$err" | Should -Match '^400 Bad Request - '
        "$err" | Should -Match 'TF401320'
        "$err" | Should -Not -Match '"message"'
    }
}

Describe 'M4 - Get-AdoWorkItemRevisions loops with $skip' {
    BeforeAll {
        Mock Start-Sleep { }
        $script:RevUris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:RevUris.Add($Uri)
            if ($Uri -match 'skip=200') {
                [pscustomobject]@{ count = 50;  value = @(201..250 | ForEach-Object { [pscustomobject]@{ rev = $_ } }) }
            } elseif ($Uri -match 'skip=0') {
                [pscustomobject]@{ count = 200; value = @(1..200   | ForEach-Object { [pscustomobject]@{ rev = $_ } }) }
            } else { throw "unexpected $Uri" }
        }
    }

    It 'requests the next page until one returns fewer than $top items' {
        $r = Get-AdoWorkItemRevisions -Id 9 -Headers $script:FakeHeaders
        @($r).Count | Should -Be 250
        $script:RevUris.Count | Should -Be 2
        $script:RevUris[0] | Should -Match 'top=200&.skip=0'
        $script:RevUris[1] | Should -Match 'skip=200'
    }
}

Describe 'M4 - WIQL and test list truncation warnings' {
    BeforeAll {
        Mock Start-Sleep { }
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ workItems = @(1..3 | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
        }
    }

    It 'Invoke-AdoWiql warns when the result count equals -Top' {
        $null = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' -Top 3 -IdsOnly `
                    -Headers $script:FakeHeaders -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'truncated'
    }

    It 'Invoke-AdoWiql does not warn when fewer than -Top are returned' {
        $null = Invoke-AdoWiql -Query 'SELECT [System.Id] FROM WorkItems' -Top 10 -IdsOnly `
                    -Headers $script:FakeHeaders -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -Be 0
    }

    It 'Invoke-AdoWiql validates -Top in 1..20000' {
        { Invoke-AdoWiql -Query 'q' -Top 0     -Headers $script:FakeHeaders } | Should -Throw
        { Invoke-AdoWiql -Query 'q' -Top 20001 -Headers $script:FakeHeaders } | Should -Throw
    }

    It 'Get-AdoTestRuns and Get-AdoTestRunResults warn when the count equals -Top' {
        Mock Invoke-AdoGet { [pscustomobject]@{ value = @(1..2 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
        $w1 = Get-AdoTestRuns -Top 2 -Headers $script:FakeHeaders 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $w2 = Get-AdoTestRunResults -RunId 1 -Top 2 -Headers $script:FakeHeaders 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        "$w1" | Should -Match 'truncated'
        "$w2" | Should -Match 'truncated'
    }
}

Describe 'M4 - Invoke-AdoGetPaged: aligned with Invoke-AdoRequest semantics' {
    BeforeAll { $script:Sleeps = [System.Collections.Generic.List[int]]::new(); Mock Start-Sleep { $script:Sleeps.Add([int]$Seconds) } }

    It 'throws the sign-in page as ErrorId AdoSignInPage and does not retry it' {
        $script:Calls = 0
        Mock Invoke-WebRequest {
            $script:Calls++
            [pscustomobject]@{ StatusCode = 200; Headers = @{}
                Content = '<html><head><title>Azure DevOps Services | Sign In</title></head></html>' }
        }
        $err = $null
        try { Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' -Headers $script:FakeHeaders } catch { $err = $_ }
        $err.FullyQualifiedErrorId | Should -Be 'AdoSignInPage'
        $script:Calls | Should -Be 1
    }

    It 'honours Retry-After on 429, capped at 120 seconds' {
        $script:Sleeps.Clear(); $script:N = 0
        Mock Invoke-WebRequest {
            $script:N++
            if ($script:N -eq 1) {
                $resp = [pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = '999' } }
                $ex = [System.Exception]::new('429')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
                throw $ex
            }
            New-FakeWebResponse -Page ([pscustomobject]@{ value = (New-Items 'p' 1 1) })
        }
        $r = Invoke-AdoGetPaged -Uri 'https://dev.azure.com/o/_apis/x?api-version=7.1' -Headers $script:FakeHeaders -WarningAction SilentlyContinue
        @($r).Count | Should -Be 1
        $script:Sleeps[0] | Should -Be 120
    }
}

Describe 'M4 - Invoke-AdoWiql truncation on link queries' {
    BeforeAll {
        Mock Start-Sleep { }
        # 2 relation rows, 3 distinct ids: -Top counts rows, so Top 2 is truncated, Top 3 is not.
        Mock Invoke-AdoRequest {
            [pscustomobject]@{ workItemRelations = @(
                [pscustomobject]@{ source = $null; target = [pscustomobject]@{ id = 1 } },
                [pscustomobject]@{ source = [pscustomobject]@{ id = 1 }; target = [pscustomobject]@{ id = 2 } }) }
        }
    }
    It 'warns when relation rows equal -Top' {
        $null = Invoke-AdoWiql -Query 'q' -Top 2 -IdsOnly -Headers $script:FakeHeaders -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'truncated'
    }
    It 'does not warn when rows are below -Top even if distinct ids equal it' {
        $null = Invoke-AdoWiql -Query 'q' -Top 3 -IdsOnly -Headers $script:FakeHeaders -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -Be 0
    }
}
