<#
.SYNOPSIS
  Test operations on Azure DevOps REST API.
  Covers Test Plans, Test Suites, Test Cases, Test Runs, and Results.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.
  New-AdoTestCase internally calls New-AdoWorkItem, so ado-workitems.ps1
  must also be dot-sourced before using New-AdoTestCase.

.SAFETY
  Read functions have no side effects.
  Write functions implement [CmdletBinding(SupportsShouldProcess)].
  Use -WhatIf to simulate. Use -Confirm:$false to skip prompts in scripts.
  IMPORTANT: Always pass -Confirm:$false to Add-AdoTestCaseToSuite inside
  scripts — the default ConfirmPreference can silently suppress the API call.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-workitems.ps1"
  . "$PSScriptRoot/ado-testing.ps1"
  $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Test Plans: Read --

function Get-AdoTestPlans {
    <#
    .SYNOPSIS  Lists all Test Plans in the project.
    #>
    param(
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoTestPlan {
    <#
    .SYNOPSIS  Gets a Test Plan by ID.
    #>
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    return Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans/$PlanId`?api-version=$ApiV" -Headers $Headers
}

#endregion

#region -- Test Suites: Read --

function Get-AdoTestSuites {
    <#
    .SYNOPSIS  Lists the Test Suites of a Test Plan.
        .DESCRIPTION
      Tries multiple API endpoint shapes in order to maximise compatibility across
      ADO organisations and API versions:
        1. /_apis/test/plans/{planId}/suites  (classic, most compatible)
        2. /_apis/testplan/Plans/{planId}/Suites?api-version={v}-preview.2
        3. /_apis/testplan/Plans/{planId}/Suites?api-version={v}-preview.1
        4. /_apis/testplan/Plans/{planId}/Suites?api-version={v}
    #>
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $base = "$(Get-AdoBaseUrl $Org)/$Project"
    $urls = @(
        "$base/_apis/test/plans/$PlanId/suites?api-version=$ApiV",
        "$base/_apis/testplan/Plans/$PlanId/Suites?api-version=$ApiV-preview.2",
        "$base/_apis/testplan/Plans/$PlanId/Suites?api-version=$ApiV-preview.1",
        "$base/_apis/testplan/Plans/$PlanId/Suites?api-version=$ApiV"
    )
    foreach ($u in $urls) {
        try {
            $r = Invoke-AdoGet -Uri $u -Headers $Headers -MaxRetries 1
            if ($r -and $r.value -and @($r.value).Count -gt 0) { return $r.value }
        }
        catch { continue }
    }
    return @()
}

function Get-AdoTestCases {
    <#
    .SYNOPSIS  Lists the Test Cases of a Suite.
        .DESCRIPTION
      Tries multiple API endpoint shapes in order to maximise compatibility across
      ADO organisations and API versions:
        1. /_apis/test/plans/{planId}/suites/{suiteId}/testcases  (classic)
        2. /_apis/testplan/Plans/{planId}/Suites/{suiteId}/TestCase?api-version={v}-preview.2
        3. /_apis/testplan/Plans/{planId}/Suites/{suiteId}/TestCase?api-version={v}-preview.1
        4. /_apis/testplan/Plans/{planId}/Suites/{suiteId}/TestCases?api-version={v}
        5. /_apis/test/suites/{suiteId}/testcases  (legacy fallback)
      Returns the raw value array; shape normalisation (testCase.id vs workItem.id)
      is the responsibility of the caller.
    #>
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [Parameter(Mandatory)][int]$SuiteId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $base = "$(Get-AdoBaseUrl $Org)/$Project"
    $urls = @(
        "$base/_apis/test/plans/$PlanId/suites/$SuiteId/testcases?api-version=$ApiV",
        "$base/_apis/testplan/Plans/$PlanId/Suites/$SuiteId/TestCase?api-version=$ApiV-preview.2",
        "$base/_apis/testplan/Plans/$PlanId/Suites/$SuiteId/TestCase?api-version=$ApiV-preview.1",
        "$base/_apis/testplan/Plans/$PlanId/Suites/$SuiteId/TestCases?api-version=$ApiV",
        "$base/_apis/test/suites/$SuiteId/testcases?api-version=$ApiV"
    )
    foreach ($u in $urls) {
        try {
            $r = Invoke-AdoGet -Uri $u -Headers $Headers -MaxRetries 1
            if ($r -and $r.value -and @($r.value).Count -gt 0) { return $r.value }
        }
        catch { continue }
    }
    return @()
}

#endregion

#region -- Test Runs and Results: Read --

function Get-AdoTestRuns {
    <#
    .SYNOPSIS  Lists Test Runs in the project, optionally filtered by Test Plan.
    #>
    param(
        [int]$PlanId,
        [int]$Top    = 50,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/test/runs?`$top=$Top&api-version=$ApiV"
    if ($PlanId) { $uri += "&planId=$PlanId" }
    $r = Invoke-AdoGet -Uri $uri -Headers $Headers
    return $r.value
}

function Get-AdoTestRunResults {
    <#
    .SYNOPSIS  Returns the results of a specific Test Run.
    #>
    param(
        [Parameter(Mandatory)][int]$RunId,
        [int]$Top    = 200,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/test/runs/$RunId/results?`$top=$Top&api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion

#region -- Test Runs: Write --

function New-AdoTestRun {
    <#
    .SYNOPSIS  Creates a new Test Run associated with a Test Plan.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$PlanId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/test/runs?api-version=$ApiV"
    $body = @{ name = $Name; plan = @{ id = $PlanId } } | ConvertTo-Json

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create Test Run '$Name' (Plan $PlanId)")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body $body -Headers $Headers
    Write-Host "(ok) Test Run created - ID: $($r.id)" -ForegroundColor Green
    return $r
}

function Update-AdoTestRunResults {
    <#
    .SYNOPSIS  Publishes results to an existing Test Run.
    .PARAMETER Results
        Array of hashtables. Minimum fields:
          @{ testCaseTitle=''; outcome='Passed'|'Failed'|'NotExecuted'|'Blocked' }
    .EXAMPLE
        $results = @(
            @{ testCaseTitle='Correct login'; outcome='Passed'  },
            @{ testCaseTitle='Wrong login'; outcome='Failed'; errorMessage='Error 500' }
        )
        Update-AdoTestRunResults -RunId 456 -Results $results
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][hashtable[]]$Results,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/test/runs/$RunId/results?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - $($Results.Count) results in Run #$RunId")) { return $null }

    return Invoke-AdoRequest -Method POST -Uri $uri -Body ($Results | ConvertTo-Json -Depth 6) -Headers $Headers
}

#endregion

#region -- Test Plans: Write --

function New-AdoTestPlan {
    <#
    .SYNOPSIS  Creates a new Test Plan and returns the created object.
    .PARAMETER Name          Display name for the Test Plan (mandatory).
    .PARAMETER AreaPath      Area path the plan belongs to (mandatory).
    .PARAMETER IterationPath Iteration/sprint path for the plan.
    .PARAMETER StartDate     ISO-8601 start date, e.g. '2025-01-01'.
    .PARAMETER EndDate       ISO-8601 end date, e.g. '2025-03-31'.
    .EXAMPLE
        New-AdoTestPlan -Name 'Sprint 5 UAT' -AreaPath 'MyProject' `
            -IterationPath 'MyProject\Sprint 5' -StartDate '2025-01-01' -EndDate '2025-01-14'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$AreaPath,
        [string]$IterationPath,
        [string]$StartDate,
        [string]$EndDate,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $body = @{ name = $Name; areaPath = $AreaPath }
    if ($IterationPath) { $body.iteration  = $IterationPath }
    if ($StartDate)     { $body.startDate  = $StartDate     }
    if ($EndDate)       { $body.endDate    = $EndDate       }

    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create Test Plan '$Name'")) {
        Write-Warning "New-AdoTestPlan: ShouldProcess returned false - no API call made. Check `$ConfirmPreference (current: $ConfirmPreference) or pass -Confirm:`$false."
        return $null
    }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 5) -Headers $Headers
    Write-Host "(ok) Test Plan created - ID: $($r.id) | Name: $($r.name)" -ForegroundColor Green
    return $r
}

#endregion

#region -- Test Suites: Write --

function New-AdoTestSuite {
    <#
    .SYNOPSIS  Creates a new Test Suite inside an existing Test Plan.
    .PARAMETER PlanId        ID of the parent Test Plan (mandatory).
    .PARAMETER Name          Display name for the suite (mandatory).
    .PARAMETER ParentSuiteId ID of the parent suite (use the plan's rootSuite.id for top-level suites).
    .PARAMETER SuiteType     staticTestSuite (default) | requirementTestSuite | dynamicTestSuite.
    .PARAMETER QueryString   WIQL query string; only used when SuiteType is 'dynamicTestSuite'.
    .EXAMPLE
        New-AdoTestSuite -PlanId 1001 -Name 'Login module' -ParentSuiteId 1002

        New-AdoTestSuite -PlanId 1001 -Name 'High priority' -ParentSuiteId 1002 `
            -SuiteType dynamicTestSuite `
            -QueryString "SELECT [System.Id] FROM WorkItems WHERE [Microsoft.VSTS.Common.Priority] = 1"
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ParentSuiteId,
        [ValidateSet('staticTestSuite','requirementTestSuite','dynamicTestSuite')]
        [string]$SuiteType = 'staticTestSuite',
        [string]$QueryString,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $body = @{
        suiteType   = $SuiteType
        name        = $Name
        parentSuite = @{ id = $ParentSuiteId }
    }
    if ($SuiteType -eq 'dynamicTestSuite' -and $QueryString) {
        $body.queryString = $QueryString
    }

    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans/$PlanId/suites?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create Test Suite '$Name' in Plan $PlanId")) {
        Write-Warning "New-AdoTestSuite: ShouldProcess returned false - no API call made. Check `$ConfirmPreference (current: $ConfirmPreference) or pass -Confirm:`$false."
        return $null
    }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 5) -Headers $Headers
    Write-Host "(ok) Test Suite created - ID: $($r.id) | Name: $($r.name)" -ForegroundColor Green
    return $r
}

