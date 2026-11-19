<#
.SYNOPSIS
  Pull request operations on Azure DevOps REST API (Git, api-version 7.1).
  Covers listing, creating, editing, abandoning, reactivating, completing and auto-completing
  pull requests; reviewers / votes; comment threads; iterations, changes, commits and linked
  work items; labels and statuses.

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
      it on the session (AuthenticatedUserId, plus AuthenticatedUserKey: a SHA-256 fingerprint of
      org + Authorization) so it is resolved once per session credential. Explicit -Headers that
      differ from the session's are resolved on every call and never touch the cache. Throws a
      clear error when the id cannot be resolved.
    .PARAMETER Force  Ignore the cached value and query again.
    #>
    param(
        [string]$Org        = $script:AdoSession.Org,
        [hashtable]$Headers = $script:AdoSession.Headers,
        [switch]$Force
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'

    # The session cache is used and written only when the effective credential is the session's
    # own (same org, same Authorization value). It is keyed by a SHA-256 fingerprint of org +
    # Authorization, so replacing the session headers in place invalidates it; the raw header is
    # never stored. Explicit -Headers of another credential always resolve their own id.
    $session = $null
    try { $session = $script:AdoSession } catch { $session = $null }
    $authOf = {
        param($h)
        if ($h -is [System.Collections.IDictionary] -and $h.Contains('Authorization')) { [string]$h['Authorization'] } else { '' }
    }
    $effectiveAuth = & $authOf $Headers
    $useCache = $false
    if ($null -ne $session -and $effectiveAuth -and
        $session.PSObject.Properties['Org'] -and $session.Org -eq $Org -and
        $session.PSObject.Properties['Headers']) {
        $useCache = [string]::Equals((& $authOf $session.Headers), $effectiveAuth, [StringComparison]::Ordinal)
    }
    $fingerprint = $null
    if ($useCache) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Org`n$effectiveAuth"))
            $fingerprint = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        } finally { $sha.Dispose() }

        if (-not $Force) {
            $cachedId  = $session.PSObject.Properties['AuthenticatedUserId']
            $cachedKey = $session.PSObject.Properties['AuthenticatedUserKey']
            if ($cachedId -and $cachedId.Value -and $cachedKey -and $cachedKey.Value -eq $fingerprint) {
                return [string]$cachedId.Value
            }
        }
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

    if ($useCache) {
        $session | Add-Member -NotePropertyName AuthenticatedUserId  -NotePropertyValue $id -Force
        $session | Add-Member -NotePropertyName AuthenticatedUserKey -NotePropertyValue $fingerprint -Force
    }
    return $id
}

function Get-AdoCanonicalValue {
    <#
    .SYNOPSIS  Internal: returns the documented spelling of a ValidateSet value (ValidateSet is case-insensitive).
    #>
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string[]]$Allowed
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    foreach ($a in $Allowed) { if ($a -eq $Value) { return $a } }
    throw "Unexpected value '$Value'. Allowed: $($Allowed -join ', ')"
}

function Get-AdoValueList {
    <#
    .SYNOPSIS  Internal: returns the 'value' array of a list response, or an empty array (StrictMode safe).
    #>
    param([Parameter(Position = 0)][AllowNull()][object]$Response)
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $vp = if ($null -ne $Response) { $Response.PSObject.Properties['value'] } else { $null }
    if ($vp -and $null -ne $vp.Value) { return @($vp.Value) }
    return @()
}

function Get-AdoPageSignature {
    <#
    .SYNOPSIS  Internal: cheap signature of a page of items, used to detect a server that repeats a page.
    .DESCRIPTION
      Uses each item's identifying property (pullRequestId, id, commitId, changeId - first one
      present); without one, falls back to the item's top-level scalar properties. Nested objects
      are never serialized (PowerShell 7's ConvertTo-Json warns when they exceed -Depth).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Page)
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $parts = foreach ($item in $Page) {
        if ($null -eq $item) { '<null>'; continue }
        if ($item -is [string] -or $item -is [ValueType]) { "v:$item"; continue }
        $sig = $null
        foreach ($name in 'pullRequestId', 'id', 'commitId', 'changeId') {
            $p = $item.PSObject.Properties[$name]
            if ($p -and $null -ne $p.Value) { $sig = "${name}:$($p.Value)"; break }
        }
        if (-not $sig) {
            $scalars = foreach ($p in $item.PSObject.Properties) {
                $v = $p.Value
                if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { "$($p.Name)=$v" }
            }
            $sig = 's:' + (@($scalars) -join ';')
        }
        $sig
    }
    return (@($parts) -join '|')
}

function Invoke-AdoGetSkipPaged {
    <#
    .SYNOPSIS  Internal: GETs a list endpoint paged with $top / $skip and collects every page.
    .PARAMETER Uri       URL including api-version; must not carry $top / $skip.
    .PARAMETER PageSize  Items per request.
    .PARAMETER MaxItems  Stop after this many items (0 = no limit).
    .PARAMETER MaxPages  Hard cap on requests (default 1000); stops with a warning when reached.
    .NOTES     Stops with a warning when a page is identical to the previous one (a server that
               ignores $skip would otherwise be paged forever).
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [int]$PageSize = 100,
        [int]$MaxItems = 0,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxPages = 1000
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($PageSize -lt 1) { throw 'PageSize must be at least 1.' }
    if ($MaxItems -gt 0 -and $MaxItems -lt $PageSize) { $PageSize = $MaxItems }

    $items     = [System.Collections.Generic.List[object]]::new()
    $skip      = 0
    $pages     = 0
    $lastPage  = $null
    $sep       = if ($Uri.Contains('?')) { '&' } else { '?' }
    while ($true) {
        if ($pages -ge $MaxPages) {
            Write-Warning "Stopped paging after $MaxPages pages ($($items.Count) items); results may be incomplete: $Uri"
            break
        }
        $pages++
        $r = Invoke-AdoGet -Uri "$Uri$sep`$top=$PageSize&`$skip=$skip" -Headers $Headers
        $page = @()
        $vp = if ($null -ne $r) { $r.PSObject.Properties['value'] } else { $null }
        if ($vp -and $null -ne $vp.Value) { $page = @($vp.Value) }

        if ($page.Count -gt 0) {
            $sig = Get-AdoPageSignature -Page $page
            if ($null -ne $lastPage -and $sig -eq $lastPage) {
                Write-Warning "Server repeated the same page (skip=$skip ignored?); stopped paging to avoid an endless loop: $Uri"
                break
            }
            $lastPage = $sig
        }
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
    if ($Status)       { $q.Add("searchCriteria.status=$(Get-AdoCanonicalValue $Status -Allowed 'active', 'abandoned', 'completed', 'all', 'notSet')") }
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

    $MergeStrategy = Get-AdoCanonicalValue $MergeStrategy -Allowed 'noFastForward', 'squash', 'rebase', 'rebaseMerge'
    $at = if ($LastMergeSourceCommitId) { $LastMergeSourceCommitId } else { 'its current source commit' }
    # ShouldProcess first: -WhatIf sends no request at all, not even the pre-flight read.
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PATCH - Complete ($MergeStrategy) at $at")) { return $null }

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
    $MergeStrategy = Get-AdoCanonicalValue $MergeStrategy -Allowed 'noFastForward', 'squash', 'rebase', 'rebaseMerge'
    $action = if ($Disable) { 'PATCH - Disable auto-complete' } else { "PATCH - Enable auto-complete ($MergeStrategy)" }
    # ShouldProcess first: -WhatIf sends no request at all, not even the connectionData read.
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", $action)) { return $null }

    if ($Disable) {
        $body = [ordered]@{ autoCompleteSetBy = @{ id = [guid]::Empty.ToString() } }
    } else {
        $body = [ordered]@{
            autoCompleteSetBy = @{ id = Get-AdoCurrentUserId -Org $Org -Headers $Headers }
            completionOptions = New-AdoCompletionOptions -MergeStrategy $MergeStrategy `
                                    -DeleteSourceBranch ([bool]$DeleteSourceBranch) `
                                    -TransitionWorkItems ([bool]$TransitionWorkItems) `
                                    -MergeCommitMessage $MergeCommitMessage
        }
    }
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
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'reviewers' -Org $Org -Project $Project -ApiV $ApiV
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
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
    $Vote   = Get-AdoCanonicalValue $Vote -Allowed 'Approve', 'ApproveWithSuggestions', 'NoVote', 'WaitForAuthor', 'Reject'
    $who    = if ($ReviewerId) { $ReviewerId } else { 'the authenticated user' }
    # ShouldProcess first: -WhatIf sends no request at all, not even the connectionData read.
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "PUT - Vote $Vote ($($values[$Vote])) as $who")) { return $null }
    if (-not $ReviewerId) { $ReviewerId = Get-AdoCurrentUserId -Org $Org -Headers $Headers }

    $uri  = "$(Get-AdoPullRequestRepoUri -RepoId $RepoId -Org $Org -Project $Project)/pullrequests/$PullRequestId/reviewers/$([uri]::EscapeDataString($ReviewerId))?api-version=$ApiV"
    $body = @{ id = $ReviewerId; vote = $values[$Vote] }
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

