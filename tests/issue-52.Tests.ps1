#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression tests for issue #52: New-AdoTestCase steps use <parameterizedString isformatted="true">,
# which Azure DevOps parses as HTML. Plain text must therefore be HTML-encoded first and XML-escaped
# second, otherwise text such as 'Saved <ok>' is sanitized away. Mocked HTTP only; no network access.

BeforeAll {
    $scriptsDir = Join-Path $PSScriptRoot '..\.github\skills\ado-powershell\scripts'
    foreach ($f in 'ado-base.ps1', 'ado-workitems.ps1', 'ado-testing.ps1') {
        . (Join-Path $scriptsDir $f)
    }

    $script:AdoSession = [pscustomobject]@{
        Org = 'fakeorg'; Project = 'fakeproj'; ApiV = '7.1'; BaseUrl = 'https://dev.azure.com/fakeorg'
        Access = 'Write'; AuthScheme = 'Basic'; Headers = @{ Authorization = 'Basic ZmFrZQ==' }
    }

    # Returns the Microsoft.VSTS.TCM.Steps value sent in the captured create request.
    function script:Get-SentSteps {
        $ops = $script:Body | ConvertFrom-Json
        @($ops | Where-Object { $_.path -eq '/fields/Microsoft.VSTS.TCM.Steps' })[0].value
    }

    # Parses the steps XML and returns, per step, the text a client sees after ONE XML decode
    # (the HTML the server stores) and after a further HTML decode (what the UI renders).
    function script:Read-Steps([string]$Xml) {
        $doc = [xml]$Xml
        foreach ($s in $doc.steps.step) {
            $p = @($s.parameterizedString)
            [pscustomobject]@{
                Html     = $p[0].InnerText
                Rendered = [System.Net.WebUtility]::HtmlDecode($p[0].InnerText)
                ExpHtml  = $p[1].InnerText
                ExpText  = [System.Net.WebUtility]::HtmlDecode($p[1].InnerText)
            }
        }
    }
}

Describe 'New-AdoTestCase step encoding (issue #52)' {
    BeforeEach {
        Mock Write-Host { }
        $script:Body = $null
        Mock Invoke-AdoRequest { $script:Body = $Body; [pscustomobject]@{ id = 101 } }
    }

    It 'double-encodes <Label> in the action and the expected result' -TestCases @(
        @{ Label = 'an angle-bracket word'; Text = 'Saved <ok>';     Html = 'Saved &lt;ok&gt;';       Raw = 'Saved &amp;lt;ok&amp;gt;' }
        @{ Label = 'a generic type';        Text = 'List<string>';  Html = 'List&lt;string&gt;';     Raw = 'List&amp;lt;string&amp;gt;' }
        @{ Label = 'an inline tag';         Text = 'a<b>c';         Html = 'a&lt;b&gt;c';            Raw = 'a&amp;lt;b&amp;gt;c' }
        @{ Label = 'an ampersand';          Text = 'save & close';  Html = 'save &amp; close';       Raw = 'save &amp;amp; close' }
    ) {
        param($Label, $Text, $Html, $Raw)
        New-AdoTestCase -Title 'TC' -Steps @('first', $Text) -ExpectedResult $Text -Confirm:$false | Out-Null

        $xml = Get-SentSteps
        { [xml]$xml } | Should -Not -Throw
        $xml | Should -BeLike "*<parameterizedString isformatted=`"true`">$Raw</parameterizedString><parameterizedString isformatted=`"true`">$Raw</parameterizedString>*"

        $step = @(Read-Steps $xml)[1]
        $step.Html     | Should -BeExactly $Html
        $step.Rendered | Should -BeExactly $Text
        $step.ExpHtml  | Should -BeExactly $Html
        $step.ExpText  | Should -BeExactly $Text
    }

    It 'keeps plain text unchanged and builds one well-formed step per action' {
        New-AdoTestCase -Title 'TC' -Steps @('Open the page', 'Click Save') -ExpectedResult 'Saved' -Confirm:$false | Out-Null

        $steps = @(Read-Steps (Get-SentSteps))
        $steps.Count | Should -Be 2
        $steps[0].Rendered | Should -BeExactly 'Open the page'
        $steps[0].ExpHtml  | Should -BeExactly ''
        $steps[1].Rendered | Should -BeExactly 'Click Save'
        $steps[1].ExpText  | Should -BeExactly 'Saved'
        (Get-SentSteps) | Should -BeLike '*<step id="1" type="ActionStep">*<step id="2" type="ValidateStep">*'
    }

    It 'round-trips quotes and an already-encoded entity literally' {
        New-AdoTestCase -Title 'TC' -Steps @('Type "a" & ''b'' then &lt;') -Confirm:$false | Out-Null
        @(Read-Steps (Get-SentSteps))[0].Rendered | Should -BeExactly 'Type "a" & ''b'' then &lt;'
    }
}