#endregion

#region -- Test Cases: Write --

function New-AdoTestCase {
    <#
    .SYNOPSIS
      Creates a Test Case work item with optional steps.
      Wraps New-AdoWorkItem -Type 'Test Case' and handles TCM-specific fields.

    .PARAMETER Title        Title of the Test Case (mandatory).
    .PARAMETER Steps        Ordered array of plain-text action strings.
                            Encoded as the XML format required by Microsoft.VSTS.TCM.Steps.
    .PARAMETER Priority     1 (Critical) | 2 (High) | 3 (Medium) | 4 (Low).
    .PARAMETER ExtraFields  Hashtable of additional TCM or custom fields.

    .EXAMPLE
        New-AdoTestCase -Title 'Verify login with valid credentials' `
            -Steps @('Navigate to /login', 'Enter username and password', 'Click Sign In') `
            -Priority '2' -AssignedTo 'qa@contoso.com' -Tags 'login; smoke'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Description,
        [string]$AssignedTo,
        [string]$AreaPath,
        [string]$IterationPath,
        [string]$Tags,
        [ValidateSet('Design','Ready','Closed')]
        [string]$State,
        [string[]]$Steps,
        [ValidateSet('1','2','3','4')]
        [string]$Priority,
        [hashtable]$ExtraFields = @{},
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $extra = $ExtraFields.Clone()

    if ($Priority) {
        $extra['Microsoft.VSTS.Common.Priority'] = $Priority
    }

    if ($Steps -and $Steps.Count -gt 0) {
        $stepsXml   = '<steps id="0" last="{0}">' -f $Steps.Count
        $stepIndex  = 1
        foreach ($action in $Steps) {
            $escaped  = [System.Security.SecurityElement]::Escape($action)
            $stepsXml += '<step id="{0}" type="ActionStep"><parameterizedString isformatted="true">{1}</parameterizedString><parameterizedString isformatted="true"/></step>' -f $stepIndex, $escaped
            $stepIndex++
        }
        $stepsXml += '</steps>'
        $extra['Microsoft.VSTS.TCM.Steps'] = $stepsXml
    }

    $splatArgs = @{
        Type        = 'Test Case'
        Title       = $Title
        ExtraFields = $extra
        Org         = $Org
        Project     = $Project
        ApiV        = $ApiV
        Headers     = $Headers
    }
    if ($Description)   { $splatArgs.Description   = $Description   }
    if ($AssignedTo)    { $splatArgs.AssignedTo    = $AssignedTo    }
    if ($AreaPath)      { $splatArgs.AreaPath      = $AreaPath      }
    if ($IterationPath) { $splatArgs.IterationPath = $IterationPath }
    if ($Tags)          { $splatArgs.Tags          = $Tags          }
    if ($State)         { $splatArgs.State         = $State         }

    # WhatIf / Confirm propagate automatically via $WhatIfPreference / $ConfirmPreference
    return New-AdoWorkItem @splatArgs
}

