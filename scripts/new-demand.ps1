<#
.SYNOPSIS
    Creates a new demand in the claude-worklog system.

.PARAMETER ticket
    Ticket ID. Examples: "PROJ-001", "TSK-123", "ISSUE-42"

.PARAMETER name
    Short descriptive name. Example: "Implement user authentication"

.PARAMETER sprint
    Sprint reference. Example: "Sprint2026.S11"

.PARAMETER type
    Demand type. Examples: "feature", "bugfix", "refactor", "investigation"

.PARAMETER owner
    Owner username. Defaults to git user.name.

.EXAMPLE
    .\new-demand.ps1 -ticket "PROJ-001" -name "Implement user auth" -sprint "Sprint2026.S11"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ticket,

    [Parameter(Mandatory=$true)]
    [string]$name,

    [string]$repos  = "",
    [string]$sprint = "",
    [string]$type   = "feature",
    [string]$owner  = ""
)

$worklogRoot  = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$demandDir    = "$worklogRoot\worklogs\$ticket"
$contextFile  = "$demandDir\CONTEXT.md"
$currentFile  = "$worklogRoot\current_demand.txt"
$templateFile = "$worklogRoot\templates\CONTEXT_template.md"

if (-not (Test-Path $templateFile)) {
    Write-Host "Template not found: $templateFile" -ForegroundColor Red
    exit 1
}

if (Test-Path $contextFile) {
    Write-Host "Demand $ticket already exists: $contextFile" -ForegroundColor Yellow
    $answer = Read-Host "Activate it as current demand? (y/N)"
    if ($answer -match '^[yY]$') {
        Set-Content -Path $currentFile -Value $ticket -Encoding utf8
        Write-Host "Demand $ticket activated." -ForegroundColor Green
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $demandDir | Out-Null

if (-not $owner) {
    $owner = (git -C $worklogRoot config user.name 2>$null)
    if ($owner) { $owner = $owner.Trim() }
    if (-not $owner) { $owner = $env:USERNAME }
}

$dateCreated = Get-Date -Format 'yyyy-MM-dd'
$content = Get-Content $templateFile -Raw -Encoding utf8

$reposList = if ($repos) {
    ($repos -split ',\s*' | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`n"
} else {
    "- (none specified, see repos.conf)"
}

$content = $content `
    -replace '\{TICKET_ID\}',    $ticket `
    -replace '\{NAME\}',         $name `
    -replace '\{TYPE\}',         $type `
    -replace '\{SPRINT\}',       $sprint `
    -replace '\{OWNER\}',        $owner `
    -replace '\{DATE_CREATED\}', $dateCreated `
    -replace '\{REPOSITORIES\}', $reposList `
    -replace '\{DESCRIPTION\}',  "TODO: describe the demand in 2-3 lines." `
    -replace '\{NEXT_ACTION\}',  "TODO: define the first next step"

Set-Content -Path $contextFile -Value $content -Encoding utf8
Set-Content -Path $currentFile -Value $ticket  -Encoding utf8

# Sync to shared repository
git -C $worklogRoot pull --rebase origin main
if ($LASTEXITCODE -eq 0) {
    git -C $worklogRoot add $demandDir
    git -C $worklogRoot commit -m "demand: $ticket - $name"
    git -C $worklogRoot push origin main
}

Write-Host ""
Write-Host "Demand $ticket created." -ForegroundColor Green
Write-Host ""
Write-Host "  Context: $contextFile"
Write-Host "  Active:  $currentFile"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit CONTEXT.md: code `"$contextFile`""
Write-Host "  2. Open Claude in your working repository"
Write-Host "  3. Claude will automatically read the demand context"
Write-Host ""
