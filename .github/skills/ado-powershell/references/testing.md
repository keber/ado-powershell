# Testing Functions - Azure DevOps PowerShell Skill

Full parameter reference and examples for Test Plan, Test Suite, Test Case, Test Run, and Results operations.
Load the skill before using: `. .github/skills/ado-powershell/load.ps1`

> **Script note:** Always pass `-Confirm:$false` to `Add-AdoTestCaseToSuite`, `New-AdoTestPlan`,
> and `New-AdoTestSuite` inside `.ps1` scripts. Without it, the default `$ConfirmPreference`
> can silently suppress the API call with no error or warning.

---

## Test Plans - Read

### `Get-AdoTestPlans`

Lists all Test Plans in the project.

```powershell
Get-AdoTestPlans | Select-Object id, name, state | Format-Table -AutoSize
```

---

### `Get-AdoTestPlan -PlanId <n>`

Gets a single Test Plan with full metadata (area path, iteration, dates, root suite ID).

```powershell
$plan = Get-AdoTestPlan -PlanId 1001
$rootSuiteId = $plan.rootSuite.id   # needed as ParentSuiteId for top-level suites
```

---

## Test Suites - Read

### `Get-AdoTestSuites -PlanId <n>`

Lists all suites in a Test Plan (flat list including nested suites).

```powershell
Get-AdoTestSuites -PlanId 1001 | Select-Object id, name, suiteType, parentSuite | Format-Table -AutoSize
```

---

### `Get-AdoTestCases -PlanId <n> -SuiteId <n>`

Lists the Test Cases assigned to a specific Suite.

```powershell
Get-AdoTestCases -PlanId 1001 -SuiteId 1002 |
    Select-Object @{n='Id';e={$_.workItem.id}},
                  @{n='Title';e={$_.workItem.name}} |
    Format-Table -AutoSize
```

---

## Test Runs - Read

### `Get-AdoTestRuns`

Lists recent Test Runs, optionally filtered by Test Plan.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-PlanId` | | - | Filter to runs of a specific Test Plan |
| `-Top` | | `50` | Max results |

```powershell
Get-AdoTestRuns -PlanId 1001 | Select-Object id, name, state, totalTests | Format-Table -AutoSize
```

---

### `Get-AdoTestRunResults -RunId <n>`

Returns the individual test results of a run.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-RunId` | ✅ | - | - |
| `-Top` | | `200` | Max results |

```powershell
Get-AdoTestRunResults -RunId 456 |
    Select-Object id, testCaseTitle, outcome, errorMessage |
    Format-Table -AutoSize

# Count by outcome
Get-AdoTestRunResults -RunId 456 | Group-Object outcome | Select-Object Name, Count
```

---

## Test Plans - Write

### `New-AdoTestPlan -Name <n> -AreaPath <a>`

Creates a new Test Plan and returns the created object (including `rootSuite.id`).

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-Name` | ✅ | - |
| `-AreaPath` | ✅ | e.g. `'MyProject'` or `'MyProject\QA'` |
| `-IterationPath` | | e.g. `'MyProject\Sprint 5'` |
| `-StartDate` | | ISO-8601: `'2025-01-01'` |
| `-EndDate` | | ISO-8601: `'2025-03-31'` |

```powershell
$plan = New-AdoTestPlan -Name 'Sprint 5 UAT' -AreaPath 'MyProject' `
    -IterationPath 'MyProject\Sprint 5' `
    -StartDate '2025-01-01' -EndDate '2025-01-14' -Confirm:$false

$plan.id              # plan ID for follow-up calls
$plan.rootSuite.id    # root suite ID (needed for New-AdoTestSuite)
```

---

## Test Suites - Write

### `New-AdoTestSuite -PlanId <n> -Name <n> -ParentSuiteId <n>`

Creates a new Test Suite inside an existing Test Plan.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-PlanId` | ✅ | - | - |
| `-Name` | ✅ | - | - |
| `-ParentSuiteId` | ✅ | - | Use `$plan.rootSuite.id` for top-level suites |
| `-SuiteType` | | `staticTestSuite` | `staticTestSuite \| requirementTestSuite \| dynamicTestSuite` |
| `-QueryString` | | - | WIQL query; only used when `SuiteType` is `dynamicTestSuite` |

