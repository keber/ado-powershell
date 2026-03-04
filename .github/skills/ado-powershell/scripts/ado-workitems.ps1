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
