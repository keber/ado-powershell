<#
.SYNOPSIS
  Pipeline operations on Azure DevOps REST API.
  Covers listing pipelines, querying runs, and triggering new runs.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.SAFETY
  Read functions have no side effects.
  Invoke-AdoPipelineRun triggers a real pipeline run; use -WhatIf to simulate.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-pipelines.ps1"
  $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Pipelines: Read --

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
    .SYNOPSIS  Returns recent runs of a pipeline with optional filters.
    .PARAMETER Branch       Filter by branch name (e.g. 'main' or 'refs/heads/feature/x').
    .PARAMETER State        Filter by run state: notStarted | inProgress | completed.
    .PARAMETER Result       Filter by result: succeeded | failed | canceled | partiallySucceeded.
    .PARAMETER CreatedFrom  ISO-8601 lower bound for run creation date.
    .PARAMETER CreatedTo    ISO-8601 upper bound for run creation date.
    .EXAMPLE
        Get-AdoPipelineRuns -PipelineId 12 -Top 5 -Branch 'main' -Result 'failed'
    #>
    param(
        [Parameter(Mandatory)][int]$PipelineId,
        [int]$Top             = 10,
        [string]$Branch       = '',
        [string]$State        = '',
        [string]$Result       = '',
        [string]$CreatedFrom  = '',
        [string]$CreatedTo    = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/pipelines/$PipelineId/runs?`$top=$Top&api-version=$ApiV"
    if ($Branch)      { $uri += "&branchName=$([Uri]::EscapeDataString($Branch))" }
    if ($State)       { $uri += "&runStateFilter=$State"  }
    if ($Result)      { $uri += "&runResultFilter=$Result" }
    if ($CreatedFrom) { $uri += "&minTime=$([Uri]::EscapeDataString($CreatedFrom))" }
    if ($CreatedTo)   { $uri += "&maxTime=$([Uri]::EscapeDataString($CreatedTo))"   }
    $r = Invoke-AdoGet -Uri $uri -Headers $Headers
    return $r.value
}

#endregion

#region -- Pipelines: Trigger --

function Invoke-AdoPipelineRun {
    <#
    .SYNOPSIS  Triggers a pipeline run and returns the created run object.
    .PARAMETER PipelineId          ID of the pipeline to trigger (mandatory).
    .PARAMETER Branch              Branch to run on (e.g. 'main', 'feature/my-branch').
    .PARAMETER Variables           Hashtable of runtime variables.
                                   Each key maps to @{ value='...'; isSecret=$false }.
    .PARAMETER TemplateParameters  Hashtable of template parameters (for YAML template pipelines).
    .PARAMETER StagesToSkip        Array of stage names to skip.
    .EXAMPLE
        # Trigger on default branch
        Invoke-AdoPipelineRun -PipelineId 4 -Confirm:$false

        # Trigger on a feature branch with a variable
        Invoke-AdoPipelineRun -PipelineId 4 -Branch 'feature/my-branch' `
            -Variables @{ deployEnv = @{ value = 'staging'; isSecret = $false } } `
            -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][int]$PipelineId,
        [string]$Branch = '',
        [hashtable]$Variables           = @{},
        [hashtable]$TemplateParameters  = @{},
        [string[]]$StagesToSkip         = @(),
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )

    $body = @{}
    if ($Branch)                        { $body.resources   = @{ repositories = @{ self = @{ refName = "refs/heads/$($Branch.TrimStart('refs/heads/'))" } } } }
    if ($Variables.Count -gt 0)         { $body.variables   = $Variables          }
    if ($TemplateParameters.Count -gt 0){ $body.templateParameters = $TemplateParameters }
    if ($StagesToSkip.Count -gt 0)      { $body.stagesToSkip = $StagesToSkip      }

    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/pipelines/$PipelineId/runs?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Trigger Pipeline $PipelineId$(if($Branch){" on branch '$Branch'"})")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 6) -Headers $Headers
    Write-Host "(ok) Pipeline run triggered - Run ID: $($r.id) | State: $($r.state)" -ForegroundColor Green
    return $r
}

#endregion
