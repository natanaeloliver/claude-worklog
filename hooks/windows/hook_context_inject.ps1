<#
.SYNOPSIS
    UserPromptSubmit hook -- injects active demand context into the first message of each session.
    Uses session_id (provided by Claude Code via stdin) as the stable session identifier.
    Identical session_id between all hooks in the same session (inject and Stop).
#>

# Read session_id from stdin (JSON sent by Claude Code).
# Do NOT gate on [Console]::In.Peek() -- confirmed via live debugging (2026-07-01) that Peek()
# can return -1 even when Claude Code does send JSON over stdin on this host. Reading directly
# with ReadToEnd() is the only reliable path.
$sessionId = $null
try {
    $stdinContent = [Console]::In.ReadToEnd()
    if ($stdinContent) {
        $hookInput = $stdinContent | ConvertFrom-Json
        $sessionId = $hookInput.session_id
    }
} catch {}

# Worklog root: env var takes precedence, fallback navigates up from hooks/windows/
$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

# No JSONL-based fallback: with multiple sessions sharing the same Claude project directory,
# "most recently modified jsonl" can belong to ANY active session, not just the caller --
# confirmed to cause cross-session state corruption (2026-07-01). Failing safe (skip injection
# for this message) is preferable to silently guessing the wrong identity.
if (-not $sessionId) { exit 0 }

# PID of claude.exe (direct parent of hook) -- stored in demand file for liveness check
$claudePid = try { (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -EA Stop).ParentProcessId } catch { 0 }

# Session files keyed by session_id -- stable and identical in inject and Stop hooks
$sessionMarker = "$env:TEMP\claude_ctx_$sessionId.marker"
$activeFlag    = "$env:TEMP\claude_active_$sessionId.flag"
$demandFile    = "$env:TEMP\claude_demand_$sessionId.txt"

# Update activeFlag on every message -- Stop hook uses it to detect mid-turn vs /exit
New-Item -ItemType File -Path $activeFlag -Force | Out-Null

# Re-injection guard: if marker exists and is less than 24h old, not the first message
if (Test-Path $sessionMarker) {
    $age = (Get-Date) - (Get-Item $sessionMarker).LastWriteTime
    if ($age.TotalHours -lt 24) { exit 0 }
    Remove-Item $sessionMarker -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType File -Path $sessionMarker -Force | Out-Null

$activeFile = "$worklogRoot\active_demands.txt"

# Cross-process lock: confirmed via live debugging (2026-07-01) that multiple Claude sessions
# running this section at the same time cause a real race (not just a flaky read) over
# active_demands.txt and the claude_demand_*/claude_ctx_*/claude_active_* files in %TEMP% --
# live sessions wiping each other's state. "Global\" makes the mutex visible across processes.
$worklogMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$worklogMutexAcquired = $false
try {
    try {
        $worklogMutexAcquired = $worklogMutex.WaitOne(10000)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner terminated without releasing (e.g. exit inside the try) -- we still acquire the lock
        $worklogMutexAcquired = $true
    }

    # Sync worklog before reading
    git -C $worklogRoot pull origin main 2>$null

    # Helper: read ticket and PID from demand file (line1=ticket, line2=claude.exe pid)
    function Read-DemandFile {
        param([string]$path)
        $lines = @(Get-Content $path -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
        @{
            Ticket = if ($lines.Count -gt 0) { $lines[0].Trim() } else { '' }
            Pid    = if ($lines.Count -gt 1) { try { [int]$lines[1].Trim() } catch { 0 } } else { 0 }
        }
    }

    # Helper: session is alive if claude.exe is still running OR marker exists and is recent (<24h).
    # Retry on Test-Path: confirmed via live debugging (2026-07-01) that a single read can fail
    # transiently under heavy concurrent I/O (multiple sessions touching the same %TEMP% files),
    # making Test-SessionAlive conclude "dead" for a live session with a marker minutes old.
    # Only retries when the first read fails (extra cost only on the rare "looks dead" path).
    function Test-SessionAlive {
        param([int]$pid, [string]$markerPath)
        if ($pid -gt 0 -and ($null -ne (Get-Process -Id $pid -EA SilentlyContinue))) { return $true }
        if (Test-Path $markerPath) { return ((Get-Date) - (Get-Item $markerPath).LastWriteTime).TotalHours -lt 24 }
        Start-Sleep -Milliseconds 150
        if (Test-Path $markerPath) { return ((Get-Date) - (Get-Item $markerPath).LastWriteTime).TotalHours -lt 24 }
        return $false
    }

    # Determine active demand for this session
$ticket = $null

# 1. Demand file by session_id (persists across Claude restarts in the same terminal tab)
if (Test-Path $demandFile) {
    $dfOwn = Read-DemandFile $demandFile
    if ($dfOwn.Ticket -and (Test-Path "$worklogRoot\worklogs\$($dfOwn.Ticket)")) {
        $ticket = $dfOwn.Ticket
    }
}

# 2. Fallback: active_demands.txt -- first ticket not claimed by another live session
if (-not $ticket -and (Test-Path $activeFile)) {
    $claimedTickets = @(@(Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue) | ForEach-Object {
        $dfSid = $_.BaseName -replace 'claude_demand_', ''
        if ($dfSid -eq $sessionId) { return }
        $dfData = Read-DemandFile $_.FullName
        if (-not $dfData.Ticket) { return }
        $dfMarker = "$env:TEMP\claude_ctx_$dfSid.marker"
        if (-not (Test-SessionAlive $dfData.Pid $dfMarker)) { return }
        $dfData.Ticket
    } | Where-Object { $_ })

    foreach ($line in @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })) {
        $candidate = $line.Trim()
        if ($candidate -and (Test-Path "$worklogRoot\worklogs\$candidate") -and ($candidate -notin $claimedTickets)) {
            $ticket = $candidate; break
        }
    }
}

# 3. Legacy fallback: current_demand.txt
if (-not $ticket) {
    $legacyFile = "$worklogRoot\current_demand.txt"
    if (Test-Path $legacyFile) {
        $candidate = (Get-Content $legacyFile -Raw -Encoding utf8).Trim()
        if ($candidate -and (Test-Path "$worklogRoot\worklogs\$candidate")) { $ticket = $candidate }
    }
}

if (-not $ticket) { exit 0 }

# Register demand in this session's demand file (ticket + claude.exe PID for liveness check)
Set-Content $demandFile -Value "$ticket`n$claudePid" -Encoding utf8

# Add to active_demands.txt if not already there
$lines = if (Test-Path $activeFile) { @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() }) } else { @() }
if ($ticket -notin ($lines | ForEach-Object { $_.Trim() })) {
    ($lines + $ticket) | Set-Content $activeFile -Encoding utf8
}

