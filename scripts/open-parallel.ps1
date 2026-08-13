<#
.SYNOPSIS
    Opens a parallel demand in a new Windows Terminal window.
    Registers the ticket in active_demands.txt, reserves it for that window, and starts Claude
    automatically.

.PARAMETER ticket
    Demand ID to open in the new session. Example: "PROJ-456"

.EXAMPLE
    .\open-parallel.ps1 -ticket "PROJ-456"
#>
param(
    [Parameter(Mandatory)]
    [string]$ticket
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$activeFile  = "$worklogRoot\active_demands.txt"
. "$PSScriptRoot\active_demands_lib.ps1"   # Get-ActiveDemands / Set-ActiveDemands (self-healing read + atomic write)

# Check for conflict: a live session already has this demand
$conflict = $false
foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -ErrorAction SilentlyContinue)) {
    $dfLines  = @(Get-Content $df.FullName -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    $dfTicket = if ($dfLines.Count -gt 0) { $dfLines[0].Trim() } else { '' }
    if ($dfTicket -ne $ticket) { continue }
    $dfPid    = if ($dfLines.Count -gt 1) { try { [int]$dfLines[1].Trim() } catch { 0 } } else { 0 }
    $dfSid    = $df.BaseName -replace 'claude_demand_', ''
    $dfFlag   = "$env:TEMP\claude_active_$dfSid.flag"
    $isAlive  = ($dfPid -gt 0 -and ($null -ne (Get-Process -Id $dfPid -EA SilentlyContinue))) -or
                ((Test-Path $dfFlag) -and ((Get-Date) - (Get-Item $dfFlag).LastWriteTime).TotalMinutes -lt 30)
    if ($isAlive) { $conflict = $true; break }
}
if ($conflict) {
    Write-Host "WARNING: $ticket is already active in another Claude session." -ForegroundColor Yellow
    exit 1
}

# Register the ticket in active_demands.txt for the new session's inject hook. The append goes at
# the END and the position in the file carries NO meaning -- there is no "slot 1". That vocabulary
# came from the original design, when position WAS the delivery mechanism. Do not insert at the top:
# fallback 3 of the inject hook takes the FIRST unclaimed ticket, so prepending would make a new
# session prefer the most recent reservation over the oldest, inverting the serving order for no
# gain. The write goes under the SAME mutex the hooks use, otherwise a concurrent write from another
# session produces duplicate entries (real bug, 2026-07-14).
#
# RESERVATION BOUND TO THE WINDOW. Delivery is no longer a FIFO queue: an opaque token (GUID) goes
# into the environment of the new window (`WORKLOG_DEMAND_TOKEN`, inherited by that window's process
# tree and by no other) and the ticket sits in a reservation file keyed by that token, consumed ONCE
# by fallback 1.5 of hook_context_inject.ps1.
#
# Why the queue did not work: `claude_pending_open.txt` is GLOBAL and the hook always pops the FIRST
# item, on UserPromptSubmit -- and `/rename` (the initial prompt) does NOT fire UserPromptSubmit, so
# the pop waits for the human to type. What pairs ticket with window becomes the order of TYPING,
# not the order of opening; and since `wt -w new` brings the new window to the front, the first
# thing typed goes into the LAST window opened, which consumes the FIRST reservation. With two opens
# back-to-back the swap is systematic, not bad luck. The demand file cannot be used instead: the
# session_id only exists after claude has started, hence the token.
#
# The ticket itself does NOT go into the environment: if it did, a second `claude` in the same window
# (after /exit) would silently reopen the old demand. Token plus single-use file solves it -- the
# second time around the file is gone and the session falls through to the normal fallbacks.
$reservationToken = [guid]::NewGuid().ToString()
$reservationFile  = "$env:TEMP\claude_reserva_$reservationToken.txt"
$mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$mutexAcquired = $false
try {
    try { $mutexAcquired = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }

    $lines = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
    Set-ActiveDemands -Path $activeFile -Tickets (@($lines | Where-Object { $_.Trim() -ne $ticket }) + @($ticket))

    # UTF8Encoding($false) = no BOM: `Set-Content -Encoding utf8` on PS 5.1 writes one on creation.
    [System.IO.File]::WriteAllText($reservationFile, $ticket, (New-Object System.Text.UTF8Encoding $false))
} finally {
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host "$ticket registered in active_demands.txt and reserved for the new window (token $($reservationToken.Substring(0,8)))." -ForegroundColor Cyan

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
    Write-Host "Windows Terminal (wt) not found. Open a new window yourself and run:" -ForegroundColor Red
    Write-Host "  cd `"$worklogRoot`"; claude" -ForegroundColor Yellow
    exit 1
}

# Claude Code injects runtime markers into its subprocesses' environment (NO_COLOR, AI_AGENT,
# CLAUDECODE, CLAUDE_CODE_*, ...). Since this script runs INSIDE a Claude session, wt propagates
# them to the new window and the child Claude reads them as a nested/agent session: colors are
# disabled (washed-out white logo) and interactive mode is degraded (no plan/auto mode). Clearing
# them here makes the parallel window start like a terminal opened by hand.
# CLAUDE_CONFIG_DIR is preserved on purpose (it does not match the CLAUDE_CODE_* glob): it is
# configuration, not a runtime marker, so wiping it would silently switch profiles.
# The exact marker set varies by context -- NO_COLOR is not always present -- so clear the list
# unconditionally rather than probing.
$env:NO_COLOR            = $null
$env:AI_AGENT            = $null
$env:CLAUDECODE          = $null
$env:CLAUDE_PID          = $null
$env:GIT_EDITOR          = $null
$env:GIT_TERMINAL_PROMPT = $null
foreach ($e in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' })) {
    Remove-Item "Env:$($e.Name)" -ErrorAction SilentlyContinue
}

# The reservation token travels with `wt` through the very mechanism that made the markers above
# leak into the new window: wt propagates the caller's environment. Here the propagation is the
# feature, not the defect -- it is the only channel that tells ONE new window apart from the others
# before a session_id exists. Set AFTER the cleanup above so it is not wiped by it.
$env:WORKLOG_DEMAND_TOKEN = $reservationToken

# --startingDirectory sets CWD without needing Set-Location
# -Command claude starts Claude directly (same as typing 'claude' in the terminal)
# Always a new window: `wt new-tab` only attaches to a window wt can identify as the caller's
# own, which isn't reliably available in this context -- it silently fell back to opening a new
# window anyway, so there was never really a tab option in practice.
& wt -w new --startingDirectory $worklogRoot powershell.exe -NoLogo -NoExit -Command claude