#region -- Threads and comments --

function Get-AdoPullRequestThreads {
    <#
    .SYNOPSIS  Lists the comment threads of a pull request.
    .PARAMETER Iteration      Only threads as of this iteration ($iteration).
    .PARAMETER BaseIteration  Compare against this base iteration ($baseIteration).
    .EXAMPLE
      Get-AdoPullRequestThreads -RepoId 'MyRepo' -PullRequestId 42 |
          Where-Object { $_.PSObject.Properties['status'] -and $_.status -eq 'active' }
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [int]$Iteration     = 0,
        [int]$BaseIteration = 0,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'threads' -Org $Org -Project $Project -ApiV $ApiV
    if ($Iteration -gt 0)     { $uri += "&`$iteration=$Iteration" }
    if ($BaseIteration -gt 0) { $uri += "&`$baseIteration=$BaseIteration" }
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
}

function New-AdoPullRequestThread {
    <#
    .SYNOPSIS  Starts a comment thread: general, or anchored to a file and line range.
    .PARAMETER Status    Thread status: active (default) | fixed | wontFix | closed | byDesign | pending.
    .PARAMETER FilePath  Repository path of the file ('src/app.ps1' or '/src/app.ps1').
    .PARAMETER Line      First line (1-based) of the anchor. Requires -FilePath.
    .PARAMETER EndLine   Last line of the anchor (default: -Line).
    .PARAMETER Side      Right (default; the PR's version of the file) or Left (the target's version).
    .EXAMPLE   New-AdoPullRequestThread -RepoId 'MyRepo' -PullRequestId 42 -Content 'Please add a test'
    .EXAMPLE   New-AdoPullRequestThread -RepoId 'MyRepo' -PullRequestId 42 -Content 'Off by one?' -FilePath 'src/calc.ps1' -Line 18
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$Content,
        [ValidateSet('active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending')]
        [string]$Status = 'active',
        [string]$FilePath = '',
        [int]$Line    = 0,
        [int]$EndLine = 0,
        [ValidateSet('Right', 'Left')]
        [string]$Side = 'Right',
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($Line -gt 0 -and -not $FilePath) { throw 'New-AdoPullRequestThread: -Line requires -FilePath.' }

    $body = [ordered]@{
        comments = @(@{ parentCommentId = 0; content = $Content; commentType = 'text' })
        status   = Get-AdoCanonicalValue $Status -Allowed 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending'
    }
    if ($FilePath) {
        $path = if ($FilePath.StartsWith('/')) { $FilePath } else { "/$FilePath" }
        $ctx  = [ordered]@{ filePath = $path }
        if ($Line -gt 0) {
            $last = if ($EndLine -ge $Line) { $EndLine } else { $Line }
            $side = $Side.ToLowerInvariant()
            $ctx["${side}FileStart"] = @{ line = $Line; offset = 1 }
            $ctx["${side}FileEnd"]   = @{ line = $last; offset = 1 }
        }
        $body.threadContext = $ctx
    }

    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'threads' -Org $Org -Project $Project -ApiV $ApiV
    $target = if ($FilePath) { "$FilePath$(if ($Line -gt 0) { ":$Line" })" } else { 'general' }
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "POST - New $Status thread ($target)")) { return $null }
    return Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 6) -Headers $Headers
}