function Add-AdoTestCaseToSuite {
    <#
    .SYNOPSIS  Adds one or more existing Test Case work items to a Test Suite.
    .PARAMETER PlanId       ID of the Test Plan.
    .PARAMETER SuiteId      ID of the target Test Suite.
    .PARAMETER TestCaseIds  Array of Test Case work item IDs to add.
    .NOTES
        Always pass -Confirm:$false in scripts. Without it, the default
        ConfirmPreference can silently suppress the API call with no error.
    .EXAMPLE
        Add-AdoTestCaseToSuite -PlanId 1001 -SuiteId 1002 -TestCaseIds @(5010, 5011) -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [Parameter(Mandatory)][int]$SuiteId,
        [Parameter(Mandatory)][int[]]$TestCaseIds,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $body = @($TestCaseIds | ForEach-Object { @{ workItem = @{ id = $_ } } })
    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans/$PlanId/suites/$SuiteId/testcase?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Add $($TestCaseIds.Count) TC(s) to Suite $SuiteId (Plan $($PlanId))")) {
        Write-Warning "Add-AdoTestCaseToSuite: ShouldProcess returned false - no API call made. Check `$ConfirmPreference (current: $($ConfirmPreference)) or pass -Confirm:`$false."
        return $null
    }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body $($body | ConvertTo-Json -Depth 5) -Headers $Headers
    Write-Host "(ok) $($TestCaseIds.Count) Test Case(s) added to Suite $SuiteId (Plan $($PlanId))" -ForegroundColor Green
    return $r
}

#endregion
