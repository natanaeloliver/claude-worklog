<#
.SYNOPSIS
    Switches the active demand in the current Claude session without restarting Claude.

.PARAMETER ticket
    Target demand ID. Example: "PROJ-456"

.PARAMETER sessionId
    session_id of the calling session. Claude SHOULD ALWAYS pass this, extracted from the UUID
    of its own scratchpad directory (given in its system prompt, identical to the session_id
    used by the hooks) -- it is the only reliable identifier when multiple Claude sessions run
    concurrently on the same machine. Without it, the script falls back to a PID/flag heuristic
    that can match a DIFFERENT, unrelated Claude session active at the same instant (confirmed
    via live debugging, 2026-07-01).

.EXAMPLE
    .\switch-demand.ps1 -ticket "PROJ-456" -sessionId "da9bd39f-cf6f-46e1-bd7b-dcad64db689f"
#>
param(
    [Parameter(Mandatory)]
    [string]$ticket,
    [string]$sessionId
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$activeFile  = "$worklogRoot\active_demands.txt"
. "$PSScriptRoot\active_demands_lib.ps1"   # Get-ActiveDemands / Set-ActiveDemands (self-healing read + atomic write)
. "$PSScriptRoot\session_lib.ps1"          # Read-DemandFile / Test-SessionAlive / Get-SessionName / Get-RenamePrompt

# 1a. RELIABLE fallback: CLAUDE_CODE_SESSION_ID, which Claude Code exports to its own subprocesses
#     -- and the process running this script IS a subprocess of the calling session, so the variable
#     identifies THAT session and no other (measured: it matches the session's scratchpad UUID).
#     Binding by identity instead of guessing from global state is the same correction applied to
#     handing a demand to a new window (see open-parallel.ps1).
if (-not $sessionId -and $env:CLAUDE_CODE_SESSION_ID) {
    $sessionId = $env:CLAUDE_CODE_SESSION_ID.Trim()
}

# 1b. FRAGILE fallback, last resort: the most recently touched claude_active_{session_id}.flag. It
#     can match a DIFFERENT, unrelated Claude session whose message landed at the same instant
#     (confirmed via live debugging, 2026-07-01). It only ever applies to a manual invocation from
#     OUTSIDE a Claude session, where 1a does not exist -- and it says so out loud when used.
if (-not $sessionId) {
    $activeFlags = @(Get-Item "$env:TEMP\claude_active_*.flag" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($activeFlags.Count -gt 0) {
        $sessionId = $activeFlags[0].BaseName -replace 'claude_active_', ''
        Write-Host "WARNING: session resolved by heuristic (most recent flag): $sessionId" -ForegroundColor Yellow
    }
}

# No JSONL-based fallback: "most recently modified jsonl in the project directory" can belong
# to ANY Claude session in that same directory -- confirmed to cause cross-session state
# corruption between real concurrent sessions (live debugging, 2026-07-01). Prefer failing loud
# over silently guessing wrong. Always pass -sessionId explicitly.

if (-not $sessionId) {
    Write-Host "ERROR: could not determine session_id for the current session." -ForegroundColor Red
    exit 1
}
$demandFile = "$env:TEMP\claude_demand_$sessionId.txt"

# Read current ticket and session identity (line1=ticket, line2=claude.exe pid, line3=creation ticks)
$oldTicket = $null
$session = @{ Pid = 0; Created = '' }
if (Test-Path $demandFile) {
    $dfOwn = Read-DemandFile $demandFile
    if ($dfOwn.Ticket) { $oldTicket = $dfOwn.Ticket }
    if ($dfOwn.Pid -gt 0 -and $dfOwn.Created) { $session = @{ Pid = $dfOwn.Pid; Created = $dfOwn.Created } }
}
if (-not $oldTicket) { $oldTicket = "(unknown)" }

# No usable identity on file (a "ghost" session the inject hook never registered, or a 2-line demand
# file from an older version whose PID cannot be trusted): resolve this session's claude.exe now, by
# walking up the ancestor chain. Avoids writing pid=0, which would make liveness and orphan cleanup
# depend on the heartbeat alone.
if ($session.Pid -le 0) { $session = Get-ClaudeSession }

# Verify target demand exists
if (-not (Test-Path "$worklogRoot\worklogs\$ticket")) {
    Write-Host "ERROR: demand $ticket not found in worklogs/." -ForegroundColor Red
    exit 1
}

# Check for conflict: another live session on the same demand
$conflictWarning = $null
foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue)) {
    $dfSid = $df.BaseName -replace 'claude_demand_', ''
    if ($dfSid -eq $sessionId) { continue }
    $dfData = Read-DemandFile $df.FullName
    if ($dfData.Ticket -ne $ticket) { continue }
    if (Test-SessionAlive $dfData.Pid $dfData.Created "$env:TEMP\claude_active_$dfSid.flag") {
        $conflictWarning = "WARNING: $ticket is already active in another session ($dfSid). Simultaneous edits to CONTEXT.md or session_log.md may cause git conflicts."
    }
}

# Update demand file for this session -- same 3-line format the inject hook writes
Write-DemandFile -Path $demandFile -Ticket $ticket -Session $session

# Update active_demands.txt: replace old ticket with new ticket.
# Same global mutex used by hook_context_inject.ps1/hook_session_end.ps1 -- without it, a
# concurrent write (e.g. a hook from another session running at the same instant) can duplicate
# or drop entries (real bug: a duplicated ticket in active_demands.txt, 2026-07-14).
$worklogMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$worklogMutexAcquired = $false
try {
    try {
        $worklogMutexAcquired = $worklogMutex.WaitOne(10000)
    } catch [System.Threading.AbandonedMutexException] {
        $worklogMutexAcquired = $true
    }

    $lines   = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
    $updated = @($lines | ForEach-Object { if ($_.Trim() -eq $oldTicket) { $ticket } else { $_ } })
    if ($ticket -notin @($updated | ForEach-Object { $_.Trim() })) { $updated = @($updated) + @($ticket) }
    Set-ActiveDemands -Path $activeFile -Tickets $updated
} finally {
    if ($worklogMutexAcquired) { $worklogMutex.ReleaseMutex() }
    $worklogMutex.Dispose()
}

Write-Host "Demand switched: $oldTicket -> $ticket" -ForegroundColor Cyan
if ($conflictWarning) { Write-Host $conflictWarning -ForegroundColor Yellow }

# Tab title: when a window is OPENED, `/rename` goes in as claude's initial prompt (open-parallel.ps1
# and resume-sessions.ps1 do that). Here it cannot: the session is already running, and neither this
# script nor Claude itself can execute a CLI built-in -- there is no tool for it, and there is an open
# issue asking for exactly that API (anthropics/claude-code#33181). So the step is human, and what the
# script can do is hand over the ready-made line. Claude should RELAY this line to the user.
$sessionName = Get-SessionName -Ticket $ticket -WorklogsDir "$worklogRoot\worklogs"
Write-Host ""
Write-Host "Rename the tab (human step -- paste into the session):" -ForegroundColor Yellow
Write-Host "  /rename $sessionName" -ForegroundColor Yellow

# Display new demand context
$contextFile = "$worklogRoot\worklogs\$ticket\CONTEXT.md"
if (Test-Path $contextFile) {
    Get-Content $contextFile -Raw -Encoding utf8
} else {
    Write-Host "CONTEXT.md not found for $ticket." -ForegroundColor Yellow
}