function Add-AdoPullRequestComment {
    <#
    .SYNOPSIS  Adds a comment (reply) to an existing pull request thread.
    .PARAMETER ParentCommentId  Comment being replied to (0 = top level of the thread).
    .EXAMPLE   Add-AdoPullRequestComment -RepoId 'MyRepo' -PullRequestId 42 -ThreadId 7 -Content 'Fixed' -ParentCommentId 1
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][int]$ThreadId,
        [Parameter(Mandatory)][string]$Content,
        [int]$ParentCommentId = 0,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri  = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath "threads/$ThreadId/comments" -Org $Org -Project $Project -ApiV $ApiV
    $body = [ordered]@{ content = $Content; parentCommentId = $ParentCommentId; commentType = 'text' }
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId thread $ThreadId", 'POST - Add comment')) { return $null }
    return Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json) -Headers $Headers
}

function Set-AdoPullRequestThreadStatus {
    <#
    .SYNOPSIS  Changes a thread's status (resolve, reopen, won't fix...).
    .PARAMETER Status  active | fixed | wontFix | closed | byDesign | pending.
    .EXAMPLE   Set-AdoPullRequestThreadStatus -RepoId 'MyRepo' -PullRequestId 42 -ThreadId 7 -Status fixed
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][int]$ThreadId,
        [Parameter(Mandatory)]
        [ValidateSet('active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending')]
        [string]$Status,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    # ValidateSet is case-insensitive; send the documented camelCase spelling.
    $canonical = Get-AdoCanonicalValue $Status -Allowed 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath "threads/$ThreadId" -Org $Org -Project $Project -ApiV $ApiV
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId thread $ThreadId", "PATCH - Status $canonical")) { return $null }
    return Invoke-AdoRequest -Method PATCH -Uri $uri -Body (@{ status = $canonical } | ConvertTo-Json) -Headers $Headers
}

