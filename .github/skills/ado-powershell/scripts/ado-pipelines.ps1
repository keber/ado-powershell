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

# StrictMode / ErrorActionPreference are set inside each function, not here: this file is dot-sourced and must not alter the caller session.

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
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    return Invoke-AdoGetPaged -Uri "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/pipelines?api-version=$ApiV" -Headers $Headers
}

function Get-AdoPipelineRuns {
    <#
    .SYNOPSIS  Returns recent runs of a pipeline with optional filters.
    .DESCRIPTION
        The Pipelines Runs - List API (7.1) supports no filter parameters, and its items
        carry no 'resources' (so no branch), so State/Result/date filters are applied
        client-side on the runs it returns. -Branch is resolved server-side with the Build
        API (Builds - List, definitions={PipelineId}&branchName=...; a YAML pipeline id equals
        its build definition id) and intersected with the run list by run id. Output is always
        the Pipelines API run object. -Branch therefore needs Build (read) scope in addition
        to Pipelines. Results are ordered most recent first (by createdDate) before -Top.
    .PARAMETER Top          Maximum number of runs to return after filtering.
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
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    # Runs - List (7.1) documents only api-version, so State/Result/date filters are applied client-side.
    $uri = "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/pipelines/$PipelineId/runs?api-version=$ApiV"
    $r = Invoke-AdoGet -Uri $uri -Headers $Headers
    $runs = @(if ($r.PSObject.Properties['value']) { $r.value })

    # Branch is not available on Runs - List items: ask the Build API which builds (== runs,
    # same id) belong to the branch. No $top is sent so -Top applies after all other filters.
    $branchIds = $null
    if ($Branch) {
        $full = if ($Branch -like 'refs/*') { $Branch } else { "refs/heads/$Branch" }
        $bUri = "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/build/builds" +
                "?definitions=$PipelineId&branchName=$([uri]::EscapeDataString($full))&api-version=$ApiV"
        $b = Invoke-AdoGet -Uri $bUri -Headers $Headers
        $branchIds = @{}
        if ($b.PSObject.Properties['value']) { foreach ($x in @($b.value)) { $branchIds["$($x.id)"] = $true } }
    }

    # StrictMode-safe property read: returns $null when a property is missing.
    $prop = { param($o, $n) if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $toDate = {
        param($v)
        if ($null -eq $v -or "$v" -eq '') { return $null }
        if ($v -is [datetime]) { return ([datetimeoffset]$v).UtcDateTime }
        $d = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse("$v", [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.UtcDateTime }
        throw "Invalid date value: '$v'"
    }

    $fromDate = & $toDate $CreatedFrom
    $toDateV  = & $toDate $CreatedTo

    $filtered = foreach ($run in $runs) {
        if ($State  -and (& $prop $run 'state')  -ine $State)  { continue }
        if ($Result -and (& $prop $run 'result') -ine $Result) { continue }
        if ($null -ne $branchIds -and -not $branchIds.ContainsKey("$(& $prop $run 'id')")) { continue }
        $created = & $toDate (& $prop $run 'createdDate')
        if ($fromDate -or $toDateV) {
            if ($null -eq $created) { continue }
            if ($fromDate -and $created -lt $fromDate) { continue }
            if ($toDateV  -and $created -gt $toDateV)  { continue }
        }
        [pscustomobject]@{ Run = $run; Created = $created }
    }
    # Most recent first (runs without createdDate last), then take -Top.
    $sorted = @($filtered | Sort-Object { if ($null -eq $_.Created) { [datetime]::MinValue } else { $_.Created } } -Descending)
    return @($sorted | Select-Object -First $Top | ForEach-Object { $_.Run })
}

#endregion

#region -- Pipelines: Trigger --

function Invoke-AdoPipelineRun {
    <#
    .SYNOPSIS  Triggers a pipeline run and returns the created run object.
    .DESCRIPTION  ConfirmImpact is High (a run may deploy), so the default $ConfirmPreference
                  prompts before queuing. Pass -Confirm:$false in unattended scripts/agents;
                  use -WhatIf to simulate.
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
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
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
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $body = @{}
    if ($Branch)                        { $body.resources   = @{ repositories = @{ self = @{ refName = "refs/heads/$($Branch -replace '^refs/heads/', '')" } } } }
    if ($Variables.Count -gt 0)         { $body.variables   = $Variables          }
    if ($TemplateParameters.Count -gt 0){ $body.templateParameters = $TemplateParameters }
    if ($StagesToSkip.Count -gt 0)      { $body.stagesToSkip = $StagesToSkip      }

    $uri = "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/pipelines/$PipelineId/runs?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Trigger Pipeline $PipelineId$(if($Branch){" on branch '$Branch'"})")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 6) -Headers $Headers
    Write-Host "(ok) Pipeline run triggered - Run ID: $($r.id) | State: $($r.state)" -ForegroundColor Green
    return $r
}

#endregion
