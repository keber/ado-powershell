# Azure DevOps PowerShell Skill - single-entry loader
# Usage:  . .github/skills/ado-powershell/load.ps1
# Dot-sources all skill scripts and auto-initialises the session when a credential is present:
# ADO_PAT / AZURE_DEVOPS_EXT_PAT, ADO_PAT_READ / ADO_PAT_WRITE, or SYSTEM_ACCESSTOKEN.
# Access: ADO_ACCESS (Read|Write) when set; otherwise Read when only ADO_PAT_READ is available,
# Write in every other case (today's behaviour).

. "$PSScriptRoot/scripts/ado-base.ps1"
. "$PSScriptRoot/scripts/ado-workitems.ps1"
. "$PSScriptRoot/scripts/ado-content.ps1"
. "$PSScriptRoot/scripts/ado-testing.ps1"
. "$PSScriptRoot/scripts/ado-pipelines.ps1"
. "$PSScriptRoot/scripts/ado-git.ps1"
. "$PSScriptRoot/scripts/ado-pullrequests.ps1"

$adoLoadWriteCred = [bool]($env:ADO_PAT_WRITE -or $env:ADO_PAT -or $env:AZURE_DEVOPS_EXT_PAT -or $env:SYSTEM_ACCESSTOKEN)
if ($adoLoadWriteCred -or $env:ADO_PAT_READ) {
    $adoLoadAccess = if ($env:ADO_ACCESS -in 'Read', 'Write') { $env:ADO_ACCESS }
                     elseif (-not $adoLoadWriteCred)          { 'Read' }
                     else                                     { 'Write' }
    if ($env:ADO_ACCESS -and $env:ADO_ACCESS -notin 'Read', 'Write') {
        Write-Host "ADO_ACCESS must be Read or Write; ignoring it and using $adoLoadAccess." -ForegroundColor Yellow
    }
    try {
        $AdoSession = Initialize-AdoSession -Access $adoLoadAccess
        Write-Host "(ok) ADO session ready - Org: $($AdoSession.Org)  Project: $($AdoSession.Project)  Access: $($AdoSession.Access)  Auth: $($AdoSession.AuthScheme)" -ForegroundColor Green
    } catch {
        Write-Host "ADO skill loaded but session could not be initialised: $_" -ForegroundColor Yellow
        Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project> [-Access Read|Write]' -ForegroundColor Yellow
    }
    Remove-Variable -Name adoLoadAccess -ErrorAction SilentlyContinue
} else {
    $missing = @('ADO_ORG','ADO_PROJECT','ADO_PAT') | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
    Write-Host "ADO skill loaded. Missing env vars: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project> [-Access Read|Write]' -ForegroundColor Yellow
}
Remove-Variable -Name adoLoadWriteCred -ErrorAction SilentlyContinue