#endregion

#region -- Inspection --

function Get-AdoPullRequestIterations {
    <#
    .SYNOPSIS  Lists the iterations (pushes) of a pull request.
    .EXAMPLE   Get-AdoPullRequestIterations -RepoId 'MyRepo' -PullRequestId 42 | Select-Object id, description, createdDate
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [switch]$IncludeCommits,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'iterations' -Org $Org -Project $Project -ApiV $ApiV
    if ($IncludeCommits) { $uri += '&includeCommits=true' }
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
}

function Get-AdoPullRequestChanges {
    <#
    .SYNOPSIS  Lists the files changed in a pull request iteration, following nextSkip/nextTop paging.
    .PARAMETER IterationId  Iteration to inspect. Default: the latest iteration.
    .PARAMETER CompareTo    Iteration to compare against (0 = the common commit; API default).
    .PARAMETER PageSize     Entries per request (1-2000, default 100).
    .OUTPUTS   The changeEntries of every page.
    .EXAMPLE   Get-AdoPullRequestChanges -RepoId 'MyRepo' -PullRequestId 42 | ForEach-Object { $_.item.path }
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [int]$IterationId = 0,
        [int]$CompareTo   = 0,
        [ValidateRange(1, 2000)]
        [int]$PageSize    = 100,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    if ($IterationId -le 0) {
        $its = @(Get-AdoPullRequestIterations -RepoId $RepoId -PullRequestId $PullRequestId `
                    -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers)
        if ($its.Count -eq 0) { throw "Get-AdoPullRequestChanges: PR #$PullRequestId has no iterations." }
        $IterationId = ($its | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum
    }

    $base  = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath "iterations/$IterationId/changes" -Org $Org -Project $Project -ApiV $ApiV
    $items = [System.Collections.Generic.List[object]]::new()
    $skip  = 0
    $top   = $PageSize
    while ($true) {
        $r = Invoke-AdoGet -Uri "$base&`$top=$top&`$skip=$skip&`$compareTo=$CompareTo" -Headers $Headers
        $ce = if ($null -ne $r) { $r.PSObject.Properties['changeEntries'] } else { $null }
        if ($ce -and $null -ne $ce.Value) { foreach ($e in @($ce.Value)) { $items.Add($e) } }

        $ns = if ($null -ne $r) { $r.PSObject.Properties['nextSkip'] } else { $null }
        $nt = if ($null -ne $r) { $r.PSObject.Properties['nextTop'] }  else { $null }
        $nextSkip = if ($ns -and $ns.Value) { [int]$ns.Value } else { 0 }
        $nextTop  = if ($nt -and $nt.Value) { [int]$nt.Value } else { 0 }
        # Both are 0 when there are no more changes; also stop if the server does not advance.
        if ($nextTop -le 0 -or $nextSkip -le $skip) { break }
        $skip = $nextSkip
        $top  = [Math]::Min($nextTop, 2000)
    }
    return $items.ToArray()
}

function Get-AdoPullRequestCommits {
    <#
    .SYNOPSIS  Lists the commits of a pull request, following the continuation token.
    .PARAMETER Top  Maximum number of commits returned (0 = all).
    .EXAMPLE   Get-AdoPullRequestCommits -RepoId 'MyRepo' -PullRequestId 42 | Select-Object commitId, comment
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [int]$Top = 0,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'commits' -Org $Org -Project $Project -ApiV $ApiV
    return Invoke-AdoGetPaged -Uri $uri -Headers $Headers -MaxItems $Top
}

function Get-AdoPullRequestWorkItems {
    <#
    .SYNOPSIS  Lists the work items linked to a pull request (ResourceRef: id, url).
    .EXAMPLE   Get-AdoPullRequestWorkItems -RepoId 'MyRepo' -PullRequestId 42 | ForEach-Object { Get-AdoWorkItem -Id $_.id }
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
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'workitems' -Org $Org -Project $Project -ApiV $ApiV
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
}

#endregion

#region -- Labels and statuses --

function Get-AdoPullRequestLabels {
    <#
    .SYNOPSIS  Lists the labels (tags) of a pull request.
    .EXAMPLE   Get-AdoPullRequestLabels -RepoId 'MyRepo' -PullRequestId 42 | Select-Object name, active
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
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'labels' -Org $Org -Project $Project -ApiV $ApiV
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
}

function Add-AdoPullRequestLabel {
    <#
    .SYNOPSIS  Adds a label to a pull request (the tag is created if it does not exist).
    .EXAMPLE   Add-AdoPullRequestLabel -RepoId 'MyRepo' -PullRequestId 42 -Name 'needs-qa'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'labels' -Org $Org -Project $Project -ApiV $ApiV
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "POST - Add label '$Name'")) { return $null }
    return Invoke-AdoRequest -Method POST -Uri $uri -Body (@{ name = $Name } | ConvertTo-Json) -Headers $Headers
}

