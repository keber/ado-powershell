# Azure DevOps PowerShell Skill — single-entry loader
# Usage:  . .github/skills/ado-powershell/load.ps1
# Dot-sources all skill scripts and auto-initialises the session
# when ADO_PAT, ADO_ORG and ADO_PROJECT environment variables are set.

. "$PSScriptRoot/scripts/ado-base.ps1"
. "$PSScriptRoot/scripts/ado-workitems.ps1"
. "$PSScriptRoot/scripts/ado-testing.ps1"
. "$PSScriptRoot/scripts/ado-pipelines.ps1"
. "$PSScriptRoot/scripts/ado-git.ps1"

if ($env:ADO_PAT -or $env:AZURE_DEVOPS_EXT_PAT) {
    try {
        $AdoSession = Initialize-AdoSession
        Write-Host "(ok) ADO session ready — Org: $($AdoSession.Org)  Project: $($AdoSession.Project)" -ForegroundColor Green
    } catch {
        Write-Host "ADO skill loaded but session could not be initialised: $_" -ForegroundColor Yellow
        Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project>' -ForegroundColor Yellow
    }
} else {
    $missing = @('ADO_ORG','ADO_PROJECT','ADO_PAT') | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
    Write-Host "ADO skill loaded. Missing env vars: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project> -Pat <pat>' -ForegroundColor Yellow
}