# Git and Iteration Functions - Azure DevOps PowerShell Skill

Full parameter reference and examples for Git Repository, Branch, and Iteration (sprint) operations.
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

---

## Iterations / Sprints

### `Get-AdoIterations`

Lists team iterations (sprints) with their paths, dates, and time-frame status.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-Team` | | project default team | Team name or ID |
| `-TimeFrame` | | all | `current \| past \| future` |

```powershell
# Current sprint of the default team
Get-AdoIterations -TimeFrame current |
    Select-Object name, @{n='Start';e={$_.attributes.startDate}},
                        @{n='End';e={$_.attributes.finishDate}} |
    Format-Table -AutoSize

# All sprints for a specific team
Get-AdoIterations -Team 'Backend Team' | Select-Object name, path | Format-Table -AutoSize

# Get the current iteration path (needed for WIQL @currentIteration)
$currentIter = (Get-AdoIterations -TimeFrame current | Select-Object -First 1).path
Invoke-AdoWiql -Query "SELECT [System.Id] FROM WorkItems WHERE [System.IterationPath] = '$currentIter'"
```

---

## Git Repositories

### `Get-AdoRepositories`

Lists all Git repositories in the project.

```powershell
Get-AdoRepositories | Select-Object id, name, remoteUrl | Format-Table -AutoSize

# Find a repo by name
$repo = Get-AdoRepositories | Where-Object name -eq 'MyRepo'
$repo.id
$repo.remoteUrl
```

---

### `Get-AdoBranches -RepoId <id>`

Lists all branches (refs) of a Git repository.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-RepoId` | ✅ | Repository ID (GUID) or repository name |

```powershell
# All branches
$repo = Get-AdoRepositories | Where-Object name -eq 'MyRepo'
Get-AdoBranches -RepoId $repo.id | Select-Object name | Format-Table -AutoSize

# Find branches matching a pattern
Get-AdoBranches -RepoId $repo.id | Where-Object name -like '*feature*' | Select-Object name

# Check if a specific branch exists
$exists = Get-AdoBranches -RepoId $repo.id | Where-Object name -eq 'refs/heads/main'
if ($exists) { Write-Host 'Branch exists' } else { Write-Host 'Branch not found' }
```
