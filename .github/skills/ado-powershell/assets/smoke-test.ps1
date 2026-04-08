<#
.SYNOPSIS
  Smoke test for the Azure DevOps PowerShell Skill.
  Validates authentication and the main read endpoints.

.USAGE
  # 1. Set environment variables (only if not already done):
  $env:ADO_PAT     = '<your-PAT>'
  $env:ADO_ORG     = '<your-organization>'    # e.g. 'contoso'
  $env:ADO_PROJECT = '<your-project>'         # e.g. 'MyApp'

  # 2. Run:
  . .\github\skills\ado-powershell\assets\smoke-test.ps1

.NOTES
  This script does not modify any data. Safe to run in production.
#>

param(
    [string]$Org        = '',
    [string]$Project    = '',
    [string]$ApiV       = '',
    [string]$Pat        = '',
    [string]$ConfigPath = '',
    [int]$SampleWiId   = 0,   # Optional: ID of an existing Work Item to test
    [int]$SamplePlanId = 0    # Optional: ID of an existing Test Plan to test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Dot-source the skill --
$skillRoot = Join-Path $PSScriptRoot '..'
. (Join-Path $skillRoot 'scripts\ado-base.ps1')
. (Join-Path $skillRoot 'scripts\ado-workitems.ps1')
. (Join-Path $skillRoot 'scripts\ado-testing.ps1')
. (Join-Path $skillRoot 'scripts\ado-git.ps1')

# -- Test utilities --─────
$passed = 0
$failed = 0

function Test-Step {
    param([string]$Name, [scriptblock]$Block)
    Write-Host "`n  > $Name" -NoNewline
    try {
        $result = & $Block
        Write-Host " (ok)" -ForegroundColor Green
        $script:passed++
        return $result
    }
    catch {
        Write-Host " (fail)  $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
        return $null
    }
}

# -- Start --
Write-Host "`n---------------------------------------" -ForegroundColor Cyan
Write-Host "  ADO PowerShell Skill - Smoke Test" -ForegroundColor Cyan
Write-Host "---------------------------------------" -ForegroundColor Cyan

# Initialize session - Resolve-AdoConfig inside will throw if required values are missing
try {
    $initArgs = @{}
    if ($Org)        { $initArgs.Org        = $Org        }
    if ($Project)    { $initArgs.Project    = $Project    }
    if ($ApiV)       { $initArgs.ApiV       = $ApiV       }
    if ($Pat)        { $initArgs.Pat        = $Pat        }
    if ($ConfigPath) { $initArgs.ConfigPath = $ConfigPath }
    $script:AdoSession = Initialize-AdoSession @initArgs
} catch {
    Write-Host "FAIL: Could not initialise session: $_" -ForegroundColor Red
    exit 1
}
Write-Host "  Org: $($script:AdoSession.Org)  -  Project: $($script:AdoSession.Project)" -ForegroundColor Cyan
Write-Host "---------------------------------------" -ForegroundColor Cyan

# Test 1 -- List projects
$projects = Test-Step "GET /_apis/projects (list projects)" {
    $r = Get-AdoProjects
    if (-not $r -or $r.Count -eq 0) { throw "No projects returned." }
    $r
}
if ($projects) {
    $resolvedProject = $script:AdoSession.Project
    $found  = $projects | Where-Object name -eq $resolvedProject
    $status = if ($found) { "found '$resolvedProject'" } else { "WARNING: '$resolvedProject' not found in the org" }
    Write-Host "     -> $($projects.Count) projects. $status" -ForegroundColor Gray
}

# Test 2 -- Individual Work Item (if ID provided)
if ($SampleWiId -gt 0) {
    $wi = Test-Step "GET /wit/workitems/$SampleWiId" {
        Get-AdoWorkItem -Id $SampleWiId
    }
    if ($wi) {
        Write-Host "     - [$($wi.id)] $($wi.fields.'System.WorkItemType') | $($wi.fields.'System.Title') | $($wi.fields.'System.State')" -ForegroundColor Gray
    }
}

# Test 3 -- Basic WIQL
$wiqlResults = Test-Step "POST /wit/wiql (basic query)" {
    Invoke-AdoWiql -Query "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.State] <> 'Closed'" -Top 5
}
if ($wiqlResults) {
    Write-Host "     - $($wiqlResults.Count) Work Items returned (top 5)" -ForegroundColor Gray
}

# Test 4 -- Git Repositories
$repos = Test-Step "GET /git/repositories (repositories)" {
    Get-AdoRepositories
}
if ($repos) {
    Write-Host "     - $($repos.Count) repository(s): $($repos.name -join ', ')" -ForegroundColor Gray
}

# Test 5 -- Test Plans (if Plan ID provided)
if ($SamplePlanId -gt 0) {
    $tp = Test-Step "GET /testplan/plans/$SamplePlanId" {
        Get-AdoTestPlan -PlanId $SamplePlanId
    }
    if ($tp) {
        Write-Host "     - '$($tp.name)' | State: $($tp.state)" -ForegroundColor Gray
    }
}

# -- Summary --
Write-Host "`n---------------------------------------" -ForegroundColor Cyan
$totalColor = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "  Result: $passed passed, $failed failed" -ForegroundColor $totalColor
Write-Host "---------------------------------------`n" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
