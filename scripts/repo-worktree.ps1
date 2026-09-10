<#
.SYNOPSIS
    Reads or records whether a registered repository uses a git worktree per demand.
    The answer is stored in repos.conf ("<alias>.worktree=yes|no") so it is asked only once.

.DESCRIPTION
    Creating a fresh worktree gives an empty working directory: everything git does not track has to
    be rebuilt there -- dependencies, local .env files, generated clients, seeded local databases.
    For a small repository that is seconds; for an application repository it is a full reinstall and
    reconfiguration on every demand, which is rework. So the choice belongs to each repository (and
    often to each machine), not to a global convention.

    With no -Use, prints the current preference: yes, no, or ask (not answered yet).
    Called with no -Alias, prints the preference of every registered repository.

.PARAMETER Alias
    Repository alias as registered in repos.conf. Omit to list all.

.PARAMETER Use
    Records the answer: "yes" (worktree per demand) or "no" (work in the main copy on a demand branch).

.EXAMPLE
    .\repo-worktree.ps1
    .\repo-worktree.ps1 -Alias backend
    .\repo-worktree.ps1 -Alias backend -Use no
#>
param(
    [string]$Alias,
    [ValidateSet('yes', 'no')]
    [string]$Use
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$confPath    = "$worklogRoot\repos.conf"
. "$PSScriptRoot\repos_lib.ps1"

if (-not (Test-Path $confPath)) {
    Write-Host "repos.conf not found at $confPath. Run setup.ps1 first." -ForegroundColor Red
    exit 1
}

if ($Use) {
    if (-not $Alias) {
        Write-Host "ERROR: -Use requires -Alias." -ForegroundColor Red
        exit 1
    }
    try {
        Set-RepoWorktreePreference -ConfPath $confPath -Alias $Alias -Value $Use
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $explanation = if ($Use -eq 'yes') {
        "work on this repo goes in a worktree under worklogs/<TICKET>/"
    } else {
        "work on this repo goes in the main copy, on a branch named after the demand"
    }
    Write-Host "$Alias worktree=$Use -- $explanation" -ForegroundColor Cyan
    exit 0
}

$repos = @(Get-Repos -ConfPath $confPath)
if ($repos.Count -eq 0) {
    Write-Host "No repositories registered in repos.conf." -ForegroundColor Yellow
    exit 0
}

if ($Alias) {
    $pref = Get-RepoWorktreePreference -ConfPath $confPath -Alias $Alias
    if ($null -eq $pref) {
        Write-Host "ERROR: alias '$Alias' is not registered in repos.conf." -ForegroundColor Red
        exit 1
    }
    Write-Output $pref
    exit 0
}

$repos | Select-Object Alias, Worktree, Path | Format-Table -AutoSize
if (@($repos | Where-Object { $_.Worktree -eq 'ask' }).Count -gt 0) {
    Write-Host "'ask' means not answered yet -- Claude asks once, then records it here." -ForegroundColor DarkGray
}
