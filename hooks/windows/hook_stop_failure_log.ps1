<#
.SYNOPSIS
    StopFailure hook -- records API errors (529 overloaded, 429 rate_limit, ...) in a structured
    per-session log. Purely observational: StopFailure ignores a hook's output and exit code, so
    this can never influence the turn, only measure it.

    It is a MEASUREMENT phase, not a mitigation: the point is to decide, from real numbers, whether
    an action layer (retry/backoff/notify) is worth building at all. scripts/stopfailure-report.ps1
    is the reader that closes that loop -- a log with no consumer decides nothing.

    Not wired up by default. Add it to .claude/settings.json (or your personal settings) when you
    want the measurement:
      "StopFailure": [ { "hooks": [ { "type": "command",
        "command": "powershell -NonInteractive -File hooks/windows/hook_stop_failure_log.ps1" } ] } ]
#>

$stdinContent = $null
try { $stdinContent = [Console]::In.ReadToEnd() } catch {}
if (-not $stdinContent) { exit 0 }

$hookInput = $null
try { $hookInput = $stdinContent | ConvertFrom-Json } catch { exit 0 }

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
$logDir  = "$worklogRoot\logs"
$logFile = "$logDir\stopfailure_events.jsonl"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

$event = [ordered]@{
    timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    session_id    = $hookInput.session_id
    error_type    = $hookInput.error_type
    error_message = $hookInput.error_message
    cwd           = $hookInput.cwd
}

# Same global mutex the other hooks and scripts use -- avoids a race between parallel sessions
# appending to the same file at the same instant.
$mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$mutexAcquired = $false
try {
    try { $mutexAcquired = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    # UTF8Encoding($false) = no BOM. `Add-Content -Encoding utf8` on PowerShell 5.1 writes a BOM on
    # file CREATION, and a BOM on line 1 breaks `json.loads` for anyone reading the .jsonl later --
    # exactly what the session-end record had to fix. Here the file had never been created (zero
    # events), so the defect was latent rather than visible.
    $line = ($event | ConvertTo-Json -Compress) + "`r`n"
    [System.IO.File]::AppendAllText($logFile, $line, (New-Object System.Text.UTF8Encoding $false))
} finally {
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

exit 0
