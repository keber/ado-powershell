# Work Item Functions - Azure DevOps PowerShell Skill

Full parameter reference and examples for Work Item, Project, and Team operations.
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

---

## Projects and Teams

| Function | Description |
|----------|-------------|
| `Get-AdoProjects` | List all projects in the organization |
| `Get-AdoTeams` | List teams in the current project |

```powershell
Get-AdoProjects | Select-Object name, state | Format-Table -AutoSize
Get-AdoTeams    | Select-Object name, description | Format-Table -AutoSize
```

---

## Work Items - Read

### `Get-AdoWorkItem -Id <n>`

Returns a single Work Item with all fields, relations, and links.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-Id` | ✅ | - | Work Item ID (int) |
| `-Expand` | | `All` | `None \| Relations \| Fields \| Links \| All` |

```powershell
$wi = Get-AdoWorkItem -Id 1234
"$($wi.id) | $($wi.fields.'System.Title') | $($wi.fields.'System.State')"

# Access a related link
$wi.relations | Where-Object rel -eq 'System.LinkTypes.Related'
```

---

### `Get-AdoWorkItemsBatch -Ids @(...)`

Fetches up to 200 Work Items in a single call.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-Ids` | ✅ | - | `[int[]]` array, max 200 |
| `-Fields` | | all fields | `@('System.Title','System.State',...)` to limit payload |
| `-Expand` | | `All` | Same values as `Get-AdoWorkItem` |

```powershell
Get-AdoWorkItemsBatch -Ids @(100, 101, 102) |
    Select-Object id, @{n='Title';e={$_.fields.'System.Title'}},
                      @{n='State';e={$_.fields.'System.State'}} |
    Format-Table -AutoSize
```

---

### `Invoke-AdoWiql -Query '...'`

Executes a WIQL query and returns Work Items with their fields.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-Query` | ✅ | - | Full WIQL SELECT statement |
| `-Top` | | `100` | Max results |

```powershell
# Active items in current sprint
Invoke-AdoWiql -Query @"
SELECT [System.Id],[System.Title],[System.State],[System.AssignedTo]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.IterationPath] = @currentIteration
  AND [System.State] <> 'Closed'
ORDER BY [System.ChangedDate] DESC
"@ | Select-Object id,
      @{n='Title';e={$_.fields.'System.Title'}},
      @{n='State';e={$_.fields.'System.State'}} |
    Format-Table -AutoSize

# Work Items by tag
Invoke-AdoWiql -Query "SELECT [System.Id],[System.Title] FROM WorkItems
    WHERE [System.Tags] CONTAINS 'regression' AND [System.State] = 'Active'"
```

---

### `Get-AdoWorkItemComments -Id <n>`

Returns the comments of a Work Item.

```powershell
Get-AdoWorkItemComments -Id 1234 |
    Select-Object @{n='Author';e={$_.createdBy.displayName}}, text |
    Format-List
```

---

### `Get-AdoWorkItemRevisions -Id <n>`

Returns the full revision (field change) history of a Work Item.

```powershell
Get-AdoWorkItemRevisions -Id 1234 |
    Select-Object rev, @{n='ChangedBy';e={$_.fields.'System.ChangedBy'}},
                       @{n='State';e={$_.fields.'System.State'}} |
    Format-Table -AutoSize
```

---


### `Get-AdoWorkItemTypeFields -Type <T>`

Field definitions for a Work Item type, including the value ADO pre-fills. Cached per type for
the session.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Type` | Yes | Type name, e.g. `User Story`. Spaces are URL-escaped automatically |
| `-Force` | No | Bypass the session cache and re-query |

```powershell
# Tell "acceptance criteria not filled in" apart from "left as the template default"
$def = (Get-AdoWorkItemTypeFields -Type 'User Story' |
        Where-Object referenceName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria').defaultValue
$ac  = Get-AdoFieldValue -WorkItem $wi -Name 'Microsoft.VSTS.Common.AcceptanceCriteria'
if ($ac -eq $def) { 'template default, not authored content' }
```

---

### `Get-AdoWorkItemParent -Id <n>`

Parent of a Work Item through `System.LinkTypes.Hierarchy-Reverse`, or `$null` when it has none.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Id` | Yes (or `-WorkItem`) | Work Item to fetch and inspect |
| `-WorkItem` | Yes (or `-Id`) | An already-fetched Work Item - avoids a second round trip |
| `-IdOnly` | No | Return just the parent id instead of the full Work Item |

```powershell
$parent = Get-AdoWorkItemParent -Id 20071
"$($parent.id) | $(Get-AdoFieldValue -WorkItem $parent -Name 'System.Title')"

# Walk to the root of the hierarchy
$cur = Get-AdoWorkItem -Id 20071
while ($p = Get-AdoWorkItemParent -WorkItem $cur) { $cur = $p }
```

> The Work Item must carry relations. The default `-Expand All` on `Get-AdoWorkItem` includes them;
> `-Expand None` or a `-Fields` projection does not.

---

### `Test-AdoWorkItemLink -SourceId <n> -TargetId <n> -LinkType <t>`

Whether a link of that type already exists between the two items.

ADO accepts a duplicate relation without complaint, so re-running a linking script silently
accumulates identical links. Matching is on the target id parsed out of the relation URL, not on
the URL string, so it holds across host and organisation spellings.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-SourceId` | Yes (or `-WorkItem`) | Work Item whose relations are inspected |
| `-WorkItem` | Yes (or `-SourceId`) | An already-fetched source Work Item |
| `-TargetId` | Yes | Work Item the link should point at |
| `-LinkType` | Yes | Relation reference name (see the link-type table below) |

