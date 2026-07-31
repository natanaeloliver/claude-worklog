<#
.SYNOPSIS
    Daily summary. The source of truth is each demand's session_log.md -- commits come in as
    supporting evidence only, never as the basis for grouping (see the comments in the commit block).

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
$activeFile  = "$worklogRoot\active_demands.txt"
$lastFile    = "$worklogRoot\last_demand.txt"
. "$PSScriptRoot\active_demands_lib.ps1"   # Get-ActiveDemands (self-healing read)
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

# Report label: the demand with a live session right now (active_demands.txt) and, failing that, the
# resume point (last_demand.txt). It used to read current_demand.txt, retired 2026-07-28.
$ticket = ""
foreach ($line in (Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs")) {
    if ($line.Trim()) { $ticket = $line.Trim(); break }
}
if (-not $ticket -and (Test-Path $lastFile)) {
    $raw = Get-Content $lastFile -Raw -Encoding utf8 -EA SilentlyContinue
    if ($raw) { $ticket = $raw.Trim() }
}

$demandLabel = if ($isToday -and $ticket) { $ticket } else { "all demands" }
Write-Host ""
Write-Host "=== day-report: $Date -- $gitUser ($demandLabel) ===" -ForegroundColor Cyan
Write-Host ""

# --- Commits: SUPPORTING evidence, not the source of truth ------------------------------------
# The source of truth for the day's activity is each demand's session_log.md (block below).
# Commits come in only as evidence, and attribution depends on the repo:
#
#  - worklog: attribute by PATH (worklogs/<TICKET>/...). The Stop hook runs `git add -A` on a
#    working tree shared by every parallel session and commits under ITS OWN session's ticket, so the
#    message frequently credits the work to the wrong demand (real case: one demand's edits committed
#    under another demand's ticket). The file path does not lie.
#  - monitored repos: attribute by MESSAGE. There, commits are written by hand with the ticket, and
#    the file path does not carry the demand.
#
# A worklog commit touching no demand directory is infrastructure (hooks, scripts, docs).
$commitsByTicket = @{}
$commitsInfra    = [System.Collections.Generic.List[object]]::new()
$commitsNoTicket = [ordered]@{}

function Add-CommitToTicket {
    param([string]$Ticket, [string]$Repo, [string]$Line, [string]$DivergentLabel)
    if (-not $commitsByTicket.ContainsKey($Ticket)) {
        $commitsByTicket[$Ticket] = [System.Collections.Generic.List[object]]::new()
    }
    $commitsByTicket[$Ticket].Add([pscustomobject]@{ Repo = $Repo; Line = $Line; Divergent = $DivergentLabel })
}

foreach ($entry in $repos.GetEnumerator()) {
    $repoPath = $entry.Value
    if (-not (Test-Path "$repoPath\.git")) { continue }
    Push-Location $repoPath
    try {
        if ($entry.Key -eq 'worklog') {
            # --name-only plus a commit-start marker, to join metadata and paths.
            $sep = [char]0x1f
            $raw = @(git log --after="$Date 00:00" --before="$Date 23:59" --name-only `
                        --pretty=format:"@@C@@%h$sep%s" 2>$null)
            $short = $null; $subject = $null
            $paths = [System.Collections.Generic.List[string]]::new()

            $flush = {
                if (-not $short) { return }
                $commitTickets = @($paths |
                    ForEach-Object { if ($_ -match '^worklogs/([^/]+)/') { $matches[1] } } |
                    Where-Object { $_ } | Sort-Object -Unique)
                $label = if ($subject -match '([A-Za-z][A-Za-z0-9]*-\d+)') { $matches[1] } else { $null }
                if ($commitTickets.Count -eq 0) {
                    $commitsInfra.Add([pscustomobject]@{ Line = "$short $subject"; Label = $label })
                } else {
                    foreach ($t in $commitTickets) {
                        # Commit label != demand owning the file -> surface the divergence
                        $div = if ($label -and $label -ne $t) { $label } else { $null }
                        Add-CommitToTicket $t $entry.Key "$short $subject" $div
                    }
                }
            }

            foreach ($line in $raw) {
                if ($line -like '@@C@@*') {
                    & $flush
                    $parts   = ($line.Substring(5) -split $sep, 2)
                    $short   = $parts[0]
                    $subject = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                    $paths   = [System.Collections.Generic.List[string]]::new()
                } elseif ($line -and $line.Trim()) {
                    $paths.Add($line.Trim())
                }
            }
            & $flush
        } else {
            $rawCommits = @(git log --oneline --after="$Date 00:00" --before="$Date 23:59" 2>$null)
            foreach ($c in $rawCommits) {
                if ($c -match '([A-Za-z][A-Za-z0-9]*-\d+)') {
                    Add-CommitToTicket $matches[1] $entry.Key $c $null
                } else {
                    if (-not $commitsNoTicket.Contains($entry.Key)) { $commitsNoTicket[$entry.Key] = [System.Collections.Generic.List[string]]::new() }
                    $commitsNoTicket[$entry.Key].Add($c)
                }
            }
        }
    } finally { Pop-Location }
}

# --- Session logs: SOURCE OF TRUTH -----------------------------------------------------------
# ALWAYS scans every demand, never just the active one: a normal day touches several demands
# (parallel sessions, mid-session switches), and restricting to the current demand hid real work.
$logsToSearch = @(Get-ChildItem "$worklogRoot\worklogs\*\session_log.md" -EA SilentlyContinue |
    Select-Object -ExpandProperty FullName)

# Extract the session block with ripgrep: from the "## DATE USER" header up to just before the next
# "## ". -P (PCRE2) enables the (?!## ) lookahead; --crlf + \r?\n because session_log.md files are
# CRLF. Falls back to a manual line scan if rg is not on PATH.
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

# --- Display ---------------------------------------------------------------------------------
# Deliberate order: demands WITH a session_log entry first (the source of truth), then what shows up
# only in git (a commit with no entry is an audit-trail gap, and actionable), then infrastructure and
# commits with no ticket.
# Dash characters via escape, never as literals: PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so a
# literal en/em dash in the source is mangled and the pattern below silently stops matching.
$emdash    = [char]0x2014
$endash    = [char]0x2013
$dashClass = "[-$endash$emdash]"

function Get-DemandTitle {
    param([string]$Ticket)
    $ctxPath = "$worklogRoot\worklogs\$Ticket\CONTEXT.md"
    if (-not (Test-Path $ctxPath)) { return "" }
    # Anchored on the template's real first line ("# Demand <TICKET> - <NAME>"). Matching any dash
    # anywhere on the line was wrong: the hyphen inside the ticket itself matched first, so
    # "# Demand PROJ-001 - Add auth" produced the title "001 - Add auth".
    $firstLine = Get-Content $ctxPath -TotalCount 1 -Encoding utf8
    if ($firstLine -match "^\s*#\s*Demand\s+\S+\s*$dashClass\s*(.+)$") { return " $emdash $($matches[1].Trim())" }
    return ""
}

function Show-DemandCommits {
    param([string]$Ticket)
    if (-not $commitsByTicket.ContainsKey($Ticket)) { return }
    foreach ($g in ($commitsByTicket[$Ticket] | Group-Object Repo)) {
        Write-Host "  [$($g.Name)]" -ForegroundColor DarkGray
        foreach ($c in $g.Group) {
            if ($c.Divergent) {
                Write-Host "    $($c.Line)" -NoNewline
                Write-Host "   <- committed under [$($c.Divergent)]" -ForegroundColor DarkYellow
            } else {
                Write-Host "    $($c.Line)"
            }
        }
    }
}

$ticketsWithLog = @($sessionLogsByTicket.Keys | Sort-Object)
$ticketsGitOnly = @($commitsByTicket.Keys | Where-Object { $_ -notin $ticketsWithLog } | Sort-Object)

Write-Host "--- Activity $Date (source: session_log.md) ---" -ForegroundColor Yellow

if ($ticketsWithLog.Count -eq 0) {
    Write-Host "  (no demand with a session_log entry for $Date)" -ForegroundColor DarkGray
}

foreach ($t in $ticketsWithLog) {
    Write-Host ""
    Write-Host "[$t$(Get-DemandTitle $t)]" -ForegroundColor DarkCyan
    $sessionLogsByTicket[$t] | ForEach-Object { Write-Host "  $_" }
    if ($commitsByTicket.ContainsKey($t)) {
        Write-Host ""
        Write-Host "  related commits:" -ForegroundColor DarkGray
        Show-DemandCommits $t
    }
}

if ($ticketsGitOnly.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Commits with no session_log entry ---" -ForegroundColor Yellow
    Write-Host "  Files of the demand changed, but there is no '## $Date $gitUser' entry in its" -ForegroundColor DarkGray
    Write-Host "  session_log.md. If the work was yours, the log entry is missing." -ForegroundColor DarkGray
    foreach ($t in $ticketsGitOnly) {
        Write-Host ""
        Write-Host "[$t$(Get-DemandTitle $t)]" -ForegroundColor DarkCyan
        Show-DemandCommits $t
    }
}

if ($commitsInfra.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Worklog infrastructure (outside worklogs/) ---" -ForegroundColor Yellow
    foreach ($c in $commitsInfra) {
        if ($c.Label) {
            Write-Host "  $($c.Line)" -NoNewline
            Write-Host "   <- committed under [$($c.Label)]" -ForegroundColor DarkYellow
        } else {
            Write-Host "  $($c.Line)"
        }
    }
}

if ($commitsNoTicket.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Commits with no ticket in the message (monitored repos) ---" -ForegroundColor Yellow
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
            $files = (@(git diff --name-only 2>$null) +
                      @(git diff --name-only --cached 2>$null) +
                      @(git ls-files --others --exclude-standard 2>$null)) |
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
