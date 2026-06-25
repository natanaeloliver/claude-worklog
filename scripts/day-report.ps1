<#
.SYNOPSIS
    Daily activity summary: commits, session log, and open (uncommitted) files.

.PARAMETER Date
    Date in yyyy-MM-dd format. Defaults to today.

.EXAMPLE
    .\day-report.ps1
    .\day-report.ps1 -Date 2026-05-28
#>
param(
    [string]$Date = ""
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$today       = Get-Date -Format 'yyyy-MM-dd'
$isToday     = (-not $Date)
if (-not $Date) { $Date = $today }

# Read monitored repos from repos.conf
function Read-ReposConf {
    param([string]$confPath)
    $result = [ordered]@{}
    if (-not (Test-Path $confPath)) { return $result }
    foreach ($line in Get-Content $confPath -Encoding utf8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $alias = $line.Substring(0, $idx).Trim()
        $path  = $line.Substring($idx + 1).Trim()
        if ($alias -and $path) { $result[$alias] = $path }
    }
    return $result
}

$repos = Read-ReposConf "$worklogRoot\repos.conf"
$repos["worklog"] = $worklogRoot

$gitUser = (git -C $worklogRoot config user.name 2>$null)
if ($gitUser) { $gitUser = $gitUser.Trim() }
if (-not $gitUser) { $gitUser = $env:USERNAME }

Write-Host ""
Write-Host "=== day-report: $Date -- $gitUser ===" -ForegroundColor Cyan
Write-Host ""

# Collect commits grouped by ticket
$commitsByTicket = @{}
$commitsNoTicket = [ordered]@{}
foreach ($entry in $repos.GetEnumerator()) {
    $repoPath = $entry.Value
    if (-not (Test-Path "$repoPath\.git")) { continue }
    Push-Location $repoPath
    try {
        $rawCommits = @(git log --oneline --after="$Date 00:00" --before="$Date 23:59" 2>$null)
        foreach ($c in $rawCommits) {
            if ($c -match '([A-Z]+-\d+)') {
                $t = $matches[1]
                if (-not $commitsByTicket.ContainsKey($t)) { $commitsByTicket[$t] = [System.Collections.Generic.List[object]]::new() }
                $commitsByTicket[$t].Add([pscustomobject]@{ Repo = $entry.Key; Line = $c })
            } else {
                if (-not $commitsNoTicket.Contains($entry.Key)) { $commitsNoTicket[$entry.Key] = [System.Collections.Generic.List[string]]::new() }
                $commitsNoTicket[$entry.Key].Add($c)
            }
        }
    } finally { Pop-Location }
}

# Collect session logs for the day
$logsToSearch = Get-ChildItem "$worklogRoot\worklogs\*\session_log.md" -EA SilentlyContinue |
    Select-Object -ExpandProperty FullName

$rgAvailable = [bool](Get-Command rg -ErrorAction SilentlyContinue)
$pat         = "^## $Date $([regex]::Escape($gitUser))(?:\r?\n(?!## ).*)*"

$encPrev = [Console]::OutputEncoding
if ($rgAvailable) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 }

$sessionLogsByTicket = @{}
try {
    foreach ($logPath in $logsToSearch) {
        $demandDir = Split-Path (Split-Path $logPath -Parent) -Leaf
        if ($rgAvailable) {
            $block = & rg -UP --crlf $pat -- "$logPath"
        } else {
            $block = $null
            $lines = Get-Content $logPath -Encoding utf8
            $idx   = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -eq "## $Date $gitUser") { $idx = $i; break }
            }
            if ($idx -ge 0) {
                $end = $lines.Count
                for ($i = $idx + 1; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^## ') { $end = $i; break }
                }
                $block = $lines[$idx..($end - 1)]
            }
        }
        if ($block) { $sessionLogsByTicket[$demandDir] = $block }
    }
} finally {
    [Console]::OutputEncoding = $encPrev
}

# Display: demands with activity (commits or session log), grouped by demand -> repo -> commit
$emdash    = [char]0x2014
$allTickets = @(@($commitsByTicket.Keys) + @($sessionLogsByTicket.Keys)) | Sort-Object -Unique

Write-Host "--- Activity $Date ---" -ForegroundColor Yellow

if ($allTickets.Count -eq 0 -and $commitsNoTicket.Count -eq 0) {
    Write-Host "  (no activity for $Date)" -ForegroundColor DarkGray
}

foreach ($t in $allTickets) {
    $ctxPath = "$worklogRoot\worklogs\$t\CONTEXT.md"
    $title   = ""
    if (Test-Path $ctxPath) {
        $firstLine = Get-Content $ctxPath -TotalCount 1 -Encoding utf8
        if ($firstLine -match "[$emdash-]\s*(.+)$") { $title = " $emdash $($matches[1].Trim())" }
    }
    Write-Host ""
    Write-Host "[$t$title]" -ForegroundColor DarkCyan

    if ($commitsByTicket.ContainsKey($t)) {
        $byRepo = $commitsByTicket[$t] | Group-Object Repo
        foreach ($g in $byRepo) {
            Write-Host "  [$($g.Name)]" -ForegroundColor DarkGray
            $g.Group | ForEach-Object { Write-Host "    $($_.Line)" }
        }
    }

    if ($sessionLogsByTicket.ContainsKey($t)) {
        if ($commitsByTicket.ContainsKey($t)) { Write-Host "" }
        $sessionLogsByTicket[$t] | ForEach-Object { Write-Host "  $_" }
    }
}

if ($commitsNoTicket.Count -gt 0) {
    Write-Host ""
    Write-Host "[no demand]" -ForegroundColor DarkGray
    foreach ($repoKey in $commitsNoTicket.Keys) {
        Write-Host "  [$repoKey]" -ForegroundColor DarkGray
        $commitsNoTicket[$repoKey] | ForEach-Object { Write-Host "    $_" }
    }
}
Write-Host ""

# Uncommitted files -- only when running for today
if ($isToday) {
    Write-Host "--- Open (uncommitted) ---" -ForegroundColor Yellow
    $anyOpen = $false
    foreach ($entry in $repos.GetEnumerator()) {
        $repoPath = $entry.Value
        if (-not (Test-Path "$repoPath\.git")) { continue }
        Push-Location $repoPath
        try {
            $files = @(git diff --name-only 2>$null) +
                     @(git diff --name-only --cached 2>$null) +
                     @(git ls-files --others --exclude-standard 2>$null) |
                Where-Object { $_ } | Sort-Object -Unique
            if ($files) {
                $anyOpen = $true
                $files | ForEach-Object { Write-Host "  [$($entry.Key)] $_" }
            }
        } finally { Pop-Location }
    }
    if (-not $anyOpen) {
        Write-Host "  none" -ForegroundColor DarkGray
    }
    Write-Host ""
}
