<#
.SYNOPSIS
  Pull request operations on Azure DevOps REST API (Git, api-version 7.1).
  Covers listing, creating, editing, abandoning, reactivating, completing and auto-completing
  pull requests, and reviewers / votes.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-pullrequests.ps1"
  $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'

.NOTES
  Reference: https://learn.microsoft.com/rest/api/azure/devops/git/pull-requests?view=azure-devops-rest-7.1
  Write functions implement [CmdletBinding(SupportsShouldProcess)] and go through
  Invoke-AdoRequest, so they are refused on a session initialised with -Access Read.
  -RepoId accepts a repository name or id, like Get-AdoBranches.
#>

# StrictMode / ErrorActionPreference are set inside each function, not here: this file is dot-sourced and must not alter the caller session.

#region -- Helpers --

function ConvertTo-AdoRefName {
    <#
    .SYNOPSIS  Normalises a branch name to a full ref: 'main' and 'refs/heads/main' both give 'refs/heads/main'.
    .NOTES     Only the exact, case-sensitive 'refs/heads/' prefix is recognised (see #2); anything
               else is treated as a branch name and prefixed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Branch)
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'ConvertTo-AdoRefName: branch name is empty.' }
    if ($Branch.StartsWith('refs/heads/', [StringComparison]::Ordinal)) { return $Branch }
    return "refs/heads/$Branch"
}

function Get-AdoPullRequestRepoUri {
    <#
    .SYNOPSIS  Internal: base URI of a repository's Git API (repository name or id is URI-escaped).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    return "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/repositories/$([uri]::EscapeDataString($RepoId))"
}

function Get-AdoCurrentUserId {
    <#
    .SYNOPSIS
      Returns the id of the authenticated identity (PAT owner, build identity, or Entra principal).
    .DESCRIPTION
      Reads authenticatedUser.id from the organization-level _apis/connectionData endpoint and caches
      it on the session (AuthenticatedUserId) so it is resolved once per session. Throws a clear
      error when the id cannot be resolved.
    .PARAMETER Force  Ignore the cached value and query again.
    #>
    param(
        [string]$Org        = $script:AdoSession.Org,
        [hashtable]$Headers = $script:AdoSession.Headers,
        [switch]$Force
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    $session = $null
    try { $session = $script:AdoSession } catch { $session = $null }
    $sameOrg = $null -ne $session -and $session.PSObject.Properties['Org'] -and $session.Org -eq $Org

    if ($sameOrg -and -not $Force) {
        $cached = $session.PSObject.Properties['AuthenticatedUserId']
        if ($cached -and $cached.Value) { return [string]$cached.Value }
    }

    $uri = "$(Get-AdoBaseUrl $Org)/_apis/connectionData"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers

    $id = $null
    $userProp = if ($null -ne $r) { $r.PSObject.Properties['authenticatedUser'] } else { $null }
    if ($userProp -and $null -ne $userProp.Value) {
        $idProp = $userProp.Value.PSObject.Properties['id']
        if ($idProp -and $idProp.Value) { $id = [string]$idProp.Value }
    }
    if (-not $id) {
        throw ("Could not resolve the authenticated user id from $uri (no authenticatedUser.id). " +
               'Pass -ReviewerId explicitly.')
    }

    if ($sameOrg) {
        $session | Add-Member -NotePropertyName AuthenticatedUserId -NotePropertyValue $id -Force
    }
    return $id
}

function Invoke-AdoGetSkipPaged {
    <#
    .SYNOPSIS  Internal: GETs a list endpoint paged with $top / $skip and collects every page.
    .PARAMETER Uri       URL including api-version; must not carry $top / $skip.
    .PARAMETER PageSize  Items per request.
    .PARAMETER MaxItems  Stop after this many items (0 = no limit).
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [int]$PageSize = 100,
        [int]$MaxItems = 0
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($PageSize -lt 1) { throw 'PageSize must be at least 1.' }
    if ($MaxItems -gt 0 -and $MaxItems -lt $PageSize) { $PageSize = $MaxItems }

    $items = [System.Collections.Generic.List[object]]::new()
    $skip  = 0
    $sep   = if ($Uri.Contains('?')) { '&' } else { '?' }
    while ($true) {
        $r = Invoke-AdoGet -Uri "$Uri$sep`$top=$PageSize&`$skip=$skip" -Headers $Headers
        $page = @()
        $vp = if ($null -ne $r) { $r.PSObject.Properties['value'] } else { $null }
        if ($vp -and $null -ne $vp.Value) { $page = @($vp.Value) }
        foreach ($i in $page) { $items.Add($i) }

        if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) {
            if ($items.Count -gt $MaxItems) { $items.RemoveRange($MaxItems, $items.Count - $MaxItems) }
            break
        }
        if ($page.Count -lt $PageSize) { break }
        $skip += $page.Count
    }
    return $items.ToArray()
}

