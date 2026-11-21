<#
.SYNOPSIS
  Git and iteration operations on Azure DevOps REST API.
  Covers repositories, branches, and team iterations (sprints).

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-git.ps1"
  $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'
#>

# StrictMode / ErrorActionPreference are set inside each function, not here: this file is dot-sourced and must not alter the caller session.

#region -- Iterations / Sprints --

function Get-AdoIterations {
    <#
    .SYNOPSIS  Lists team iterations (sprints).
    .PARAMETER TimeFrame  current | past | future  (empty = all). The service only accepts
                          $timeframe=current, so past/future are filtered client-side on
                          attributes.timeFrame.
    .PARAMETER Team       Team name or ID. If omitted, uses the project default team.
    .EXAMPLE   Get-AdoIterations -TimeFrame current
    #>
    param(
        [string]$Team      = '',
        [ValidateSet('past', 'current', 'future')]
        [string]$TimeFrame = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $teamSeg = if ($Team) { "/$(ConvertTo-AdoPathSegment -Value $Team -Name 'team')" } else { '' }
    # The service rejects $timeframe=past|future with 400; only 'current' is a valid server-side filter.
    $tfParam = if ($TimeFrame -eq 'current') { "&`$timeframe=current" } else { '' }
    $uri = "$(Get-AdoProjectUrl -Org $Org -Project $Project)$teamSeg/_apis/work/teamsettings/iterations?api-version=$ApiV$tfParam"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers
    if ($TimeFrame -in 'past', 'future') {
        return @($r.value | Where-Object {
            $_.PSObject.Properties['attributes'] -and $_.attributes -and
            $_.attributes.PSObject.Properties['timeFrame'] -and $_.attributes.timeFrame -eq $TimeFrame
        })
    }
    return $r.value
}

#endregion

#region -- Git Repositories --

function Get-AdoRepositories {
    <#
    .SYNOPSIS  Lists Git repositories in the project.
    .EXAMPLE   Get-AdoRepositories | Select-Object id, name, remoteUrl
    #>
    param(
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $r = Invoke-AdoGet -Uri "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/git/repositories?api-version=$ApiV" -Headers $Headers
    return $r.value
}

function Get-AdoBranches {
    <#
    .SYNOPSIS  Lists branches (refs) of a Git repository.
    .PARAMETER RepoId  Repository ID or name (mandatory).
    .EXAMPLE
        $repo = Get-AdoRepositories | Where-Object name -eq 'MyRepo'
        Get-AdoBranches -RepoId $repo.id | Select-Object name
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    return Invoke-AdoGetPaged -Uri "$(Get-AdoProjectUrl -Org $Org -Project $Project)/_apis/git/repositories/$(ConvertTo-AdoPathSegment -Value $RepoId -Name 'repository')/refs?filter=heads/&api-version=$ApiV" -Headers $Headers
}

#endregion
