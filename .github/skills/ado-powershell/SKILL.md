---
name: ado-powershell
description: "Access Azure DevOps (ADO) via REST API using PowerShell. Covers reading and writing Work Items, Test Plans, Test Runs, Git Repositories, Pipelines, and Iterations. Use this skill when the user asks to query, create, or update items in Azure DevOps, or mentions ADO, Work Items, Test Plans, sprints, pipelines, repositories, or ADO bugs."
compatibility: "Requires PowerShell 7+ (or Windows PowerShell 5.1). Needs Internet access to reach dev.azure.com. The ADO_PAT environment variable must be set."r<>
metadata:
  author: keber
  version: "1.0.0"
  api-version: "7.1"
  standard: agentskills.io
---

# Azure DevOps PowerShell Skill

Skill for interacting with the Azure DevOps REST API from PowerShell.
Supports **🔵 read** operations (no side effects) and
**🔴 write** operations (modify data; all support `-WhatIf`).

> **AGENT INSTRUCTIONS - follow before doing anything else:**
> 1. **Never paste function bodies into the terminal.** All functions are already on disk.
> 2. **Load with one command:** `. .github/skills/ado-powershell/load.ps1`
>    Auto-initialises `$AdoSession` when `ADO_PAT`, `ADO_ORG`, and `ADO_PROJECT` are set.
> 3. **This file is the quick-lookup index.** Do not read `.ps1` source files.
>    For full parameter tables and code examples, read the relevant domain reference file:
>    - [references/workitems.md](references/workitems.md) - Projects, Work Items, WIQL, Links, Attachments
>    - [references/testing.md](references/testing.md) - Test Plans, Suites, Cases, Runs, Results
>    - [references/pipelines.md](references/pipelines.md) - List, query, and trigger Pipelines
>    - [references/git.md](references/git.md) - Repositories, Branches, Iterations
>    Read **only the domain file you need** - not all of them.

---

## Required configuration

**Mandatory environment variable:** `ADO_PAT` (Azure DevOps Personal Access Token).

```powershell
$env:ADO_ORG     = 'my-organization'
$env:ADO_PROJECT = 'my-project'

# PS 7+ - inline SecureString conversion:
$env:ADO_PAT = Read-Host -AsSecureString 'ADO PAT' | ConvertFrom-SecureString -AsPlainText

# PS 5.1 - requires BSTR marshalling:
$ss = Read-Host -AsSecureString 'ADO PAT'
$env:ADO_PAT = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
```

> ⚠️ Never hardcode the PAT. Use minimum required scope and set an expiration date.
> Permissions per operation → [references/errors.md](references/errors.md).

---

## Session initialization

```powershell
. .github/skills/ado-powershell/load.ps1
# Auto-calls Initialize-AdoSession when ADO_PAT (or AZURE_DEVOPS_EXT_PAT) is set.
# If not auto-initialised, run:
$AdoSession = Initialize-AdoSession   # reads from env vars
$AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'   # explicit override
$AdoSession = Initialize-AdoSession -ConfigPath "$HOME/.config/ado/config.json"  # from file
```

**Config resolution order** (for each value - first non-empty wins):
1. Explicit parameter (`-Org`, `-Project`, `-Pat`, `-ApiV`, `-BaseUrl`)
2. Environment variable (`ADO_ORG`, `ADO_PROJECT`, `ADO_PAT` -> `AZURE_DEVOPS_EXT_PAT`, `ADO_API_VER`)
3. Config file (`-ConfigPath`) - JSON keys: `org`, `project`, `pat`, `apiVersion`, `baseUrl`

Missing required values (`Org`, `Project`, `Pat`) throw a clear error - no silent fake defaults.

Every function defaults its `Org`, `Project`, `ApiV`, and `Headers` from `$AdoSession`.
Pass them explicitly to override on a per-call basis.

---

## Function index

### 🔵 Projects & Work Items   ·   [references/workitems.md](references/workitems.md)

