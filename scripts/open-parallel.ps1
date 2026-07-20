<#
.SYNOPSIS
    Opens a parallel demand in a new Windows Terminal window.
    Reserves the slot in active_demands.txt and starts Claude automatically.

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

# Reserve the slot in active_demands.txt for the new session's inject hook, and enqueue in the
# FIFO queue consumed by hook_context_inject.ps1 in the new session before it falls back to
# scanning active_demands.txt -- without this, opening two parallels back-to-back could make the
# second new session grab an old/orphaned ticket already sitting in the file instead of its own
# reservation (real bug, worklog TSK-596, 2026-07-03). Both writes now go under the SAME mutex the
# hooks use -- before, only the FIFO append had this protection; the active_demands.txt write was
# exposed to a race with a concurrent write from another session, causing duplicate entries (real
# bug: TSK-2276 duplicated, worklog TSK-596, 2026-07-14). Select-Object -Unique added as a second
# layer of defense.
$pendingFile = "$env:TEMP\claude_pending_open.txt"
$mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$mutexAcquired = $false
try {
    try { $mutexAcquired = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }

    if (Test-Path $activeFile) {
        $lines = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
        (@($lines | Where-Object { $_.Trim() -ne $ticket }) + @($ticket) | Select-Object -Unique) | Set-Content $activeFile -Encoding utf8
    } else {
        Set-Content $activeFile -Value $ticket -Encoding utf8
    }

    Add-Content $pendingFile -Value $ticket -Encoding utf8
} finally {
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host "Slot reserved for $ticket." -ForegroundColor Cyan

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

# --startingDirectory sets CWD without needing Set-Location
# -Command claude starts Claude directly (same as typing 'claude' in the terminal)
# Always a new window: `wt new-tab` only attaches to a window wt can identify as the caller's
# own, which isn't reliably available in this context -- it silently fell back to opening a new
# window anyway, so there was never really a tab option in practice.
& wt -w new --startingDirectory $worklogRoot powershell.exe -NoLogo -NoExit -Command claude
