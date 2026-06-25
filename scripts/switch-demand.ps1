<#
.SYNOPSIS
    Switches the active demand in the current Claude session without restarting Claude.
    Locates the session_id from the most recent JSONL in the Claude project directory.

.PARAMETER ticket
    Target demand ID. Example: "PROJ-456"

.EXAMPLE
    .\switch-demand.ps1 -ticket "PROJ-456"
#>
param(
    [Parameter(Mandatory)]
    [string]$ticket
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$activeFile  = "$worklogRoot\active_demands.txt"

# Locate session_id by walking the process tree to find the claude.exe PID
# stored by the inject hook in the demand file (line 2)
$sessionId = $null
$checkPid  = $PID
for ($hop = 0; $hop -lt 6 -and -not $sessionId; $hop++) {
    $checkPid = try { (Get-CimInstance Win32_Process -Filter "ProcessId=$checkPid" -EA Stop).ParentProcessId } catch { 0 }
    if (-not $checkPid) { break }
    foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue)) {
        $dfLines = @(Get-Content $df.FullName -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
        $dfPid   = if ($dfLines.Count -gt 1) { try { [int]$dfLines[1].Trim() } catch { 0 } } else { 0 }
        if ($dfPid -gt 0 -and $dfPid -eq $checkPid) {
            $sessionId = $df.BaseName -replace 'claude_demand_', ''
            break
        }
    }
}

# Fallback: most recent JSONL (less reliable with parallel sessions)
if (-not $sessionId) {
    $worklogDirName = Split-Path $worklogRoot -Leaf
    $claudeProjectDir = (Get-ChildItem "$env:USERPROFILE\.claude\projects\" -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -like "*$worklogDirName*" } | Select-Object -First 1).FullName
    if ($claudeProjectDir) {
        $latestJsonl = Get-ChildItem "$claudeProjectDir\*.jsonl" -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestJsonl) { $sessionId = $latestJsonl.BaseName }
    }
}

if (-not $sessionId) {
    Write-Host "ERROR: could not determine session_id for the current session." -ForegroundColor Red
    exit 1
}
$demandFile = "$env:TEMP\claude_demand_$sessionId.txt"

# Read current ticket
$oldTicket = $null
if (Test-Path $demandFile) {
    $oldTicket = @(Get-Content $demandFile -Encoding utf8 | Where-Object { $_.Trim() })[0]
    if ($oldTicket) { $oldTicket = $oldTicket.Trim() }
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

# Update demand file for this session
Set-Content $demandFile -Value $ticket -Encoding utf8

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
