<#
.DEPRECATED
  Functions in this file have been moved to domain-specific files:
    ado-workitems.ps1  — projects, teams, work items, WIQL
    ado-testing.ps1   — test plans, suites, test cases, test runs/results
    ado-pipelines.ps1 — pipelines and pipeline runs
    ado-git.ps1       — repositories, branches, iterations

  Load the skill via load.ps1 — it sources the domain files automatically.
  This file is kept for backward compatibility only and will be removed in a future version.

.SYNOPSIS
  READ operations on Azure DevOps REST API.
  All functions in this file are read-only: they do not modify data.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-read.ps1"
  $s = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Projects and organization --

function Get-AdoProjects {
    <#
    .SYNOPSIS  Lists all projects in the organization.
    .EXAMPLE   Get-AdoProjects | Select-Object name, state | Format-Table -AutoSize
    #>
    param(
        [string]$Org  = $script:AdoSession.Org,
        [string]$ApiV = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/_apis/projects?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoTeams {
    <#
    .SYNOPSIS  Lists teams in a project.
    #>
    param(
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/_apis/projects/$Project/teams?api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion

#region -- Work Items --

function Get-AdoWorkItem {
    <#
    .SYNOPSIS  Gets a Work Item by ID with all its fields and relations.
    .PARAMETER Expand  None | Relations | Fields | Links | All  (default: All)
    .EXAMPLE   $wi = Get-AdoWorkItem -Id 1234
               "$($wi.id) | $($wi.fields.'System.Title') | $($wi.fields.'System.State')"
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Expand  = 'All',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id`?`$expand=$Expand&api-version=$ApiV"
    return Invoke-AdoGet -Uri $uri -Headers $Headers
}

function Get-AdoWorkItemsBatch {
    <#
    .SYNOPSIS  Gets up to 200 Work Items in a single call.
    .PARAMETER Fields  Optional: array of field names. If omitted, returns all fields.
    .EXAMPLE   Get-AdoWorkItemsBatch -Ids @(100,101,102) | Select-Object id, @{n='T';e={$_.fields.'System.Title'}}
    #>
    param(
        [Parameter(Mandatory)][int[]]$Ids,
        [string[]]$Fields,
        [string]$Expand  = 'All',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitemsbatch?api-version=$ApiV"
    $body = @{ ids = $Ids; '$expand' = $Expand }
    if ($Fields) { $body.fields = $Fields }
    # Read-only POST: call Invoke-AdoRequest directly (not ShouldProcess)
    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 5) `
        -ContentType 'application/json' -Headers $Headers
    return $r.value
}

function Get-AdoWorkItemComments {
    <#
    .SYNOPSIS  Returns the comments of a Work Item.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id/comments?api-version=$ApiV-preview.3"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers
    return $r.comments
}

function Get-AdoWorkItemRevisions {
    <#
    .SYNOPSIS  Returns the revision history (field changes) of a Work Item.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/$Id/revisions?api-version=$ApiV"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers
    return $r.value
}

#endregion

#region -- WIQL --

function Invoke-AdoWiql {
    <#
    .SYNOPSIS  Executes a WIQL query and returns Work Items with their fields.
    .NOTES     WIQL uses POST internally, but is a read-only operation.
    .EXAMPLE
        Invoke-AdoWiql -Query "SELECT [System.Id],[System.Title] FROM WorkItems WHERE [System.State] = 'Active'"
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$Top        = 100,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/wiql?`$top=$Top&api-version=$ApiV"
    $body = @{ query = $Query } | ConvertTo-Json
    $r    = Invoke-AdoRequest -Method POST -Uri $uri -Body $body `
        -ContentType 'application/json' -Headers $Headers
    if (-not $r.workItems -or $r.workItems.Count -eq 0) { return @() }
    $ids  = $r.workItems | Select-Object -ExpandProperty id
    return Get-AdoWorkItemsBatch -Ids $ids -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
}

#endregion

#region -- Iterations / Sprints --

function Get-AdoIterations {
    <#
    .SYNOPSIS  Lists team iterations.
    .PARAMETER TimeFrame  current | past | future  (empty = all)
    .EXAMPLE   Get-AdoIterations -TimeFrame current
    #>
    param(
        [string]$Team      = '',
        [string]$TimeFrame = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $teamSeg = if ($Team) { "/$Team" } else { '' }
    $tfParam = if ($TimeFrame) { "&`$timeframe=$TimeFrame" } else { '' }
    $uri = "$(Get-AdoBaseUrl $Org)/$Project$teamSeg/_apis/work/teamsettings/iterations?api-version=$ApiV$tfParam"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers
    return $r.value
}

#endregion

#region -- Test Plans and Suites --

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

function Get-AdoTestSuites {
    <#
    .SYNOPSIS  Lists the Test Suites of a Test Plan.
    #>
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans/$PlanId/suites?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoTestCases {
    <#
    .SYNOPSIS  Lists the Test Cases of a Suite.
    #>
    param(
        [Parameter(Mandatory)][int]$PlanId,
        [Parameter(Mandatory)][int]$SuiteId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/testplan/plans/$PlanId/suites/$SuiteId/testcase?api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion

#region -- Test Runs and Results --

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

#region -- Git Repositories --

function Get-AdoRepositories {
    <#
    .SYNOPSIS  Lists Git repositories in the project.
    #>
    param(
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/repositories?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoBranches {
    <#
    .SYNOPSIS  Lists branches of a Git repository.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/repositories/$RepoId/refs?filter=heads/&api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion

#region -- Pipelines --

function Get-AdoPipelines {
    <#
    .SYNOPSIS  Lists pipelines (build definitions) in the project.
    #>
    param(
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/pipelines?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoPipelineRuns {
    <#
    .SYNOPSIS  Returns the latest runs of a pipeline.
    #>
    param(
        [Parameter(Mandatory)][int]$PipelineId,
        [int]$Top    = 10,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/pipelines/$PipelineId/runs?`$top=$Top&api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion
