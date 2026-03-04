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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Iterations / Sprints --

function Get-AdoIterations {
    <#
    .SYNOPSIS  Lists team iterations (sprints).
    .PARAMETER TimeFrame  current | past | future  (empty = all)
    .PARAMETER Team       Team name or ID. If omitted, uses the project default team.
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
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/repositories?api-version=$ApiV" -Headers $Headers
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
    $r = Invoke-AdoGet -Uri "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/repositories/$RepoId/refs?filter=heads/&api-version=$ApiV" -Headers $Headers
    return $r.value
}

#endregion