# Clean up legacy files from old approach (keyed by numeric PID)
Get-ChildItem "$env:TEMP\claude_*" -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '_\d+$' } |
    Remove-Item -Force -EA SilentlyContinue

# Check for conflict: another live session on the same demand
$conflictWarning = $null
foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue)) {
    $dfSid = $df.BaseName -replace 'claude_demand_', ''
    if ($dfSid -eq $sessionId) { continue }
    $dfData = Read-DemandFile $df.FullName
    if ($dfData.Ticket -ne $ticket) { continue }
    $dfMarker = "$env:TEMP\claude_ctx_$dfSid.marker"
    if (-not (Test-SessionAlive $dfData.Pid $dfMarker)) { continue }
    $conflictWarning = "HOOK WARNING: $ticket is already open in another session ($dfSid). Editing CONTEXT.md or session_log.md simultaneously may cause git conflicts."
    break
}

# Clean up orphan demand files (dead process or expired marker)
foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue)) {
    $dfSid = $df.BaseName -replace 'claude_demand_', ''
    if ($dfSid -eq $sessionId) { continue }
    $dfData = Read-DemandFile $df.FullName
    $dfMarker = "$env:TEMP\claude_ctx_$dfSid.marker"
    if (Test-SessionAlive $dfData.Pid $dfMarker) { continue }
    $orphanTicket = $dfData.Ticket
    Remove-Item $df.FullName -Force -EA SilentlyContinue
    Remove-Item $dfMarker -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\claude_active_$dfSid.flag" -Force -EA SilentlyContinue
    if ($orphanTicket -and (Test-Path $activeFile)) {
        $liveTickets = @(@(Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue) | ForEach-Object {
            (Read-DemandFile $_.FullName).Ticket
        } | Where-Object { $_ })
        if ($orphanTicket -notin $liveTickets) {
            $al = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
            ($al | Where-Object { $_.Trim() -ne $orphanTicket }) | Set-Content $activeFile -Encoding utf8
        }
    }
}

} finally {
    if ($worklogMutexAcquired) { $worklogMutex.ReleaseMutex() }
    $worklogMutex.Dispose()
}

$contextFile = "$worklogRoot\worklogs\$ticket\CONTEXT.md"
if (-not (Test-Path $contextFile)) { exit 0 }

$context = Get-Content $contextFile -Raw -Encoding utf8
$context = [regex]::Replace($context, '[\uD800-\uDFFF]', '')

$additionalContext = "=== ACTIVE DEMAND: $ticket ===" + "`n`n" + $context
if ($conflictWarning) {
    $mandatory = "[MANDATORY INSTRUCTION: Report this warning on the first line of your response, before anything else, regardless of what the user asks.]"
    $additionalContext = ">>> $conflictWarning <<<`n$mandatory`n`n" + $additionalContext
}

$output = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName     = "UserPromptSubmit"
        additionalContext = $additionalContext
    }
} | ConvertTo-Json -Compress -Depth 3

Write-Output $output
