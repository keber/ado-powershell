# Error handling - Azure DevOps PowerShell Skill

## Behavior by HTTP status code

| Code | Common cause | `Invoke-AdoRequest` behavior |
|------|--------------|------------------------------|
| `200-299` | Success | Returns parsed response as object |
| `401 Unauthorized` | Invalid, expired or malformed PAT | Immediate error - **no retry** |
| `401` / `403` with `VS403463` | Microsoft Entra Conditional Access policy (network location / device) | ErrorId `AdoConditionalAccess` - **no retry**; a new PAT will not help |
| (none sent) | Write attempted on a `-Access Read` session | ErrorId `AdoReadOnlySession` - request never sent |
| `403 Forbidden` | PAT scope insufficient for that operation | Immediate error - **no retry** |
| `404 Not Found` | Non-existent resource ID or wrong URL | Immediate error - **no retry** |
| `409 Conflict` | Resource state conflict (e.g. PR merge conflict, stale commit) | Original error rethrown (status + server message) - **no retry, any method** |
| `429 Too Many Requests` | ADO rate limit (API quota) | Exponential backoff up to `$MaxRetries` |
| `503 Service Unavailable` | ADO temporarily unavailable | Exponential backoff up to `$MaxRetries` |
| Other 5xx | Transient server error | Linear backoff up to `$MaxRetries` |

> **Note:** Retries for 429/503 use `$RetryDelaySec * 2^attempt` seconds.  
> With default values (MaxRetries=3, RetryDelaySec=2): 4 s → 8 s → fail.

---

## Recommended try/catch pattern

```powershell
try {
    $wi = Get-AdoWorkItem -Id 99999
    Write-Host "$($wi.id) | $($wi.fields.'System.Title')"
}
catch {
    $msg = $_.Exception.Message
    switch -Regex ($msg) {
        '401'  { Write-Error "Invalid or expired PAT. Renew ADO_PAT."; break }
        '403'  { Write-Error "No permissions. Check the PAT scope."; break }
        '404'  { Write-Warning "Resource not found."; break }
        default { throw }   # re-throw unexpected errors
    }
}
```

---

## Diagnosing HTML errors

If `Invoke-AdoRequest` throws `"Server returned HTML"`, likely causes are:

1. **Expired or invalid PAT** - ADO redirects to the login page instead of returning 401.
2. **Wrong URL** - organization or project name has a typo.
3. **Blocked IP / corporate proxy** - intermediate server returns HTML.
4. **WinINet cookie leak (Windows PowerShell 5.1 only)** - `Invoke-RestMethod` in PS 5.1
   shares the cookie store with IE/Edge Legacy. If a browser session is active, ADO may
   accept the cookie and return data - masking a broken PAT. In PS 7+ `HttpClient` is used
   and cookies are never shared, so auth failures are consistent.

Verify with:

```powershell
# Directly test authentication:
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$env:ADO_PAT"))
Invoke-RestMethod -Uri "https://dev.azure.com/$env:ADO_ORG/_apis/projects?api-version=7.1" `
    -Headers @{ Authorization = "Basic $b64" }
```

---

## Minimum PAT permissions by operation

| PAT Scope | Enables |
|-----------|--------|
| `Work Items (Read)` | `Get-AdoWorkItem`, `Get-AdoWorkItemsBatch`, `Invoke-AdoWiql`, `Get-AdoWorkItemComments`, `Get-AdoWorkItemRevisions` |
| `Work Items (Read & Write)` | `New-AdoWorkItem`, `Update-AdoWorkItem`, `Add-AdoWorkItemComment`, `Add-AdoWorkItemLink`, `Add-AdoWorkItemAttachment` |
| `Test Management (Read)` | `Get-AdoTestPlans`, `Get-AdoTestPlan`, `Get-AdoTestSuites`, `Get-AdoTestCases`, `Get-AdoTestRuns`, `Get-AdoTestRunResults` |
| `Test Management (Read & Write)` | `New-AdoTestPlan`, `New-AdoTestSuite`, `New-AdoTestCase`, `Add-AdoTestCaseToSuite`, `New-AdoTestRun`, `Update-AdoTestRunResults` |
| `Code (Read)` | `Get-AdoRepositories`, `Get-AdoBranches`, every `Get-AdoPullRequest*` function |
| `Code (Read & Write)` | `New-/Set-/Stop-/Restore-/Complete-AdoPullRequest`, auto-complete, reviewers and votes, threads and comments, labels |
| `Code (Status)` | `New-AdoPullRequestStatus` (scope name per the PAT UI; not verified against a real org) |
| `Build (Read)` | `Get-AdoPipelines`, `Get-AdoPipelineRuns` |
| `Build (Read & Execute)` | `Invoke-AdoPipelineRun` |
| `Project and Team (Read)` | `Get-AdoProjects`, `Get-AdoTeams`, `Get-AdoIterations` |

> **Principle of least privilege:** create the PAT with only the scopes you
> need. For read-only use, do not grant write permissions.
