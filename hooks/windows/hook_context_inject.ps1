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

# activeFlag = continuous heartbeat (touched on every message, never removed by the Stop hook --
# which fires every turn but only logs+syncs, without touching session state, since 2026-07-14).
# Used by Test-SessionAlive (here, switch-demand.ps1, open-parallel.ps1) to know whether ANOTHER
# session is alive. Real state cleanup (demand file, sessionMarker, activeFlag, active_demands.txt)
# happens exactly once, at the true /exit, in hook_session_end.ps1 (SessionEnd event) -- see
# settings.json.
New-Item -ItemType File -Path $activeFlag -Force | Out-Null

# Re-injection guard: a marker less than 24h old means this is NOT the first message, so there is
# no context to inject. The guard used to `exit 0` right here, and the state CLEANUP left with it,
# because the cleanup lived at the END of the hook: in a long session nothing was ever cleaned, and
# if nobody opened a new session the orphan entry stayed in active_demands.txt indefinitely.
# Now the guard only DECIDES ($reinject); the cleanup runs either way, with a grace period.
$reinject = $true
if (Test-Path $sessionMarker) {
    $age = (Get-Date) - (Get-Item $sessionMarker).LastWriteTime
    if ($age.TotalHours -lt 24) { $reinject = $false }
    else { Remove-Item $sessionMarker -Force -ErrorAction SilentlyContinue }
}