#endregion

#region -- Pull requests --

function Get-AdoPullRequests {
    <#
    .SYNOPSIS  Lists pull requests of a repository, following $top/$skip paging.
    .PARAMETER RepoId        Repository name or id.
    .PARAMETER Status        active (API default) | abandoned | completed | all | notSet.
    .PARAMETER CreatorId     Identity id of the creator.
    .PARAMETER ReviewerId    Identity id of a reviewer.
    .PARAMETER SourceBranch  'feature/x' or 'refs/heads/feature/x'.
    .PARAMETER TargetBranch  'main' or 'refs/heads/main'.
    .PARAMETER Top           Maximum number of pull requests returned (0 = all).
    .PARAMETER PageSize      Items per request (default 100).
    .EXAMPLE   Get-AdoPullRequests -RepoId 'MyRepo' -Status active -TargetBranch main
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [ValidateSet('active', 'abandoned', 'completed', 'all', 'notSet')]
        [string]$Status       = '',
        [string]$CreatorId    = '',
        [string]$ReviewerId   = '',
        [string]$SourceBranch = '',
        [string]$TargetBranch = '',
        [int]$Top      = 0,
        [int]$PageSize = 100,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $q = [System.Collections.Generic.List[string]]::new()
    if ($Status)       { $q.Add("searchCriteria.status=$Status") }
    if ($CreatorId)    { $q.Add("searchCriteria.creatorId=$([uri]::EscapeDataString($CreatorId))") }
    if ($ReviewerId)   { $q.Add("searchCriteria.reviewerId=$([uri]::EscapeDataString($ReviewerId))") }
    if ($SourceBranch) { $q.Add("searchCriteria.sourceRefName=$([uri]::EscapeDataString((ConvertTo-AdoRefName $SourceBranch)))") }
    if ($TargetBranch) { $q.Add("searchCriteria.targetRefName=$([uri]::EscapeDataString((ConvertTo-AdoRefName $TargetBranch)))") }
    $q.Add("api-version=$ApiV")
    $uri = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests?$($q -join '&')"
    return Invoke-AdoGetSkipPaged -Uri $uri -Headers $Headers -PageSize $PageSize -MaxItems $Top
}

