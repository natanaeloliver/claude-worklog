<#
.SYNOPSIS
    Global Claude Code hook -- cleans up session state (demand file, markers, heartbeat) and
    removes the demand from active_demands.txt when the session truly ends.
    Fires ONCE per session, on the SessionEnd event (not Stop, which fires every turn) -- so it
    needs no file heuristic to distinguish mid-turn from exit (that was the role of the old
    activeFlag-presence check in the Stop hook, removed once this hook took over cleanup).
    No "matcher" in settings.json -- fires for any reason (clear, resume, logout,
    prompt_input_exit, bypass_permissions_disabled, other). Confirmed empirically via a temporary
    debug log (2026-07-14) that interactive /exit uses reason "prompt_input_exit" -- Anthropic's
    docs described that value as non-interactive-only.
    The "SessionEnd hook ... failed: Hook cancelled" message the CLI sometimes shows after /exit
    does NOT indicate a real failure: confirmed (same debug log) that the hook finishes and
    completes cleanup before that message appears -- it's a reporting artifact of the CLI tearing
    down the process, with no effect on the result (SessionEnd has no decision control, exit code
    ignored by the harness). Known Anthropic issues tracking this:
      - https://github.com/anthropics/claude-code/issues/63495 (closed) -- same exact symptom
        (fast hook, exit 0, "cancelled" anyway -- "pure display artifact")
      - https://github.com/anthropics/claude-code/issues/70465 (open, Windows env like ours) --
        explains the cause: "SessionEnd hooks are hard-killed on exit with no configurable grace
        and no awaited teardown"
    Called by the SessionEnd event configured in .claude/settings.json
#>

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

# Read session_id from stdin (JSON sent by Claude Code) -- same pattern as the other hooks.
$sessionId = $null
try {
    $stdinContent = [Console]::In.ReadToEnd()
    if ($stdinContent) {
        $hookInput = $stdinContent | ConvertFrom-Json
        $sessionId = $hookInput.session_id
    }
} catch {}

if (-not $sessionId) { exit 0 }

# Session files keyed by session_id -- stable and identical to the other hooks
$demandFile    = "$env:TEMP\claude_demand_$sessionId.txt"
$activeFlag    = "$env:TEMP\claude_active_$sessionId.flag"
$sessionMarker = "$env:TEMP\claude_ctx_$sessionId.marker"

# Ticket: demand file by session_id (written by the inject hook)
$ticket = $null
if (Test-Path $demandFile) {
    $lines = @(Get-Content $demandFile -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    if ($lines.Count -gt 0) { $ticket = $lines[0].Trim() }
}

$activeFile = "$worklogRoot\active_demands.txt"
$lastFile   = "$worklogRoot\last_demand.txt"
. "$worklogRoot\scripts\active_demands_lib.ps1"   # Get-ActiveDemands / Set-ActiveDemands (self-healing read + atomic write)

# Same lock used by hook_context_inject.ps1 -- protects active_demands.txt and the
# claude_demand_*/claude_ctx_*/claude_active_* files against races between concurrent sessions
# (confirmed to cause real state corruption/loss, live debugging 2026-07-01).
$worklogMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$worklogMutexAcquired = $false
try {
    try {
        $worklogMutexAcquired = $worklogMutex.WaitOne(10000)
    } catch [System.Threading.AbandonedMutexException] {
        $worklogMutexAcquired = $true
    }

    if ((Test-Path $activeFile) -and $ticket) {
        # Only remove the ticket from active_demands.txt if NO other session still claims it --
        # the same demand can be open in two parallel sessions, and one of them exiting must not
        # remove the ticket while the other is still working on it.
        $otherClaims = @(Get-ChildItem "$env:TEMP\claude_demand_*.txt" -EA SilentlyContinue |
            Where-Object { ($_.BaseName -replace 'claude_demand_', '') -ne $sessionId } |
            ForEach-Object {
                $l = @(Get-Content $_.FullName -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
                if ($l.Count -gt 0) { $l[0].Trim() }
            })
        if ($ticket -notin $otherClaims) {
            $lines = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
            Set-ActiveDemands -Path $activeFile -Tickets @($lines | Where-Object { $_.Trim() -ne $ticket })
        }
    }

    # RESUME POINT: record the ticket in last_demand.txt.
    # active_demands.txt is ephemeral by design ("who has a live session right now") and was just
    # cleared above -- without this record, ending the last session of the day erased every trace of
    # the demand and the next morning opened in stand-by (real bug, 2026-07-28).
    # This is NOT the old current_demand.txt: that one was "the" demand of the single-session model,
    # read by the Stop hook too, which allowed work to be attributed to the wrong demand.
    # last_demand.txt has ONE meaning -- where to resume from when nothing more specific exists --
    # and a single consumer (fallback 4 of hook_context_inject.ps1).
    # Explicit stand-by wins: standby.ps1 clears this file, and a stand-by session has no demand
    # file, so $ticket is null here and nothing is written.
    if ($ticket) {
        Set-Content $lastFile -Value $ticket -Encoding utf8
    }

    Remove-Item $sessionMarker -Force -EA SilentlyContinue
    Remove-Item $demandFile    -Force -EA SilentlyContinue
    Remove-Item $activeFlag    -Force -EA SilentlyContinue
} finally {
    if ($worklogMutexAcquired) { $worklogMutex.ReleaseMutex() }
    $worklogMutex.Dispose()
}