$activeFile = "$worklogRoot\active_demands.txt"
. "$worklogRoot\scripts\active_demands_lib.ps1"   # Get-ActiveDemands / Set-ActiveDemands (self-healing read + atomic write)

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

    # Sync worklog before reading. --rebase --autostash instead of a plain `git pull`: without them
    # a pull with a dirty tree either fails or creates a merge commit, and the session starts out of
    # sync. On conflict, ABORT the rebase -- never leave a rebase stuck, which breaks every
    # subsequent hook in the session. Non-fatal throughout: a failed sync must not block the session.
    # Only on the first message: the Stop hook already pulls+pushes every turn, so pulling again
    # here would duplicate work under the same mutex. Hence the $reinject guard -- without it the
    # pull would start running on every turn, as a side effect of the cleanup moving up.
    if ($reinject) {
        git -C $worklogRoot pull --rebase --autostash origin main 2>$null
        if ($LASTEXITCODE -ne 0) { git -C $worklogRoot rebase --abort 2>$null }
    }

    # Helper: read ticket and PID from demand file (line1=ticket, line2=claude.exe pid)
    function Read-DemandFile {
        param([string]$path)
        $lines = @(Get-Content $path -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
        @{
            Ticket = if ($lines.Count -gt 0) { $lines[0].Trim() } else { '' }
            Pid    = if ($lines.Count -gt 1) { try { [int]$lines[1].Trim() } catch { 0 } } else { 0 }
        }
    }

    # Helper: session is alive if claude.exe is still running OR activeFlag exists and is recent
    # (<30min). Uses activeFlag, not sessionMarker: the marker is a once-per-24h re-injection
    # guard, not a liveness signal, so a session dead for hours (crashed/closed without /exit)
    # was being reported as alive for up to 24h -- real bug, caused ghost sessions blocking
    # tickets and a duplicate entry in active_demands.txt during rapid open/close cycles
    # (found 2026-07-13). activeFlag is a continuous heartbeat: touched on every message by this
    # hook and NEVER removed by the Stop hook (which only logs+syncs since 2026-07-14) -- it is
    # only removed at the true /exit, by hook_session_end.ps1 (SessionEnd event), so its age
    # reflects actual last activity.
    # Retry on Test-Path: confirmed via live debugging (2026-07-01) that a single read can fail
    # transiently under heavy concurrent I/O (multiple sessions touching the same %TEMP% files),
    # making Test-SessionAlive conclude "dead" for a live session with a flag minutes old.
    # Only retries when the first read fails (extra cost only on the rare "looks dead" path).
    function Test-SessionAlive {
        param([int]$targetPid, [string]$flagPath)
        if ($targetPid -gt 0 -and ($null -ne (Get-Process -Id $targetPid -EA SilentlyContinue))) { return $true }
        if (Test-Path $flagPath) { return ((Get-Date) - (Get-Item $flagPath).LastWriteTime).TotalMinutes -lt 30 }
        Start-Sleep -Milliseconds 150
        if (Test-Path $flagPath) { return ((Get-Date) - (Get-Item $flagPath).LastWriteTime).TotalMinutes -lt 30 }
        return $false
    }

# Helper: tickets reserved for a window that has NOT sent its first message yet -- token
# reservations (claude_reserva_<token>.txt, current) plus the FIFO queue (legacy). They have no
# demand file yet, so they must not be pruned from active_demands.txt NOR handed to another session
# by fallbacks 3 and 4. Read at two different moments (cleanup and fallback 3), hence a function:
# the state changes in between, because fallback 1.5 consumes THIS window's reservation.
function Get-ReservedTickets {
    param([string]$pendingPath)
    @(
        @(Get-Item "$env:TEMP\claude_reserva_*.txt" -EA SilentlyContinue | ForEach-Object {
            (Get-Content $_.FullName -Raw -Encoding utf8 -EA SilentlyContinue)
        }) +
        @(Get-Content $pendingPath -Encoding utf8 -EA SilentlyContinue)
    ) | ForEach-Object { if ($_) { $_.Trim() } } | Where-Object { $_ }
}

$pendingFile = "$env:TEMP\claude_pending_open.txt"

# ===========================================================================================
# STATE CLEANUP -- BEFORE demand resolution, and not gated on this being a new session.
#
# Until 2026-08-12 these blocks lived at the END of the hook, after the demand had already been
# resolved and written. The effect: fallback 3 walked active_demands.txt BEFORE the prune, so a
# residual entry left by a session that died without SessionEnd (the norm, not the exception --
# anthropics/claude-code#70465) was still HANDED to the new session; and once handed, the session
# had a demand file with that ticket, which made the prune at the end of the SAME hook consider the
# entry legitimate and keep it. The cleanup fixed the file for the sessions that came after, and
# never for the one that inherited the residue.
#
# It also ran after the re-injection guard, so only on the first message of a session. Extracted
# into a function to run in both regimes: ALWAYS on the first message, and every
# $cleanupGraceMinutes on later turns. The grace period exists because this runs under the global
# mutex, and work under the lock is what serializes every parallel session on this machine.
# ===========================================================================================
function Invoke-StateCleanup {
    # Orphan demand files (dead process or expired heartbeat)
    foreach ($df in (Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue)) {
        $dfSid = $df.BaseName -replace 'claude_demand_', ''
        if ($dfSid -eq $sessionId) { continue }
        $dfData = Read-DemandFile $df.FullName
        $dfFlag = "$env:TEMP\claude_active_$dfSid.flag"
        if (Test-SessionAlive $dfData.Pid $dfFlag) { continue }
        $orphanTicket = $dfData.Ticket
        Remove-Item $df.FullName -Force -EA SilentlyContinue
        Remove-Item "$env:TEMP\claude_ctx_$dfSid.marker" -Force -EA SilentlyContinue
        Remove-Item $dfFlag -Force -EA SilentlyContinue
        if ($orphanTicket -and (Test-Path $activeFile)) {
            $liveTickets = @(@(Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue) | ForEach-Object {
                (Read-DemandFile $_.FullName).Ticket
            } | Where-Object { $_ })
            if ($orphanTicket -notin $liveTickets) {
                $al = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
                Set-ActiveDemands -Path $activeFile -Tickets @($al | Where-Object { $_.Trim() -ne $orphanTicket })
            }
        }
    }

    # TTL on reservations. A reservation for a window that never sent its first message (the user
    # closed it, or `wt` failed) would otherwise live forever, and with it the matching entry in
    # active_demands.txt, because the prune below preserves whatever is reserved. 24h is the same
    # horizon as the re-injection guard.
    foreach ($rv in (Get-Item "$env:TEMP\claude_reserva_*.txt" -EA SilentlyContinue)) {
        if (((Get-Date) - $rv.LastWriteTime).TotalHours -ge 24) { Remove-Item $rv.FullName -Force -EA SilentlyContinue }
    }

    # Prune active_demands.txt entries with NO demand file at all -- residue from a session that died
    # without SessionEnd. The orphan cleanup above iterates claude_demand_*.txt, so it only reaches
    # sessions that still have a demand file; an entry with no file was invisible to it, stayed in
    # active_demands.txt forever, and fallback 3 then handed the wrong demand to every new session.
    $liveTickets = @(@(Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue) | ForEach-Object {
        (Read-DemandFile $_.FullName).Ticket
    } | Where-Object { $_ })
    $reserved = Get-ReservedTickets $pendingFile
    $current  = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
    $kept     = @($current | Where-Object { $_.Trim() -in $liveTickets -or $_.Trim() -in $reserved })
    if ($kept.Count -ne $current.Count) {
        Set-ActiveDemands -Path $activeFile -Tickets $kept
    }
}

$cleanupStamp = "$env:TEMP\claude_cleanup.stamp"
$cleanupGraceMinutes = 5
$runCleanup = $reinject -or -not (Test-Path $cleanupStamp) -or
              (((Get-Date) - (Get-Item $cleanupStamp).LastWriteTime).TotalMinutes -ge $cleanupGraceMinutes)
if ($runCleanup) {
    Invoke-StateCleanup
    Set-Content $cleanupStamp -Value (Get-Date -Format 'o') -Encoding utf8
}

# Context already injected in this session (fresh marker): the cleanup above was all there was to do.
# The early exit sits HERE, and no longer at the guard, because the cleanup has to run first.
# `return` at script scope unwinds through the `finally` (releasing the mutex) and skips everything
# after the try, which is the injection -- exactly what is wanted on a later turn.
if (-not $reinject) { return }

New-Item -ItemType File -Path $sessionMarker -Force | Out-Null

# Determine active demand for this session
$ticket = $null

# 1. Demand file by session_id (persists across Claude restarts in the same terminal tab)
if (Test-Path $demandFile) {
    $dfOwn = Read-DemandFile $demandFile
    if ($dfOwn.Ticket -and (Test-Path "$worklogRoot\worklogs\$($dfOwn.Ticket)")) {
        $ticket = $dfOwn.Ticket
    }
}

# 1.5 RESERVATION BOUND TO THIS WINDOW -- wins over the legacy FIFO queue.
#     `open-parallel.ps1` generates a token (GUID), writes the ticket to claude_reserva_<token>.txt
#     and exports the token in WORKLOG_DEMAND_TOKEN, which `wt` propagates ONLY to the process tree
#     of the new window. So the reservation reaches the window it was made for, no matter who types
#     first -- which is exactly where the queue failed (see fallback 2).
#     Consumed ONCE: the file is deleted here. That way a second `claude` in the same window (after
#     /exit) does not silently reopen the old demand, it falls through to the normal fallbacks.
if (-not $ticket -and $env:WORKLOG_DEMAND_TOKEN) {
    $reservationFile = "$env:TEMP\claude_reserva_$($env:WORKLOG_DEMAND_TOKEN).txt"
    if (Test-Path $reservationFile) {
        $candidate = (Get-Content $reservationFile -Raw -Encoding utf8 -EA SilentlyContinue)
        if ($candidate) { $candidate = $candidate.Trim() }
        Remove-Item $reservationFile -Force -EA SilentlyContinue
        if ($candidate -and (Test-Path "$worklogRoot\worklogs\$candidate")) { $ticket = $candidate }
    }
}

# 2. LEGACY fallback: the FIFO reservation queue (`claude_pending_open.txt`). It was the delivery
#    mechanism until 2026-08-12 and survives only to serve a queue still in flight from an older
#    open-parallel.ps1 -- nothing writes to it any more.
#    Why it was retired: the queue is GLOBAL and the pop always takes the FIRST item, on
#    UserPromptSubmit -- and `/rename` (the initial prompt that names the tab) does NOT fire
#    UserPromptSubmit, so the pop waits for the human to type. What pairs ticket with window becomes
#    the order of TYPING, not the order of opening; and since `wt -w new` brings the new window to
#    the front, the first thing typed goes into the LAST window opened, which consumes the FIRST
#    reservation. With two opens back-to-back the swap is systematic, not bad luck.
if (-not $ticket -and (Test-Path $pendingFile)) {
    $pendingLines = @(Get-Content $pendingFile -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    if ($pendingLines.Count -gt 0) {
        $candidate = $pendingLines[0].Trim()
        $remaining = @($pendingLines | Select-Object -Skip 1)
        if ($remaining.Count -gt 0) { $remaining | Set-Content $pendingFile -Encoding utf8 } else { Remove-Item $pendingFile -Force -EA SilentlyContinue }
        if ($candidate -and (Test-Path "$worklogRoot\worklogs\$candidate")) { $ticket = $candidate }
    }
}

# Tickets unavailable to fallbacks 3 and 4. Two sources:
#  (a) claimed by ANOTHER live session (has a demand file and passes the liveness check);
#  (b) RESERVED for a window that has not typed yet -- recomputed here, after fallback 1.5 consumed
#      THIS window's reservation, so what is left belongs to some other window.
# Without (b), a `claude` opened by hand (no reservation, so it falls to fallback 3) could walk off
# with the ticket reserved for an open-parallel window that had not typed yet, and both sessions
# would end up on the same demand. The prune above already preserved the reservation inside
# active_demands.txt; what was missing was refusing to DELIVER it to someone who does not own it.
$claimedTickets = @(@(Get-Item "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue) | ForEach-Object {
    $dfSid = $_.BaseName -replace 'claude_demand_', ''
    if ($dfSid -eq $sessionId) { return }
    $dfData = Read-DemandFile $_.FullName
    if (-not $dfData.Ticket) { return }
    $dfFlag = "$env:TEMP\claude_active_$dfSid.flag"
    if (-not (Test-SessionAlive $dfData.Pid $dfFlag)) { return }
    $dfData.Ticket
} | Where-Object { $_ })
$claimedTickets = @($claimedTickets + (Get-ReservedTickets $pendingFile)) | Where-Object { $_ } | Select-Object -Unique

# 3. Fallback: active_demands.txt -- first ticket not claimed by another live session
if (-not $ticket -and (Test-Path $activeFile)) {
    foreach ($line in (Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs")) {
        $candidate = $line.Trim()
        if ($candidate -and (Test-Path "$worklogRoot\worklogs\$candidate") -and ($candidate -notin $claimedTickets)) {
            $ticket = $candidate; break
        }
    }
}

# 4. Final fallback: last_demand.txt -- THE RESUME POINT.
# Written by hook_session_end.ps1 (last session to end) and by new-demand.ps1 (freshly created
# demand); cleared by standby.ps1. It exists because active_demands.txt is ephemeral by design:
# without this file, ending the last session of the day erased every trace of the demand and the
# next morning opened in stand-by (real bug, 2026-07-28).
# It replaces the old current_demand.txt fallback, a leftover of the single-session model that
# survived the migration to parallel sessions as a compatibility bridge and was never retired: no
# actor in the multi-session model wrote to it, only new-demand and standby, so it sat frozen on
# some old demand while being trusted as "the" demand.
# Claim guard: if the last demand is already open in another live session, do NOT reopen it here --
# this fallback exists to recover lost context, not to duplicate a demand already being worked on
# (which would only trigger the conflict warning below).
if (-not $ticket) {
    $lastFile = "$worklogRoot\last_demand.txt"
    if (Test-Path $lastFile) {
        $candidate = Get-Content $lastFile -Raw -Encoding utf8 -EA SilentlyContinue
        if ($candidate) { $candidate = $candidate.Trim() }
        if ($candidate -and ($candidate -notin $claimedTickets) -and (Test-Path "$worklogRoot\worklogs\$candidate")) {
            $ticket = $candidate
        }
    }
}

# Stand-by: no fallback resolved. Leaves through the `finally`, like the guard above.
if (-not $ticket) { return }

# Register demand in this session's demand file (ticket + claude.exe PID for liveness check)
Set-Content $demandFile -Value "$ticket`n$claudePid" -Encoding utf8

# Add to active_demands.txt if not already there
$lines = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
if ($ticket -notin ($lines | ForEach-Object { $_.Trim() })) {
    Set-ActiveDemands -Path $activeFile -Tickets ($lines + $ticket)
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
    $dfFlag = "$env:TEMP\claude_active_$dfSid.flag"
    if (-not (Test-SessionAlive $dfData.Pid $dfFlag)) { continue }
    $conflictWarning = "HOOK WARNING: $ticket is already open in another session ($dfSid). Editing CONTEXT.md or session_log.md simultaneously may cause git conflicts."
    break
}

# The orphan cleanup, the reservation TTL and the active_demands.txt prune used to live HERE, and
# that was the defect: running after resolution, they fixed the file for the next sessions and never
# for the one that had just inherited the residue. Moved above, see the "STATE CLEANUP" block.
# Nothing runs after resolution on purpose: the hook ends by writing the additionalContext.

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