function Get-AdoPullRequest {
    <#
    .SYNOPSIS  Gets one pull request. Without -RepoId the project-level route (by id only) is used.
    .EXAMPLE   Get-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -IncludeWorkItemRefs
    #>
    param(
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$RepoId = '',
        [switch]$IncludeCommits,
        [switch]$IncludeWorkItemRefs,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($RepoId) {
        $uri = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId`?api-version=$ApiV"
        if ($IncludeCommits)      { $uri += '&includeCommits=true' }
        if ($IncludeWorkItemRefs) { $uri += '&includeWorkItemRefs=true' }
    } else {
        $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/git/pullrequests/$PullRequestId`?api-version=$ApiV"
    }
    return Invoke-AdoGet -Uri $uri -Headers $Headers
}

function New-AdoPullRequest {
    <#
    .SYNOPSIS  Creates a pull request.
    .PARAMETER ReviewerIds          Optional reviewers (identity ids).
    .PARAMETER RequiredReviewerIds  Required reviewers (identity ids).
    .PARAMETER WorkItemIds          Work items to link.
    .PARAMETER Labels               Label (tag) names.
    .EXAMPLE
      New-AdoPullRequest -RepoId 'MyRepo' -SourceBranch 'feature/x' -TargetBranch 'main' `
          -Title 'Add X' -Description 'Details' -WorkItemIds 1234 -Draft
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$SourceBranch,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$Title,
        [string]$Description = '',
        [switch]$Draft,
        [string[]]$ReviewerIds         = @(),
        [string[]]$RequiredReviewerIds = @(),
        [int[]]$WorkItemIds            = @(),
        [string[]]$Labels              = @(),
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $body = [ordered]@{
        sourceRefName = ConvertTo-AdoRefName $SourceBranch
        targetRefName = ConvertTo-AdoRefName $TargetBranch
        title         = $Title
        description   = $Description
        isDraft       = [bool]$Draft
    }
    $reviewers = @()
    foreach ($id in $ReviewerIds)         { $reviewers += @{ id = $id; isRequired = $false } }
    foreach ($id in $RequiredReviewerIds) { $reviewers += @{ id = $id; isRequired = $true } }
    if ($reviewers.Count -gt 0)   { $body.reviewers    = $reviewers }
    if ($WorkItemIds.Count -gt 0) { $body.workItemRefs = @($WorkItemIds | ForEach-Object { @{ id = [string]$_ } }) }
    if ($Labels.Count -gt 0)      { $body.labels       = @($Labels | ForEach-Object { @{ name = $_ } }) }

    $uri = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests?api-version=$ApiV"
    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create PR '$Title' ($($body.sourceRefName) -> $($body.targetRefName))")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 6) -Headers $Headers
    $idProp = if ($null -ne $r) { $r.PSObject.Properties['pullRequestId'] } else { $null }
    Write-Host "(ok) Pull request created - ID: $(if ($idProp) { $idProp.Value })" -ForegroundColor Green
    return $r
}

function Get-AdoPullRequestUri {
    <#
    .SYNOPSIS  Internal: URI of one pull request (repository route), optionally with a sub-resource.
    .NOTES     Writes call Invoke-AdoRequest themselves, inside their ShouldProcess function, so the
               Read-session guard and -WhatIf apply where the write is decided.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$SubPath = '',
        [string]$Org, [string]$Project, [string]$ApiV
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $sub = if ($SubPath) { "/$SubPath" } else { '' }
    return "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId$sub`?api-version=$ApiV"
}

function Set-AdoPullRequest {
    <#
    .SYNOPSIS  Edits a pull request: title, description, draft state, target branch (retarget).
    .PARAMETER Draft    Turn the PR back into a draft (isDraft = true).
    .PARAMETER Publish  Publish a draft PR (isDraft = false).
    .PARAMETER TargetBranch  Retarget; requires the PR retargeting feature on the organization.
    .EXAMPLE   Set-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -Publish
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$Title,
        [string]$Description,
        [switch]$Draft,
        [switch]$Publish,
        [string]$TargetBranch,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($Draft -and $Publish) { throw 'Set-AdoPullRequest: -Draft and -Publish are mutually exclusive.' }

    $body = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('Title'))       { $body.title       = $Title }
    if ($PSBoundParameters.ContainsKey('Description')) { $body.description = $Description }
    if ($Draft)        { $body.isDraft = $true }
    if ($Publish)      { $body.isDraft = $false }
    if ($TargetBranch) { $body.targetRefName = ConvertTo-AdoRefName $TargetBranch }
    if ($body.Count -eq 0) {
        throw 'Set-AdoPullRequest: Nothing to update. Pass -Title, -Description, -Draft, -Publish or -TargetBranch.'
    }

    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PATCH - Update $($body.Keys -join ', ')")) { return $null }
    return Invoke-AdoRequest -Method PATCH -Headers $Headers -Body (ConvertTo-Json -InputObject $body -Depth 6) `
        -Uri (Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -Org $Org -Project $Project -ApiV $ApiV)
}

function Stop-AdoPullRequest {
    <#
    .SYNOPSIS  Abandons a pull request (status = abandoned).
    .EXAMPLE   Stop-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", 'PATCH - Abandon')) { return $null }
    $r = Invoke-AdoRequest -Method PATCH -Headers $Headers -Body (ConvertTo-Json -InputObject @{ status = 'abandoned' } -Depth 6) `
        -Uri (Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -Org $Org -Project $Project -ApiV $ApiV)
    Write-Host "(ok) Pull request #$PullRequestId abandoned" -ForegroundColor Green
    return $r
}

