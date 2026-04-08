# Pipeline Functions - Azure DevOps PowerShell Skill

Full parameter reference and examples for Pipeline (CI/CD) operations.
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

---

## Pipelines - Read

### `Get-AdoPipelines`

Lists all pipelines (build definitions) in the project.

```powershell
Get-AdoPipelines | Select-Object id, name, folder | Format-Table -AutoSize

# Find a pipeline by name
$pipe = Get-AdoPipelines | Where-Object name -eq 'Deploy to Staging'
$pipe.id
```

---

### `Get-AdoPipelineRuns -PipelineId <n>`

Returns recent runs of a pipeline with optional filters.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-PipelineId` | ✅ | - | - |
| `-Top` | | `10` | Max results |
| `-Branch` | | - | e.g. `'main'` or `'refs/heads/feature/x'` |
| `-State` | | - | `notStarted \| inProgress \| completed` |
| `-Result` | | - | `succeeded \| failed \| canceled \| partiallySucceeded` |
| `-CreatedFrom` | | - | ISO-8601 lower bound, e.g. `'2025-01-01'` |
| `-CreatedTo` | | - | ISO-8601 upper bound, e.g. `'2025-01-31'` |

```powershell
# Last 5 runs on main
Get-AdoPipelineRuns -PipelineId 12 -Top 5 -Branch 'main' |
    Select-Object id, name, state, result, @{n='CreatedDate';e={$_.createdDate}} |
    Format-Table -AutoSize

# Failed runs this month
Get-AdoPipelineRuns -PipelineId 12 -Top 20 -Result 'failed' -CreatedFrom '2025-01-01' |
    Select-Object id, name, result | Format-Table -AutoSize
```

---

## Pipelines - Trigger

### `Invoke-AdoPipelineRun -PipelineId <n>`

Triggers a new pipeline run and returns the created run object.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-PipelineId` | ✅ | - | - |
| `-Branch` | | pipeline default | Branch to run on. `'main'`, `'feature/x'`, `'refs/heads/...'` all accepted |
| `-Variables` | | `@{}` | Runtime variables. Each key: `@{ value='...'; isSecret=$false }` |
| `-TemplateParameters` | | `@{}` | YAML template parameter overrides as a flat hashtable |
| `-StagesToSkip` | | `@()` | Array of stage display names to skip |

```powershell
# Trigger on default branch
Invoke-AdoPipelineRun -PipelineId 4 -Confirm:$false

# Trigger on a feature branch
Invoke-AdoPipelineRun -PipelineId 4 -Branch 'feature/my-branch' -Confirm:$false

# With runtime variable
Invoke-AdoPipelineRun -PipelineId 4 -Branch 'main' `
    -Variables @{ deployEnv = @{ value = 'staging'; isSecret = $false } } `
    -Confirm:$false

# With template parameter and stage skip
Invoke-AdoPipelineRun -PipelineId 4 `
    -TemplateParameters @{ environment = 'uat'; runSmokeTests = 'true' } `
    -StagesToSkip @('DeployProd') `
    -Confirm:$false

# Simulate without triggering
Invoke-AdoPipelineRun -PipelineId 4 -Branch 'main' -WhatIf
```

**Returned run object fields:**

| Field | Description |
|-------|-------------|
| `id` | Run ID - use with `Get-AdoPipelineRuns` to poll for status |
| `state` | `inProgress \| completed \| notStarted` |
| `result` | `succeeded \| failed \| canceled` (only when `state = completed`) |
| `_links.web.href` | Direct browser URL to the run |