```powershell
# Idempotent linking
if (-not (Test-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related')) {
    Add-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related'
}

# Inspecting many links on one item: fetch once, test repeatedly
$wi = Get-AdoWorkItem -Id 1001
$targets | Where-Object { -not (Test-AdoWorkItemLink -WorkItem $wi -TargetId $_ -LinkType $lt) }
```

---

### `Get-AdoIdFromUrl -Url <u>`

Work Item id out of a relation URL; `$null` when the URL does not point at a Work Item.

```powershell
$rel = $wi.relations | Where-Object rel -eq 'System.LinkTypes.Hierarchy-Reverse'
Get-AdoIdFromUrl -Url $rel.url    # -> 20088
```

> Splitting the URL on `/` and taking the last segment breaks on
> `.../workitems/311?api-version=7.1` - it yields `311?api-version=7.1`, not `311`.

---

## Work Items - Write

All write functions support `-WhatIf` (simulate) and `-Confirm:$false` (skip prompt in scripts).

### `New-AdoWorkItem -Type <T> -Title <t>`

Creates a new Work Item of the given type.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-Type` | ✅ | `Task \| Bug \| User Story \| Feature \| Epic \| Issue \| Test Case` ... |
| `-Title` | ✅ | - |
| `-Description` | | HTML supported |
| `-AssignedTo` | | Email or display name |
| `-AreaPath` | | Defaults to project root |
| `-IterationPath` | | e.g. `'MyProject\Sprint 5'` |
| `-Tags` | | Semicolon-separated: `'tag1; tag2'` |
| `-State` | | `New \| Active \| To Do \| Resolved \| Closed` |
| `-ExtraFields` | | `@{ 'System.Tags' = 'qa'; 'Microsoft.VSTS.Common.Priority' = '1' }` |

```powershell
# Simple task
New-AdoWorkItem -Type 'Task' -Title 'Configure CI/CD' -AssignedTo 'dev@contoso.com' `
    -Tags 'infra; sprint-5' -IterationPath 'MyProject\Sprint 5'

# Bug with repro steps
New-AdoWorkItem -Type 'Bug' -Title 'Login fails on mobile' `
    -ExtraFields @{ 'Microsoft.VSTS.TCM.ReproSteps' = '<p>1. Open /login<br>2. Tap Sign In</p>' }

# Simulate without creating
New-AdoWorkItem -Type 'Task' -Title 'Test task' -WhatIf
```

---

### `Update-AdoWorkItem -Id <n>`

Updates one or more fields.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-Id` | ✅ | - |
| `-Title` | | - |
| `-Description` | | - |
| `-State` | | - |
| `-AssignedTo` | | - |
| `-AreaPath` | | - |
| `-IterationPath` | | - |
| `-Tags` | | - |
| `-ExtraFields` | | Any field as hashtable |

```powershell
Update-AdoWorkItem -Id 1234 -State 'Active' -AssignedTo 'qa@contoso.com'
Update-AdoWorkItem -Id 1234 -ExtraFields @{ 'Microsoft.VSTS.Common.Priority' = '1' }
Update-AdoWorkItem -Id 1234 -State 'Closed' -WhatIf   # simulate
```

---

### `Add-AdoWorkItemComment -Id <n> -Text <t>`

Adds a text or HTML comment to a Work Item.

```powershell
Add-AdoWorkItemComment -Id 1234 -Text 'Reviewed and approved in UAT.'
Add-AdoWorkItemComment -Id 1234 -Text '<b>Blocked</b> - waiting for environment access.'
```

---

### `Add-AdoWorkItemLink -SourceId <n> -TargetId <n> -LinkType <t>`

Creates a typed link between two Work Items.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-SourceId` | ✅ | - |
| `-TargetId` | ✅ | - |
| `-LinkType` | ✅ | See table below |
| `-Comment` | | Optional description for the link |

**Common link types:**

| LinkType | Meaning |
|----------|---------|
| `System.LinkTypes.Related` | Related to |
| `System.LinkTypes.Hierarchy-Forward` | Parent → Child |
| `System.LinkTypes.Hierarchy-Reverse` | Child → Parent |
| `System.LinkTypes.Duplicate-Forward` | Duplicate of |
| `Microsoft.VSTS.Common.TestedBy-Forward` | User Story tested by Test Case |
| `Microsoft.VSTS.Common.TestedBy-Reverse` | Test Case tests User Story |

```powershell
Add-AdoWorkItemLink -SourceId 1001 -TargetId 1050 -LinkType 'System.LinkTypes.Related'
Add-AdoWorkItemLink -SourceId 2000 -TargetId 2001 `
    -LinkType 'Microsoft.VSTS.Common.TestedBy-Forward' -Comment 'UAT coverage'
```

---

### `Add-AdoWorkItemAttachment -Id <n> -FilePath <p>`

Uploads a local file and attaches it to a Work Item.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-Id` | ✅ | - |
| `-FilePath` | ✅ | Absolute path to the local file |
| `-Comment` | | Label shown in the attachment list |

```powershell
Add-AdoWorkItemAttachment -Id 1234 -FilePath 'C:\logs\error.log' -Comment 'Error log from prod'
Add-AdoWorkItemAttachment -Id 1234 -FilePath 'C:\screenshots\step3.png'
```