function Restore-AdoPullRequest {
    <#
    .SYNOPSIS  Reactivates an abandoned pull request (status = active).
    .EXAMPLE   Restore-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", 'PATCH - Reactivate')) { return $null }
    return Invoke-AdoRequest -Method PATCH -Headers $Headers -Body (ConvertTo-Json -InputObject @{ status = 'active' } -Depth 6) `
        -Uri (Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -Org $Org -Project $Project -ApiV $ApiV)
}

function New-AdoCompletionOptions {
    <#
    .SYNOPSIS  Internal: builds GitPullRequestCompletionOptions.
    #>
    param(
        [string]$MergeStrategy = 'noFastForward',
        [bool]$DeleteSourceBranch,
        [bool]$TransitionWorkItems,
        [string]$MergeCommitMessage = ''
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $o = [ordered]@{
        mergeStrategy       = $MergeStrategy
        deleteSourceBranch  = $DeleteSourceBranch
        transitionWorkItems = $TransitionWorkItems
    }
    if ($MergeCommitMessage) { $o.mergeCommitMessage = $MergeCommitMessage }
    return $o
}

function Complete-AdoPullRequest {
    <#
    .SYNOPSIS  Completes (merges) a pull request.
    .DESCRIPTION
      PATCHes status = completed with lastMergeSourceCommit and completionOptions. When
      -LastMergeSourceCommitId is omitted, the PR is fetched first and its current
      lastMergeSourceCommit is used; ADO rejects the completion if the source moved since.
      A 409 Conflict (merge conflicts, policies, source changed) is thrown with ErrorId
      AdoPullRequestConflict and the server's message.
    .PARAMETER MergeStrategy  noFastForward (default) | squash | rebase | rebaseMerge.
    .EXAMPLE   Complete-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42 -MergeStrategy squash -DeleteSourceBranch
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$LastMergeSourceCommitId = '',
        [ValidateSet('noFastForward', 'squash', 'rebase', 'rebaseMerge')]
        [string]$MergeStrategy = 'noFastForward',
        [switch]$DeleteSourceBranch,
        [switch]$TransitionWorkItems,
        [string]$MergeCommitMessage = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    if (-not $LastMergeSourceCommitId) {
        $pr = Get-AdoPullRequest -RepoId $RepoId -PullRequestId $PullRequestId `
            -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
        $lp = if ($null -ne $pr) { $pr.PSObject.Properties['lastMergeSourceCommit'] } else { $null }
        if ($lp -and $null -ne $lp.Value -and $lp.Value.PSObject.Properties['commitId']) {
            $LastMergeSourceCommitId = [string]$lp.Value.commitId
        }
        if (-not $LastMergeSourceCommitId) {
            throw "Complete-AdoPullRequest: PR #$PullRequestId has no lastMergeSourceCommit; pass -LastMergeSourceCommitId."
        }
    }

    $body = [ordered]@{
        status                = 'completed'
        lastMergeSourceCommit = @{ commitId = $LastMergeSourceCommitId }
        completionOptions     = New-AdoCompletionOptions -MergeStrategy $MergeStrategy `
                                    -DeleteSourceBranch ([bool]$DeleteSourceBranch) `
                                    -TransitionWorkItems ([bool]$TransitionWorkItems) `
                                    -MergeCommitMessage $MergeCommitMessage
    }

    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PATCH - Complete ($MergeStrategy) at $LastMergeSourceCommitId")) { return $null }

    try {
        $r = Invoke-AdoRequest -Method PATCH -Headers $Headers -Body (ConvertTo-Json -InputObject $body -Depth 6) `
            -Uri (Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -Org $Org -Project $Project -ApiV $ApiV)
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -ne 409) { throw }
        $detail = ''
        try {
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $detail = [string]$_.ErrorDetails.Message
                $j = $detail | ConvertFrom-Json -ErrorAction Stop
                if ($j -and $j.PSObject.Properties['message'] -and $j.message) { $detail = [string]$j.message }
            }
        } catch { }
        $msg = ("409 Conflict - pull request #$PullRequestId could not be completed (merge conflicts, " +
                "failing policies, or the source branch changed since $LastMergeSourceCommitId). $detail").Trim()
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($msg), 'AdoPullRequestConflict',
            [System.Management.Automation.ErrorCategory]::ResourceExists, $PullRequestId)
    }
    Write-Host "(ok) Pull request #$PullRequestId completed ($MergeStrategy)" -ForegroundColor Green
    return $r
}

