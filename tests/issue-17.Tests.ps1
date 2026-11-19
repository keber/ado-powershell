# Regression tests for issue #17: dot-sourcing the skill must not alter the caller session
# (StrictMode / $ErrorActionPreference), while the library functions keep running strict.
# No network access. Each check runs in a child powershell.exe so the Pester session is untouched.

BeforeAll {
    $script:SkillRoot  = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell'
    $script:ScriptsDir = Join-Path $script:SkillRoot 'scripts'
    $script:Load       = (Resolve-Path (Join-Path $script:SkillRoot 'load.ps1')).Path

    function script:Invoke-Child {
        param([string]$Body)
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("issue17-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        try {
            Set-Content -LiteralPath $tmp -Value $Body -Encoding UTF8
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
            @($out | ForEach-Object { "$_" })
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'M10 - Dot-sourcing the skill alters the caller session' {
    It 'load.ps1 leaves the caller ErrorActionPreference unchanged' {
        $out = Invoke-Child @"
`$ErrorActionPreference = 'Continue'
. '$($script:Load)' *> `$null
'EAP=' + `$ErrorActionPreference
"@
        $out | Should -Contain 'EAP=Continue'
    }

    It 'load.ps1 does not enable StrictMode in the caller scope' {
        $out = Invoke-Child @"
`$ErrorActionPreference = 'Continue'
. '$($script:Load)' *> `$null
try { `$null = `$neverAssignedIssue17; 'STRICT=off' } catch { 'STRICT=on' }
"@
        $out | Should -Contain 'STRICT=off'
    }

    It 'dot-sourcing each script individually leaves the caller session unchanged' {
        foreach ($f in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter *.ps1) {
            $out = Invoke-Child @"
`$ErrorActionPreference = 'Continue'
. '$($f.FullName)' *> `$null
'EAP=' + `$ErrorActionPreference
try { `$null = `$neverAssignedIssue17; 'STRICT=off' } catch { 'STRICT=on' }
"@
            $out | Should -Contain 'EAP=Continue' -Because $f.Name
            $out | Should -Contain 'STRICT=off'   -Because $f.Name
        }
    }

    It 'a caller that already runs under StrictMode stays strict after loading' {
        $out = Invoke-Child @"
Set-StrictMode -Version Latest
. '$($script:Load)' *> `$null
try { `$null = `$neverAssignedIssue17; 'STRICT=off' } catch { 'STRICT=on' }
"@
        $out | Should -Contain 'STRICT=on'
    }

    It 'smoke-test.ps1 usage line points at the real .github path' {
        $bad = @(Select-String -LiteralPath (Join-Path $script:SkillRoot 'assets\smoke-test.ps1') `
                    -Pattern '\. \.\\github\\skills' | ForEach-Object { $_.Line.Trim() })
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'M10 - Library functions keep running under StrictMode and ErrorActionPreference Stop' {
    It 'every function sets StrictMode Latest and EAP Stop as the first statement after its param block' {
        $missing = @()
        foreach ($f in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($fn in $fns) {
                $stmts = @($fn.Body.EndBlock.Statements)
                $ok = $stmts.Count -ge 2 -and
                      $stmts[0].Extent.Text -eq 'Set-StrictMode -Version Latest' -and
                      $stmts[1].Extent.Text -eq '$ErrorActionPreference = ''Stop'''
                if (-not $ok) { $missing += "$($f.Name):$($fn.Name)" }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'a function sets its own ErrorActionPreference to Stop even when the caller uses Continue' {
        $out = Invoke-Child @"
`$ErrorActionPreference = 'Continue'
. '$($script:Load)' *> `$null
`$body = (Get-Command Get-AdoFieldValue).ScriptBlock.Ast.Body
'FIRST=' + `$body.EndBlock.Statements[0].Extent.Text
'SECOND=' + `$body.EndBlock.Statements[1].Extent.Text
"@
        $out | Should -Contain 'FIRST=Set-StrictMode -Version Latest'
        $out | Should -Contain "SECOND=`$ErrorActionPreference = 'Stop'"
    }

    It 'Get-AdoFieldValue still works from a non-strict caller (missing field returns default)' {
        $out = Invoke-Child @"
`$ErrorActionPreference = 'Continue'
. '$($script:Load)' *> `$null
`$wi = [pscustomobject]@{ fields = [pscustomobject]@{ 'System.Title' = 'T' } }
'TITLE=' + (Get-AdoFieldValue -WorkItem `$wi -Name 'System.Title')
'MISSING=' + (Get-AdoFieldValue -WorkItem `$wi -Name 'System.Reason' -Default 'dflt')
"@
        $out | Should -Contain 'TITLE=T'
        $out | Should -Contain 'MISSING=dflt'
    }

    It 'a representative function with a mocked request still works' {
        . (Join-Path $script:ScriptsDir 'ado-base.ps1')
        . (Join-Path $script:ScriptsDir 'ado-git.ps1')
        $script:AdoSession = [pscustomobject]@{
            Org = 'o'; Project = 'p'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/o'
            Headers = @{ Authorization = 'Basic ZmFrZQ==' }
        }
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @([pscustomobject]@{ id = '1'; name = 'repo1' }) } }
        $r = @(Get-AdoRepositories)
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'repo1'
    }
}
