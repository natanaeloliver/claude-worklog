<#
.SYNOPSIS
    Opens a parallel demand in a new Windows Terminal tab or window.
    Reserves the slot in active_demands.txt and starts Claude automatically.

.PARAMETER ticket
    Demand ID to open in the new session. Example: "PROJ-456"

.PARAMETER option
    "1" = new tab (default), "2" = new window

.EXAMPLE
    .\open-parallel.ps1 -ticket "PROJ-456"
    .\open-parallel.ps1 -ticket "PROJ-456" -option 2
#>
param(
    [Parameter(Mandatory)]
    [string]$ticket,
    [ValidateSet("1","2")]
    [string]$option
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
    $dfMarker = "$env:TEMP\claude_ctx_$dfSid.marker"
    $isAlive  = ($dfPid -gt 0 -and ($null -ne (Get-Process -Id $dfPid -EA SilentlyContinue))) -or
                ((Test-Path $dfMarker) -and ((Get-Date) - (Get-Item $dfMarker).LastWriteTime).TotalHours -lt 24)
    if ($isAlive) { $conflict = $true; break }
}
if ($conflict) {
    Write-Host "WARNING: $ticket is already active in another Claude session." -ForegroundColor Yellow
    exit 1
}

# Reserve slot in active_demands.txt for the new session's inject hook
if (Test-Path $activeFile) {
    $lines = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
    (@($lines | Where-Object { $_.Trim() -ne $ticket }) + @($ticket)) | Set-Content $activeFile -Encoding utf8
} else {
    Set-Content $activeFile -Value $ticket -Encoding utf8
}

# FIFO queue consumed by hook_context_inject.ps1 in the new session before it falls back to
# scanning active_demands.txt -- without this, opening two parallels back-to-back could make the
# second new session grab an old/orphaned ticket already sitting in the file instead of its own
# reservation (real bug, worklog TSK-596, 2026-07-03). Same global mutex the hooks use protects
# the append against a race with a concurrent read.
$pendingFile = "$env:TEMP\claude_pending_open.txt"
$mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$mutexAcquired = $false
try {
    try { $mutexAcquired = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    Add-Content $pendingFile -Value $ticket -Encoding utf8
} finally {
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host "Slot reserved for $ticket." -ForegroundColor Cyan

if (-not $option) {
    $option = Read-Host "Open in (1) new tab or (2) new window? [1/2]"
}

# --startingDirectory sets CWD without needing Set-Location
# -Command claude starts Claude directly (same as typing 'claude' in the terminal)
if ($option -eq "2") {
    & wt -w new --startingDirectory $worklogRoot powershell.exe -NoLogo -NoExit -Command claude
} else {
    & wt new-tab --startingDirectory $worklogRoot powershell.exe -NoLogo -NoExit -Command claude
}
