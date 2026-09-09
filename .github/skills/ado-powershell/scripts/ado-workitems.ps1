<#
.SYNOPSIS
  Work Item operations on Azure DevOps REST API.
  Covers project/team discovery, Work Item CRUD, WIQL queries,
  comments, links, and attachments.

.PREREQUISITE
  Dot-source ado-base.ps1 first and call Initialize-AdoSession.

.SAFETY
  Read functions have no side effects.
  Write functions implement [CmdletBinding(SupportsShouldProcess)].
  Use -WhatIf to simulate. Use -Confirm:$false to skip prompts in scripts.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"
  . "$PSScriptRoot/ado-workitems.ps1"
  $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Session cache for Get-AdoWorkItemTypeFields. Declared here rather than initialised lazily
# inside the function: under Set-StrictMode, reading a script variable that was never assigned
# throws instead of yielding $null, so an in-function existence check never runs.
$script:AdoWorkItemTypeFieldCache = @{}

#region -- Projects and Teams --

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

#region -- Work Items: Read --

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
    .PARAMETER Fields
      Optional: array of field names. If omitted, returns all fields.
      ADO rejects a request that combines 'fields' with an '$expand' other than None (HTTP 400),
      so supplying -Fields forces Expand to None unless an explicit -Expand was also passed -
      in which case the conflict is reported rather than silently resolved.
    .EXAMPLE   Get-AdoWorkItemsBatch -Ids @(100,101,102) | Select-Object id, @{n='T';e={$_.fields.'System.Title'}}
    .EXAMPLE   Get-AdoWorkItemsBatch -Ids @(100,101) -Fields 'System.Id','System.Title'
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
    # 'fields' and '$expand' are mutually exclusive in the workitemsbatch API: any $expand other
    # than None alongside 'fields' is answered with HTTP 400. Resolve it here rather than letting
    # the caller discover it as a server error.
    if ($Fields) {
        if ($PSBoundParameters.ContainsKey('Expand') -and $Expand -ne 'None') {
            throw ("Get-AdoWorkItemsBatch: -Fields cannot be combined with -Expand '$Expand'. " +
                   "ADO rejects that combination (HTTP 400). Drop -Expand to select fields, " +
                   "or drop -Fields to expand.")
        }
        $Expand = 'None'
    }

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

function Get-AdoWorkItemTypeFields {
    <#
    .SYNOPSIS  Returns the field definitions for a Work Item type, including default values.

    .DESCRIPTION
      Answers what a type's fields are called and what ADO pre-fills them with. The default value
      matters when deciding whether a field was actually filled in: a template default is not the
      same as user-authored content, but both are non-empty. Results are cached per type for the
      session, since type definitions do not change during a run.

    .PARAMETER Type   Work Item type name, e.g. 'User Story'. Spaces are escaped automatically.
    .PARAMETER Force  Bypass the session cache and re-query.

    .EXAMPLE
      Get-AdoWorkItemTypeFields -Type 'User Story' |
          Where-Object referenceName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria'
    .EXAMPLE
      # Tell "not filled in" apart from "left as the template default"
      $def = (Get-AdoWorkItemTypeFields -Type $t |
              Where-Object referenceName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria').defaultValue
      $ac  = Get-AdoFieldValue -WorkItem $wi -Name 'Microsoft.VSTS.Common.AcceptanceCriteria'
      $isTemplate = ($ac -eq $def)
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [switch]$Force,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $cacheKey = "$Org/$Project/$Type"
    if (-not $Force -and $script:AdoWorkItemTypeFieldCache.ContainsKey($cacheKey)) {
        return $script:AdoWorkItemTypeFieldCache[$cacheKey]
    }

    $typeEncoded = [Uri]::EscapeDataString($Type)
    $uri = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitemtypes/$typeEncoded/fields?api-version=$ApiV"
    $r   = Invoke-AdoGet -Uri $uri -Headers $Headers
    $script:AdoWorkItemTypeFieldCache[$cacheKey] = $r.value
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

    $uri  = "$(Get-AdoBaseUrl $Org)/$Project/_apis/wit/workitems/`$$Type`?api-version=$ApiV"

    if (-not $PSCmdlet.ShouldProcess($uri, "POST - Create ${Type}: '$Title'")) { return $null }

    $r = Invoke-AdoRequest -Method POST -Uri $uri -Body (ConvertTo-Json -InputObject @($ops) -Depth 5) `
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

    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body (ConvertTo-Json -InputObject @($ops) -Depth 5) `
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

function Get-AdoIdFromUrl {
    <#
    .SYNOPSIS  Extracts a Work Item id from an ADO relation URL.
    .DESCRIPTION
      Relations reference their target by URL, not by id. Splitting on '/' breaks when the URL
      carries a query string, so match the id explicitly.
    .OUTPUTS  [int], or $null when the URL is not a Work Item URL.
    .EXAMPLE  Get-AdoIdFromUrl -Url $rel.url
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url -match '(?i)/workitems/(\d+)(\?|$)') { return [int]$Matches[1] }
    return $null
}

function Get-AdoWorkItemParent {
    <#
    .SYNOPSIS  Returns the parent of a Work Item, or $null when it has none.

    .DESCRIPTION
      Walks 'System.LinkTypes.Hierarchy-Reverse'. Accepts either an id (fetched here) or an
      already-fetched Work Item, so callers that hold the object avoid a second round trip.
      The Work Item must have been fetched with relations - the default -Expand All does.

    .PARAMETER Id        Work Item id to fetch and inspect.
    .PARAMETER WorkItem  An already-fetched Work Item to inspect.
    .PARAMETER IdOnly    Return just the parent id instead of the full Work Item.

    .EXAMPLE  $parent = Get-AdoWorkItemParent -Id 20071
    .EXAMPLE  $parentId = Get-AdoWorkItemParent -WorkItem $wi -IdOnly
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0)]
        [int]$Id,

        [Parameter(Mandatory, ParameterSetName = 'ByObject')]
        [AllowNull()]
        [object]$WorkItem,

        [switch]$IdOnly,
        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $wi = if ($PSCmdlet.ParameterSetName -eq 'ById') {
        Get-AdoWorkItem -Id $Id -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
    } else {
        $WorkItem
    }
    if ($null -eq $wi) { return $null }

    $relsProp = $wi.PSObject.Properties['relations']
    if (-not $relsProp -or $null -eq $relsProp.Value) { return $null }

    foreach ($r in @($relsProp.Value)) {
        if ($null -eq $r) { continue }
        if ($r.rel -ne 'System.LinkTypes.Hierarchy-Reverse') { continue }

        $parentId = Get-AdoIdFromUrl -Url $r.url
        if ($null -eq $parentId) { continue }
        if ($IdOnly) { return $parentId }
        return Get-AdoWorkItem -Id $parentId -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
    }
    return $null
}