function Remove-AdoPullRequestLabel {
    <#
    .SYNOPSIS  Removes a label from a pull request (the tag itself is not deleted).
    .PARAMETER Name  Label name or id.
    .EXAMPLE   Remove-AdoPullRequestLabel -RepoId 'MyRepo' -PullRequestId 42 -Name 'needs-qa'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath "labels/$([uri]::EscapeDataString($Name))" -Org $Org -Project $Project -ApiV $ApiV
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "DELETE - Remove label '$Name'")) { return $null }
    return Invoke-AdoRequest -Method DELETE -Uri $uri -Headers $Headers
}

function Get-AdoPullRequestStatuses {
    <#
    .SYNOPSIS  Lists the statuses posted on a pull request (CI checks, external tools).
    .EXAMPLE   Get-AdoPullRequestStatuses -RepoId 'MyRepo' -PullRequestId 42 | Select-Object state, description
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
    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'statuses' -Org $Org -Project $Project -ApiV $ApiV
    return Get-AdoValueList (Invoke-AdoGet -Uri $uri -Headers $Headers)
}

function New-AdoPullRequestStatus {
    <#
    .SYNOPSIS  Posts a status on a pull request (e.g. an external check result).
    .PARAMETER State         notSet | pending | succeeded | failed | error | notApplicable.
    .PARAMETER ContextName   Status name; with -ContextGenre it identifies the status.
    .PARAMETER IterationId   Attach the status to this iteration (optional, >= 1).
    .EXAMPLE
      New-AdoPullRequestStatus -RepoId 'MyRepo' -PullRequestId 42 -State succeeded `
          -ContextGenre 'qa' -ContextName 'smoke' -Description 'Smoke tests passed' -TargetUrl $runUrl
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)]
        [ValidateSet('notSet', 'pending', 'succeeded', 'failed', 'error', 'notApplicable')]
        [string]$State,
        [Parameter(Mandatory)][string]$ContextName,
        [string]$ContextGenre = '',
        [string]$Description  = '',
        [string]$TargetUrl    = '',
        [int]$IterationId     = 0,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
    $canonical = Get-AdoCanonicalValue $State -Allowed 'notSet', 'pending', 'succeeded', 'failed', 'error', 'notApplicable'
    $context = [ordered]@{ name = $ContextName }
    if ($ContextGenre) { $context.genre = $ContextGenre }
    $body = [ordered]@{ state = $canonical; context = $context }
    if ($Description)       { $body.description = $Description }
    if ($TargetUrl)         { $body.targetUrl   = $TargetUrl }
    if ($IterationId -gt 0) { $body.iterationId = $IterationId }

    $uri = Get-AdoPullRequestUri -RepoId $RepoId -PullRequestId $PullRequestId -SubPath 'statuses' -Org $Org -Project $Project -ApiV $ApiV
    if (-not $PSCmdlet.ShouldProcess("PR #$PullRequestId", "POST - Status $canonical ($ContextGenre/$ContextName)")) { return $null }
    return Invoke-AdoRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 4) -Headers $Headers
}

#endregion
