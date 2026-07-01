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

# Fallback (sessionId not provided): most recently touched claude_active_{session_id}.flag.
# FRAGILE HEURISTIC -- can match a DIFFERENT, unrelated Claude session active on the same
# machine at the same instant. Only used when -sessionId was not passed (e.g. manual invocation
# outside a Claude session).
if (-not $sessionId) {
    $activeFlags = @(Get-Item "$env:TEMP\claude_active_*.flag" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($activeFlags.Count -gt 0) { $sessionId = $activeFlags[0].BaseName -replace 'claude_active_', '' }
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

# Read current ticket and PID (line1=ticket, line2=claude.exe pid)
$oldTicket = $null
$existingPid = 0
if (Test-Path $demandFile) {
    $dfLines = @(Get-Content $demandFile -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    if ($dfLines.Count -gt 0) { $oldTicket = $dfLines[0].Trim() }
    if ($dfLines.Count -gt 1) { try { $existingPid = [int]$dfLines[1].Trim() } catch { $existingPid = 0 } }
}
if (-not $oldTicket) { $oldTicket = "(unknown)" }

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
    $dfLines  = @(Get-Content $df.FullName -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    $dfTicket = if ($dfLines.Count -gt 0) { $dfLines[0].Trim() } else { '' }
    if ($dfTicket -ne $ticket) { continue }
    $dfPid    = if ($dfLines.Count -gt 1) { try { [int]$dfLines[1].Trim() } catch { 0 } } else { 0 }
    $dfMarker = "$env:TEMP\claude_ctx_$dfSid.marker"
    $isAlive  = ($dfPid -gt 0 -and ($null -ne (Get-Process -Id $dfPid -EA SilentlyContinue))) -or
                ((Test-Path $dfMarker) -and ((Get-Date) - (Get-Item $dfMarker).LastWriteTime).TotalHours -lt 24)
    if ($isAlive) {
        $conflictWarning = "WARNING: $ticket is already active in another session ($dfSid). Simultaneous edits to CONTEXT.md or session_log.md may cause git conflicts."
    }
}

# Update demand file for this session -- preserve the existing PID (line 2), same format the inject hook writes
Set-Content $demandFile -Value "$ticket`n$existingPid" -Encoding utf8

# Update active_demands.txt: replace old ticket with new ticket
if (Test-Path $activeFile) {
    $lines   = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
    $updated = @($lines | ForEach-Object { if ($_.Trim() -eq $oldTicket) { $ticket } else { $_ } })
    if ($ticket -notin @($updated | ForEach-Object { $_.Trim() })) { $updated = @($updated) + @($ticket) }
    $updated | Set-Content $activeFile -Encoding utf8
} else {
    Set-Content $activeFile -Value $ticket -Encoding utf8
}

Write-Host "Demand switched: $oldTicket -> $ticket" -ForegroundColor Cyan
if ($conflictWarning) { Write-Host $conflictWarning -ForegroundColor Yellow }

# Display new demand context
$contextFile = "$worklogRoot\worklogs\$ticket\CONTEXT.md"
if (Test-Path $contextFile) {
    Get-Content $contextFile -Raw -Encoding utf8
} else {
    Write-Host "CONTEXT.md not found for $ticket." -ForegroundColor Yellow
}