```powershell
# Static suite at the root of plan 1001
$suite = New-AdoTestSuite -PlanId 1001 -Name 'Login module' `
    -ParentSuiteId $plan.rootSuite.id -Confirm:$false

# Dynamic suite (query-based)
New-AdoTestSuite -PlanId 1001 -Name 'High priority TCs' `
    -ParentSuiteId $plan.rootSuite.id -SuiteType dynamicTestSuite `
    -QueryString "SELECT [System.Id] FROM WorkItems WHERE [Microsoft.VSTS.Common.Priority] = 1" `
    -Confirm:$false
```

---

## Test Cases - Write

### `New-AdoTestCase -Title <t>`

Creates a Test Case work item with optional steps encoded in the ADO XML format.

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `-Title` | ✅ | - | - |
| `-Steps` | | - | `@('Action 1','Action 2',...)` - plain text per step |
| `-Priority` | | - | `'1'` (Critical) `'2'` (High) `'3'` (Medium) `'4'` (Low) |
| `-AssignedTo` | | - | Email or display name |
| `-Description` | | - | HTML accepted |
| `-Tags` | | - | Semicolon-separated |
| `-State` | | - | `Design \| Ready \| Closed` |
| `-AreaPath` | | - | - |
| `-IterationPath` | | - | - |
| `-ExtraFields` | | `@{}` | Any additional TCM or custom field |

```powershell
# Test Case with steps
$tc = New-AdoTestCase -Title 'Verify login with valid credentials' `
    -Steps @(
        'Navigate to /login',
        'Enter valid username and password',
        'Click Sign In',
        'Verify redirect to dashboard'
    ) `
    -Priority '2' -AssignedTo 'qa@contoso.com' -Tags 'login; smoke'

$tc.id   # Work Item ID to use with Add-AdoTestCaseToSuite

# Minimal
$tc = New-AdoTestCase -Title 'Check logout button'
```

---

### `Add-AdoTestCaseToSuite -PlanId <n> -SuiteId <n> -TestCaseIds @(...)`

Adds one or more existing Test Case work items to a Suite.

| Parameter | Required | Notes |
|-----------|----------|-------|
| `-PlanId` | ✅ | - |
| `-SuiteId` | ✅ | - |
| `-TestCaseIds` | ✅ | `[int[]]` array of Test Case work item IDs |

> ⚠️ **Always pass `-Confirm:$false` in scripts.** Without it, the default `$ConfirmPreference`
> can silently suppress the API call - no error is raised, the TC is simply not added.

```powershell
Add-AdoTestCaseToSuite -PlanId 1001 -SuiteId 1002 -TestCaseIds @(5010, 5011, 5012) -Confirm:$false

# Full end-to-end: create plan → suite → test case → link
$plan  = New-AdoTestPlan  -Name 'Sprint UAT' -AreaPath 'MyProject' -Confirm:$false
$suite = New-AdoTestSuite -PlanId $plan.id -Name 'Login' -ParentSuiteId $plan.rootSuite.id -Confirm:$false
$tc    = New-AdoTestCase  -Title 'Valid login' -Steps @('Go to /login','Click Sign In')
Add-AdoTestCaseToSuite -PlanId $plan.id -SuiteId $suite.id -TestCaseIds @($tc.id) -Confirm:$false
```

---

## Test Runs - Write

### `New-AdoTestRun -Name <n> -PlanId <n>`

Creates a new Test Run associated with a Test Plan.

```powershell
$run = New-AdoTestRun -Name 'Sprint 5 Regression' -PlanId 1001
$run.id   # use with Update-AdoTestRunResults
```

---

### `Update-AdoTestRunResults -RunId <n> -Results @(...)`

Publishes test results to an existing Test Run.

**Outcome values:** `Passed | Failed | NotExecuted | Blocked`

Each result is a hashtable with at minimum `testCaseTitle` and `outcome`:

```powershell
$results = @(
    @{ testCaseTitle = 'Valid login';        outcome = 'Passed' },
    @{ testCaseTitle = 'Login wrong password'; outcome = 'Failed'; errorMessage = 'HTTP 401 - Unauthorized' },
    @{ testCaseTitle = 'Logout button';      outcome = 'NotExecuted' }
)
Update-AdoTestRunResults -RunId $run.id -Results $results
```
