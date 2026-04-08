<#
.DEPRECATED
  Functions in this file have been moved to domain-specific files:
    ado-workitems.ps1  - New-AdoWorkItem, Update-AdoWorkItem, Add-AdoWorkItemComment, Add-AdoWorkItemLink, Add-AdoWorkItemAttachment
    ado-testing.ps1   - New-AdoTestRun, Update-AdoTestRunResults, New-AdoTestPlan, New-AdoTestSuite, New-AdoTestCase, Add-AdoTestCaseToSuite

  Load the skill via load.ps1 - it sources the domain files automatically.
  This file is kept for backward compatibility only and will be removed in a future version.

.SYNOPSIS
  WRITE operations on Azure DevOps REST API.
  All functions in this file modify data in ADO.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.SAFETY
  All functions implement [CmdletBinding(SupportsShouldProcess)].
  Use -WhatIf to simulate the operation without applying changes.
  Use -Confirm:$false to suppress prompts in automated pipelines.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-write.ps1"
  $s = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'

  # Simulate without changing anything:
  New-AdoWorkItem -Type 'Task' -Title 'My task' -WhatIf

  # Apply without interactive confirmation:
  New-AdoWorkItem -Type 'Task' -Title 'My task' -Confirm:$false
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Work Items: Create --

function New-AdoWorkItem {
    <#
    .SYNOPSIS  Creates a new Work Item of the specified type and returns the created object.
    .PARAMETER Type         Task | Bug | User Story | Feature | Epic | Issue ...
    .PARAMETER ExtraFields  Hashtable for any additional field, e.g.: @{'System.Tags'='qa'}
    .EXAMPLE
        New-AdoWorkItem -Type 'Task' -Title 'Configure CI/CD' -AssignedTo 'dev@contoso.com'
    .EXAMPLE
        New-AdoWorkItem -Type 'Bug' -Title 'Login fails' -ExtraFields @{ 'Microsoft.VSTS.TCM.ReproSteps' = '<p>Steps...</p>' }
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Title,
        [string]$Description,
        [string]$AssignedTo,
        [string]$AreaPath,
        [string]$IterationPath,
        [string]$Tags,
        [ValidateSet('New','Active','To Do','Resolved','Closed')]
        [string]$State,
        [hashtable]$ExtraFields = @{},
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $ops = [System.Collections.Generic.List[hashtable]]::new()
    $ops.Add(@{ op='add'; path='/fields/System.Title'; value=$Title })
    if ($Description)   { $ops.Add(@{ op='add'; path='/fields/System.Description';   value=$Description   }) }
    if ($AssignedTo)    { $ops.Add(@{ op='add'; path='/fields/System.AssignedTo';    value=$AssignedTo    }) }
    if ($AreaPath)      { $ops.Add(@{ op='add'; path='/fields/System.AreaPath';      value=$AreaPath      }) }
    if ($IterationPath) { $ops.Add(@{ op='add'; path='/fields/System.IterationPath'; value=$IterationPath }) }
    if ($Tags)          { $ops.Add(@{ op='add'; path='/fields/System.Tags';          value=$Tags          }) }
    if ($State)         { $ops.Add(@{ op='add'; path='/fields/System.State';         value=$State         }) }
    foreach ($k in $ExtraFields.Keys) {
        $ops.Add(@{ op='add'; path="/fields/$k"; value=$ExtraFields[$k] })
    }

    $typeEncoded = [Uri]::EscapeDataString($Type)
    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/`$$typeEncoded`?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create ${Type}: '$Title'")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($ops | ConvertTo-Json -Depth 5) `
        -ContentType 'application/json-patch+json' -Headers $Headers
    Write-Host "(ok) Work Item created - ID: $($r.id)" -ForegroundColor Green
    return $r
}

#endregion

#region -- Work Items: Update --

function Update-AdoWorkItem {
    <#
    .SYNOPSIS  Updates one or more fields of an existing Work Item.
    .PARAMETER ExtraFields  Hashtable for additional fields, e.g.: @{'System.Tags'='sprint-5'}
    .EXAMPLE   Update-AdoWorkItem -Id 1234 -State 'Active' -AssignedTo 'dev@contoso.com'
    .EXAMPLE   Update-AdoWorkItem -Id 1234 -ExtraFields @{'Microsoft.VSTS.Common.Priority'='1'}
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Title,
        [string]$Description,
        [string]$AssignedTo,
        [string]$State,
        [string]$AreaPath,
        [string]$IterationPath,
        [string]$Tags,
        [hashtable]$ExtraFields = @{},
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $ops = [System.Collections.Generic.List[hashtable]]::new()
    if ($Title)         { $ops.Add(@{ op='replace'; path='/fields/System.Title';          value=$Title         }) }
    if ($Description)   { $ops.Add(@{ op='replace'; path='/fields/System.Description';    value=$Description   }) }
    if ($AssignedTo)    { $ops.Add(@{ op='replace'; path='/fields/System.AssignedTo';     value=$AssignedTo    }) }
    if ($State)         { $ops.Add(@{ op='replace'; path='/fields/System.State';          value=$State         }) }
    if ($AreaPath)      { $ops.Add(@{ op='replace'; path='/fields/System.AreaPath';       value=$AreaPath      }) }
    if ($IterationPath) { $ops.Add(@{ op='replace'; path='/fields/System.IterationPath';  value=$IterationPath }) }
    if ($Tags)          { $ops.Add(@{ op='replace'; path='/fields/System.Tags';           value=$Tags          }) }
    foreach ($k in $ExtraFields.Keys) {
        $ops.Add(@{ op='replace'; path="/fields/$k"; value=$ExtraFields[$k] })
    }

    if ($ops.Count -eq 0) { Write-Warning 'No fields specified for update.'; return $null }

    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id`?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "PATCH - Update WI #$Id")) { return $null }

    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body ($ops | ConvertTo-Json -Depth 5) `
        -ContentType 'application/json-patch+json' -Headers $Headers
    Write-Host "(ok) Work Item updated - ID: $($r.id)" -ForegroundColor Green
    return $r
}

