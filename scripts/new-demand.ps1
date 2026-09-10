<#
.SYNOPSIS
    Creates the STRUCTURE of a demand: the worklogs/<TICKET>/ folder and a CONTEXT.md scaffolded
    from the template. No session, no active demand.

.DESCRIPTION
    Structure only. It does NOT write last_demand.txt, does NOT write active_demands.txt and does
    NOT touch any session file -- running it while another Claude session is live is safe.

    Why the split exists: this script used to write the ticket into last_demand.txt, the resume
    point (fallback 4 of hook_context_inject.ps1). Creating the folder for a new ticket while
    another session was working on a different demand STOLE that resume point, and the next session
    opened without a window reservation -- including the same window reopening claude after an
    /exit -- came up on the freshly created demand. The real cost was creating demand folders by
    hand to avoid trampling a live session.

    To work on the demand once it exists:
      open-parallel.ps1 -ticket <T>                       (new window; it guarantees the structure)
      switch-demand.ps1 -ticket <T> -sessionId <uuid>     (current session)

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
$templateFile = "$worklogRoot\templates\CONTEXT_template.md"

if (-not (Test-Path $templateFile)) {
    Write-Host "Template not found: $templateFile" -ForegroundColor Red
    exit 1
}

# Idempotent and NON-interactive: open-parallel.ps1 calls this script unattended, and the old
# "activate it as current demand?" prompt was exactly the coupling removed here.
if (Test-Path $contextFile) {
    Write-Host "Demand $ticket already has a structure: $contextFile" -ForegroundColor Yellow
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

# Sync to shared repository, and only from the branch WORKLOG_BRANCH names -- see scripts/sync_lib.ps1.
# Off that branch the folder is still created; what is skipped is publishing it.
. "$PSScriptRoot\sync_lib.ps1"   # Get-SyncTarget (WORKLOG_BRANCH, and the refusal to sync from another branch)
$syncTarget = Get-SyncTarget -RepoPath $worklogRoot
if ($syncTarget.Matches) {
    git -C $worklogRoot pull --rebase origin $($syncTarget.Branch)
    if ($LASTEXITCODE -eq 0) {
        git -C $worklogRoot add $demandDir
        git -C $worklogRoot commit -m "demand: $ticket - $name"
        git -C $worklogRoot push origin $($syncTarget.Branch)
    }
} else {
    $headName = if ($syncTarget.Head) { "'$($syncTarget.Head)'" } else { 'a detached HEAD' }
    Write-Host "Not pushed: WORKLOG_BRANCH targets '$($syncTarget.Branch)' and the repo is on $headName." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Structure for demand $ticket created." -ForegroundColor Green
Write-Host ""
Write-Host "  Context: $contextFile"
Write-Host ""
Write-Host "No active demand was changed. Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit CONTEXT.md: code `"$contextFile`""
Write-Host "  2. New window for this demand: scripts\open-parallel.ps1 -ticket $ticket"
Write-Host "  3. Or in the current session: scripts\switch-demand.ps1 -ticket $ticket -sessionId <scratchpad-uuid>"
Write-Host ""
