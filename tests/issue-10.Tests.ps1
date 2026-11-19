BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'ado-base.ps1')

    $script:AdoSession = [pscustomobject]@{
        Org     = 'fakeorg'
        Project = 'fakeproj'
        ApiV    = '7.1'
        BaseUrl = 'https://dev.azure.com/fakeorg'
        Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }
    $script:FakeHeaders = @{ Authorization = 'Basic ZmFrZQ==' }
    $script:Uri400 = 'https://dev.azure.com/fakeorg/fakeproj/_apis/wit/workitems/$Task?api-version=7.1'

    function script:Invoke-400 {
        try { Invoke-AdoRequest -Method POST -Uri $script:Uri400 -Body '[]' -Headers $script:FakeHeaders }
        catch { return $_ }
    }
}

Describe 'M3 - 400 response body is lost when Exception.Response has no GetResponseStream (PowerShell 7)' {
    BeforeAll { Mock Start-Sleep { } }

    It 'includes ErrorDetails.Message in the 400 error' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('Response status code does not indicate success: 400 (Bad Request).')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 400 })
            $er = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"TF401320: Rule Error for field Title"}')
            throw $er
        }
        $err = Invoke-400
        $err | Should -Not -BeNullOrEmpty
        "$err" | Should -Match '^400 Bad Request - '
        "$err" | Should -Match 'TF401320'
    }

    It 'includes a non-JSON ErrorDetails body verbatim' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('400')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 400 })
            $er = [System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('plain text failure')
            throw $er
        }
        "$(Invoke-400)" | Should -Match 'plain text failure'
    }

    It 'keeps the 400 prefix and still throws when no body is available anywhere' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('400')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 400 })
            throw ([System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null))
        }
        "$(Invoke-400)" | Should -Match '^400 Bad Request - '
    }

    It 'still reads the body from GetResponseStream on Windows PowerShell 5.1 shape' {
        Mock Invoke-RestMethod {
            $ex = [System.Exception]::new('The remote server returned an error: (400) Bad Request.')
            $resp = [pscustomobject]@{ StatusCode = 400 }
            $resp | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
                [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes('{"message":"TF401320: stream body"}'))
            }
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
            throw ([System.Management.Automation.ErrorRecord]::new($ex, 'x', 'InvalidOperation', $null))
        }
        "$(Invoke-400)" | Should -Match 'TF401320: stream body'
    }
}