function Test-AdoWorkItemLink {
    <#
    .SYNOPSIS  Tells whether a link of a given type already exists between two Work Items.

    .DESCRIPTION
      ADO accepts a duplicate relation without complaint, so a re-run of a linking script silently
      accumulates identical links. Check before adding.

      Comparison is on the target id parsed out of each relation URL, not on the URL string:
      the same Work Item can be referenced through different host or organisation spellings.

    .PARAMETER SourceId  Work Item whose relations are inspected.
    .PARAMETER WorkItem  An already-fetched source Work Item, as an alternative to -SourceId.
    .PARAMETER TargetId  Work Item the link should point at.
    .PARAMETER LinkType  Relation reference name, e.g. 'System.LinkTypes.Related'.

    .EXAMPLE
      if (-not (Test-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related')) {
          Add-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related'
      }
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById', Position = 0)]
        [int]$SourceId,

        [Parameter(Mandatory, ParameterSetName = 'ByObject')]
        [AllowNull()]
        [object]$WorkItem,

        [Parameter(Mandatory)][int]$TargetId,
        [Parameter(Mandatory)][string]$LinkType,

        [string]$Org     = $script:AdoSession.Org,
        [string]$Project = $script:AdoSession.Project,
        [string]$ApiV    = $script:AdoSession.ApiV,
        [hashtable]$Headers = $script:AdoSession.Headers
    )
    $wi = if ($PSCmdlet.ParameterSetName -eq 'ById') {
        Get-AdoWorkItem -Id $SourceId -Org $Org -Project $Project -ApiV $ApiV -Headers $Headers
    } else {
        $WorkItem
    }
    if ($null -eq $wi) { return $false }

    $relsProp = $wi.PSObject.Properties['relations']
    if (-not $relsProp -or $null -eq $relsProp.Value) { return $false }

    foreach ($r in @($relsProp.Value)) {
        if ($null -eq $r) { continue }
        if ($r.rel -ne $LinkType) { continue }
        if ((Get-AdoIdFromUrl -Url $r.url) -eq $TargetId) { return $true }
    }
    return $false
}

function Add-AdoWorkItemLink {
    <#
    .SYNOPSIS  Creates a link between two Work Items.
    .PARAMETER LinkType
        Common values:
          System.LinkTypes.Hierarchy-Forward         -> parent includes child
          System.LinkTypes.Related                   -> related to
          System.LinkTypes.Duplicate-Forward         -> duplicate of
          Microsoft.VSTS.Common.TestedBy-Forward     -> User Story tested by Test Case
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

    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body (ConvertTo-Json -InputObject @($ops) -Depth 6) `
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
    $r = Invoke-AdoRequest -Method PATCH -Uri $uri -Body (ConvertTo-Json -InputObject @($ops) -Depth 6) `
        -ContentType 'application/json-patch+json' -Headers $Headers
    Write-Host "(ok) '$fileName' attached to WI #$Id" -ForegroundColor Green
    return $r
}

#endregion