#endregion

#region -- Work Items: Comments --

function Add-AdoWorkItemComment {
    <#
    .SYNOPSIS  Adds a text or HTML comment to a Work Item.
    .EXAMPLE   Add-AdoWorkItemComment -Id 1234 -Text 'Reviewed and approved.'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Text,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id/comments?api-version=$ApiV-preview.3"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Comment on WI #$Id")) { return $null }

    return Invoke-AdoRequest -Method POST -Uri $uri -Body (@{ text = $Text } | ConvertTo-Json) `
        -ContentType 'application/json' -Headers $Headers
}

#endregion

#region -- Work Items: Links --

function Add-AdoWorkItemLink {
    <#
    .SYNOPSIS  Creates a link between two Work Items.
    .PARAMETER LinkType
        Common values:
          System.LinkTypes.Hierarchy-Forward  -> parent includes child
          System.LinkTypes.Related            -> related to
          System.LinkTypes.Duplicate-Forward  -> duplicate of
          Microsoft.VSTS.Common.TestedBy-Forward -> User Story tested by Test Case
    .EXAMPLE
        Add-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][int]$SourceId,
        [Parameter(Mandatory)][int]$TargetId,
        [Parameter(Mandatory)][string]$LinkType,
        [string]$Comment = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $ops = @(@{
        op    = 'add'
        path  = '/relations/-'
        value = @{
            rel        = $LinkType
            url        = "$(Get-AdoBaseUrl $Org)/_apis/wit/workitems/$TargetId"
            attributes = @{ comment = $Comment }
        }
    })
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$SourceId`?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "PATCH - Link #$SourceId -> #$TargetId [$LinkType]")) { return $null }

    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body ($ops | ConvertTo-Json -Depth 6) `
        -ContentType 'application/json-patch+json' -Headers $Headers
    Write-Host "(ok) Link created: #$SourceId -> #$TargetId [$LinkType]" -ForegroundColor Green
    return $r
}

#endregion

#region -- Work Items: Attachments --

function Add-AdoWorkItemAttachment {
    <#
    .SYNOPSIS  Uploads a local file and attaches it to an existing Work Item.
    .EXAMPLE   Add-AdoWorkItemAttachment -Id 1234 -FilePath 'C:\logs\error.log'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Comment = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }

    $fileName  = Split-Path $FilePath -Leaf
    $uploadUri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/attachments?fileName=$fileName&api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uploadUri, "POST - Upload '$fileName' and attach to WI #$Id")) { return $null }

    # 1. Upload the binary
    $uploadHdr = $Headers.Clone()
    $uploadHdr['Content-Type'] = 'application/octet-stream'
    $attachment = Invoke-RestMethod -Method POST -Uri $uploadUri `
        -Headers $uploadHdr -Body ([IO.File]::ReadAllBytes($FilePath)) -ErrorAction Stop

    # 2. Attach the reference to the Work Item
    $ops = @(@{
        op    = 'add'
        path  = '/relations/-'
        value = @{
            rel        = 'AttachedFile'
            url        = $attachment.url
            attributes = @{ comment = $Comment; name = $fileName }
        }
    })
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id`?api-version=$ApiV"
    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body ($ops | ConvertTo-Json -Depth 6) `
        -ContentType 'application/json-patch+json' -Headers $Headers
    Write-Host "(ok) '$fileName' attached to WI #$Id" -ForegroundColor Green
    return $r
}

#endregion

#region -- Test Runs --

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

#region -- Test Plans: Create --

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

#region -- Test Suites: Create --

function New-AdoTestSuite {
    <#
    .SYNOPSIS  Creates a new Test Suite inside an existing Test Plan.
    .PARAMETER PlanId        ID of the parent Test Plan (mandatory).
    .PARAMETER Name          Display name for the suite (mandatory).
    .PARAMETER ParentSuiteId ID of the parent suite (use the plan's rootSuite.id for top-level suites).
    .PARAMETER SuiteType     staticTestSuite (default) | requirementTestSuite | dynamicTestSuite.
    .PARAMETER QueryString   WIQL query string; only used when SuiteType is 'dynamicTestSuite'.
    .EXAMPLE
        # Top-level static suite (parentSuiteId = plan's rootSuite.id)
        New-AdoTestSuite -PlanId 1001 -Name 'Login module' -ParentSuiteId 1002

        # Dynamic query-based suite
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

#region -- Test Cases: Create --

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

    .EXAMPLE
        # WhatIf - no changes applied
        New-AdoTestCase -Title 'Draft test' -WhatIf
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

    # Build extra fields, handling TCM-specific ones
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

#endregion

#region -- Test Cases: Add to Suite --

function Add-AdoTestCaseToSuite {
    <#
    .SYNOPSIS  Adds one or more existing Test Case work items to a Test Suite.
    .PARAMETER PlanId       ID of the Test Plan.
    .PARAMETER SuiteId      ID of the target Test Suite.
    .PARAMETER TestCaseIds  Array of Test Case work item IDs to add.
    .EXAMPLE
        Add-AdoTestCaseToSuite -PlanId 1001 -SuiteId 1002 -TestCaseIds @(5010, 5011)
    .EXAMPLE
        # Pipe a just-created test case directly
        $tc = New-AdoTestCase -Title 'Verify logout' -Confirm:$false
        Add-AdoTestCaseToSuite -PlanId 1001 -SuiteId 1002 -TestCaseIds @($tc.id)
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
