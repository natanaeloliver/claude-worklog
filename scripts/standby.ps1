<#
.SYNOPSIS
    Puts Claude Code in stand-by mode (no active demand) for the current session.
    No demand context will be injected in the next messages of this session, or in future sessions.
    To resume: switch to a demand, or create one with new-demand.ps1.

.PARAMETER sessionId
    session_id of the calling session. Claude SHOULD ALWAYS pass this, extracted from the UUID of
    its own scratchpad directory (given in its system prompt, identical to the session_id used by
    the hooks) -- same convention as switch-demand.ps1. Without it, the script falls back to a
    fragile heuristic (most recently touched claude_active_*.flag) that can match a DIFFERENT
    concurrent session on the same machine.

.EXAMPLE
    .\standby.ps1 -sessionId "da9bd39f-cf6f-46e1-bd7b-dcad64db689f"
#>
param(
    [string]$sessionId
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }

# Until 2026-07-14 this script located the session by walking the ancestor process tree and matching
# the PID stored on line 2 of the demand file. That PID is captured by hook_context_inject.ps1 as the
# parent of the hook's own powershell process, not as claude.exe -- confirmed live that it never
# matches a genuinely running process (it is either 0 or points at an already-dead transient
# wrapper), so the walk never matched and stand-by reported success without cleaning anything.
# Replaced by the same convention as switch-demand.ps1: explicit -sessionId, with the flag fallback.
if (-not $sessionId) {
    $activeFlags = @(Get-Item "$env:TEMP\claude_active_*.flag" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($activeFlags.Count -gt 0) { $sessionId = $activeFlags[0].BaseName -replace 'claude_active_', '' }
}

if (-not $sessionId) {
    Write-Host "ERROR: could not determine session_id for the current session." -ForegroundColor Red
    exit 1
}

$demandFile = "$env:TEMP\claude_demand_$sessionId.txt"

$previous = $null
if (Test-Path $demandFile) {
    $dfLines = @(Get-Content $demandFile -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    if ($dfLines.Count -gt 0) { $previous = $dfLines[0].Trim() }

    # Remove from active_demands.txt -- same global mutex used by the hooks and the other scripts,
    # protecting against a race with a concurrent write from another session.
    $activeFile = "$worklogRoot\active_demands.txt"
    . "$PSScriptRoot\active_demands_lib.ps1"   # Get-ActiveDemands / Set-ActiveDemands (self-healing read + atomic write)
    $worklogMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
    $worklogMutexAcquired = $false
    try {
        try {
            $worklogMutexAcquired = $worklogMutex.WaitOne(10000)
        } catch [System.Threading.AbandonedMutexException] {
            $worklogMutexAcquired = $true
        }
        if ((Test-Path $activeFile) -and $previous) {
            $lines = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
            Set-ActiveDemands -Path $activeFile -Tickets @($lines | Where-Object { $_.Trim() -ne $previous })
        }
    } finally {
        if ($worklogMutexAcquired) { $worklogMutex.ReleaseMutex() }
        $worklogMutex.Dispose()
    }

    Remove-Item $demandFile -Force -ErrorAction SilentlyContinue
}

# Explicit stand-by beats the resume point: clearing last_demand.txt stops fallback 4 of
# hook_context_inject.ps1 from reopening the demand in the next session. Without this, "going into
# stand-by" would not survive the end of the session.
Set-Content -Path "$worklogRoot\last_demand.txt" -Value "" -Encoding utf8

if ($previous) {
    Write-Host "Stand-by activated (was: $previous)." -ForegroundColor Cyan
} else {
    Write-Host "Stand-by activated." -ForegroundColor Cyan
}
Write-Host "To resume: use 'switch demand' in Claude or open a new window." -ForegroundColor Gray