| Function | Description |
|----------|-------------|
| `Get-AdoProjects` | List organization projects |
| `Get-AdoTeams` | List teams in a project |
| `Get-AdoWorkItem -Id <n>` | Single Work Item with all fields |
| `Get-AdoWorkItemsBatch -Ids @(...)` | Up to 200 Work Items in one call |
| `Get-AdoWorkItemComments -Id <n>` | Comments on a Work Item |
| `Get-AdoWorkItemRevisions -Id <n>` | Field change history |
| `Invoke-AdoWiql -Query '...'` | WIQL query - returns items with fields |
| `New-AdoWorkItem -Type <T> -Title <t>` | 🔴 Create a Work Item |
| `Update-AdoWorkItem -Id <n>` | 🔴 Update one or more fields |
| `Add-AdoWorkItemComment -Id <n> -Text <t>` | 🔴 Add comment |
| `Add-AdoWorkItemLink -SourceId <n> -TargetId <n> -LinkType <t>` | 🔴 Link two Work Items |
| `Add-AdoWorkItemAttachment -Id <n> -FilePath <p>` | 🔴 Upload and attach a file |

### 🔵 Testing   ·   [references/testing.md](references/testing.md)

| Function | Description |
|----------|-------------|
| `Get-AdoTestPlans` | List Test Plans |
| `Get-AdoTestPlan -PlanId <n>` | Test Plan by ID (includes `rootSuite.id`) |
| `Get-AdoTestSuites -PlanId <n>` | Suites in a Plan |
| `Get-AdoTestCases -PlanId <n> -SuiteId <n>` | Test Cases in a Suite |
| `Get-AdoTestRuns` | Test Runs in the project |
| `Get-AdoTestRunResults -RunId <n>` | Results of a Test Run |
| `New-AdoTestPlan -Name <n> -AreaPath <a>` | 🔴 Create Test Plan |
| `New-AdoTestSuite -PlanId <n> -Name <n> -ParentSuiteId <n>` | 🔴 Create Test Suite |
| `New-AdoTestCase -Title <t>` | 🔴 Create Test Case (with optional `-Steps @(...)`) |
| `Add-AdoTestCaseToSuite -PlanId <n> -SuiteId <n> -TestCaseIds @(...)` | 🔴 Link TC(s) to Suite - always pass `-Confirm:$false` in scripts |
| `New-AdoTestRun -Name <n> -PlanId <n>` | 🔴 Create Test Run |
| `Update-AdoTestRunResults -RunId <n> -Results @(...)` | 🔴 Publish results |

### 🔵 Pipelines   ·   [references/pipelines.md](references/pipelines.md)

| Function | Description |
|----------|-------------|
| `Get-AdoPipelines` | List pipelines in the project |
| `Get-AdoPipelineRuns -PipelineId <n>` | Recent runs (filterable by branch/state/result/date) |
| `Invoke-AdoPipelineRun -PipelineId <n>` | 🔴 Trigger a run (supports branch, variables, template params) |

### 🔵 Git & Iterations   ·   [references/git.md](references/git.md)

| Function | Description |
|----------|-------------|
| `Get-AdoIterations` | Team sprints (filterable: `current \| past \| future`) |
| `Get-AdoRepositories` | Git repositories in the project |
| `Get-AdoBranches -RepoId <id>` | Branches of a repository |

---

## Quick validation

Run the smoke test to verify connectivity and permissions before operating:

```powershell
# Minimal - uses env vars for org/project:
. .github/skills/ado-powershell/assets/smoke-test.ps1

# With a known Work Item ID and Test Plan ID for deeper validation:
. .github/skills/ado-powershell/assets/smoke-test.ps1 -SampleWiId <wi-id> -SamplePlanId <plan-id>
```

Full script → [assets/smoke-test.ps1](assets/smoke-test.ps1)

---

## References

- [Work Items - full parameter docs + examples](references/workitems.md)
- [Testing - full parameter docs + examples](references/testing.md)
- [Pipelines - full parameter docs + examples](references/pipelines.md)
- [Git & Iterations - full parameter docs + examples](references/git.md)
- [ADO API v7.1 endpoint reference](references/endpoints.md)
- [Error handling, HTTP codes and PAT permissions](references/errors.md)
- [Error handling, HTTP codes and PAT permissions](references/errors.md)