function Set-AdoPullRequestAutoComplete {
    <#
    .SYNOPSIS  Enables auto-complete as the current user, or disables it with -Disable.
    .DESCRIPTION
      Enabling sets autoCompleteSetBy to the authenticated user (Get-AdoCurrentUserId) together with
      completionOptions. -Disable sends autoCompleteSetBy with the empty GUID.
    .EXAMPLE   Set-AdoPullRequestAutoComplete -RepoId 'MyRepo' -PullRequestId 42 -MergeStrategy squash -DeleteSourceBranch
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [switch]$Disable,
        [ValidateSet('noFastForward', 'squash', 'rebase', 'rebaseMerge')]
        [string]$MergeStrategy = 'noFastForward',
        [switch]$DeleteSourceBranch,
        [switch]$TransitionWorkItems,
        [string]$MergeCommitMessage = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($Disable) {
        $body = [ordered]@{ autoCompleteSetBy = @{ id = [guid]::Empty.ToString() } }
        $action = 'PATCH - Disable auto-complete'
    } else {
        $body = [ordered]@{
            autoCompleteSetBy = @{ id = Get-AdoCurrentUserId -Org $Org -Headers $Headers }
            completionOptions = New-AdoCompletionOptions -MergeStrategy $MergeStrategy `
                                    -DeleteSourceBranch ([bool]$DeleteSourceBranch) `
                                    -TransitionWorkItems ([bool]$TransitionWorkItems) `
                                    -MergeCommitMessage $MergeCommitMessage
        }
        $action = "PATCH - Enable auto-complete ($MergeStrategy)"
    }
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", $action)) { return $null }
    return Invoke-AdoRequest -Method PATCH -Headers $Headers -Body (ConvertTo-Json -InputObject $body -Depth 6) `
        -Uri (Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -Org $Org -Project $Project -ApiV $ApiV)
}

#endregion

#region -- Reviewers and votes --

function Get-AdoPullRequestReviewers {
    <#
    .SYNOPSIS  Lists the reviewers of a pull request with their votes.
    .EXAMPLE   Get-AdoPullRequestReviewers -RepoId 'MyRepo' -PullRequestId 42 | Select-Object displayName, vote, isRequired
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId/reviewers?api-version=$ApiV"
    $r = Invoke-AdoGet -Uri $uri -Headers $Headers
    $vp = if ($null -ne $r) { $r.PSObject.Properties['value'] } else { $null }
    if ($vp) { return @($vp.Value) }
    return @()
}

function Add-AdoPullRequestReviewer {
    <#
    .SYNOPSIS  Adds a reviewer (optional by default, -Required for a required reviewer).
    .EXAMPLE   Add-AdoPullRequestReviewer -RepoId 'MyRepo' -PullRequestId 42 -ReviewerId $id -Required
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$ReviewerId,
        [switch]$Required,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri  = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId/reviewers/$([uri]::EscapeDataString($ReviewerId))?api-version=$ApiV"
    $body = @{ id = $ReviewerId; isRequired = [bool]$Required }
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PUT - Add $(if($Required){'required'}else{'optional'}) reviewer $ReviewerId")) { return $null }
    return Invoke-AdoRequest -Method PUT -Uri $uri -Body ($body | ConvertTo-Json) -Headers $Headers
}

function Remove-AdoPullRequestReviewer {
    <#
    .SYNOPSIS  Removes a reviewer from a pull request.
    .EXAMPLE   Remove-AdoPullRequestReviewer -RepoId 'MyRepo' -PullRequestId 42 -ReviewerId $id
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$ReviewerId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId/reviewers/$([uri]::EscapeDataString($ReviewerId))?api-version=$ApiV"
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "DELETE - Remove reviewer $ReviewerId")) { return $null }
    return Invoke-AdoRequest -Method DELETE -Uri $uri -Headers $Headers
}

function Set-AdoPullRequestVote {
    <#
    .SYNOPSIS  Casts a vote on a pull request, as the authenticated user by default.
    .PARAMETER Vote        Approve (10) | ApproveWithSuggestions (5) | NoVote (0) | WaitForAuthor (-5) | Reject (-10).
    .PARAMETER ReviewerId  Identity to vote as. Default: the authenticated user (resolved once per session).
    .EXAMPLE   Set-AdoPullRequestVote -RepoId 'MyRepo' -PullRequestId 42 -Vote WaitForAuthor
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)]
        [ValidateSet('Approve', 'ApproveWithSuggestions', 'NoVote', 'WaitForAuthor', 'Reject')]
        [string]$Vote,
        [string]$ReviewerId = '',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $values = @{ Approve = 10; ApproveWithSuggestions = 5; NoVote = 0; WaitForAuthor = -5; Reject = -10 }
    if (-not $ReviewerId) { $ReviewerId = Get-AdoCurrentUserId -Org $Org -Headers $Headers }

    $uri  = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId/reviewers/$([uri]::EscapeDataString($ReviewerId))?api-version=$ApiV"
    $body = @{ id = $ReviewerId; vote = $values[$Vote] }
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PUT - Vote $Vote ($($values[$Vote])) as $ReviewerId")) { return $null }
    return Invoke-AdoRequest -Method PUT -Uri $uri -Body ($body | ConvertTo-Json) -Headers $Headers
}

function Approve-AdoPullRequest {
    <#
    .SYNOPSIS  Approves a pull request as the authenticated user (vote 10). Shortcut for Set-AdoPullRequestVote -Vote Approve.
    .EXAMPLE   Approve-AdoPullRequest -RepoId 'MyRepo' -PullRequestId 42
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    # WhatIf / Confirm propagate automatically via $WhatIfPreference / $ConfirmPreference
    return Set-AdoPullRequestVote -RepoId $RepoId -PullRequestId $PullRequestId -Vote Approve `
        -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
}

#endregion
