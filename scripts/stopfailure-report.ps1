<#
.SYNOPSIS
    Reader for logs/stopfailure_events.jsonl -- closes the StopFailure measurement loop.

.DESCRIPTION
    hooks/windows/hook_stop_failure_log.ps1 records one API error per turn (529 overloaded,
    429 rate_limit, ...), declaring itself a measurement phase: decide whether an action layer is
    worth building after seeing how many events actually happen, and of what kind. This is the
    missing half -- a log with no consumer decides nothing.

    It answers the three questions the decision needs: how many events, of what type, and how often.
    And it prints the verdict with the criterion spelled out, so it does not depend on how whoever
    runs it happens to read the numbers.

.PARAMETER Days
    Analysis window in days (default 30). Older events count only towards the log-wide total.

.PARAMETER All
    Ignore the window and analyze the whole log.

.EXAMPLE
    .\scripts\stopfailure-report.ps1
    .\scripts\stopfailure-report.ps1 -Days 7
    .\scripts\stopfailure-report.ps1 -All
#>

param(
    [int]$Days = 30,
    [switch]$All
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$logFile = "$worklogRoot\logs\stopfailure_events.jsonl"

# A missing file is NOT a failure -- it is the most likely and the most informative result: zero API
# errors recorded since the measurement started. Report it as a measurement, not as an error. The
# absence means something precisely because the hook writes on the FIRST occurrence.
if (-not (Test-Path $logFile)) {
    Write-Host "StopFailure -- no events recorded" -ForegroundColor Green
    Write-Host "  log:  $logFile (does not exist)"
    Write-Host "  hook: hooks/windows/hook_stop_failure_log.ps1 (writes on the first occurrence)"
    Write-Host ""
    Write-Host "  Verdict: an action layer is NOT justified -- there is nothing to mitigate." -ForegroundColor Green
    Write-Host "  Check the hook is actually armed: StopFailure is not wired up by default,"
    Write-Host "  it has to be added to .claude/settings.json."
    exit 0
}

$events = @()
$badLines = 0
foreach ($line in (Get-Content $logFile -Encoding utf8 -EA SilentlyContinue)) {
    if (-not $line.Trim()) { continue }
    # Tolerate a BOM on line 1: PowerShell 5.1's `Add-Content -Encoding utf8` used to put one on file
    # creation. Without this, ConvertFrom-Json fails on line 1 and the report silently loses the
    # oldest event.
    $clean = $line.TrimStart([char]0xFEFF).Trim()
    try { $events += ($clean | ConvertFrom-Json) } catch { $badLines++ }
}

if ($badLines -gt 0) {
    Write-Host "WARNING: $badLines unreadable line(s) in the log -- ignored." -ForegroundColor Yellow
}

$now    = Get-Date
$cutoff = if ($All) { [datetime]::MinValue } else { $now.AddDays(-$Days) }
$window = @($events | Where-Object {
    $ts = $null
    if ([datetime]::TryParse($_.timestamp, [ref]$ts)) { $ts -ge $cutoff } else { $false }
})

$label = if ($All) { "the whole log" } else { "the last $Days days" }
Write-Host ""
Write-Host "StopFailure -- $($window.Count) event(s) in $label  ($($events.Count) in the log overall)" -ForegroundColor Cyan
Write-Host "  log: $logFile"

if ($window.Count -eq 0) {
    Write-Host ""
    Write-Host "  Verdict: an action layer is NOT justified in the window analyzed." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "By error type:" -ForegroundColor Cyan
$window | Group-Object error_type | Sort-Object Count -Descending |
    Select-Object @{n='error_type';e={ if ($_.Name) { $_.Name } else { '(no type)' } }}, Count |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "By day:" -ForegroundColor Cyan
$window | Group-Object { ([datetime]$_.timestamp).ToString('yyyy-MM-dd') } | Sort-Object Name |
    Select-Object @{n='day';e={$_.Name}}, Count |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "By session (top 5):" -ForegroundColor Cyan
$window | Group-Object session_id | Sort-Object Count -Descending | Select-Object -First 5 |
    Select-Object @{n='session_id';e={ if ($_.Name) { $_.Name.Substring(0, [Math]::Min(8, $_.Name.Length)) } else { '(no id)' } }}, Count |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "Last 5 events:" -ForegroundColor Cyan
foreach ($e in ($window | Sort-Object { [datetime]$_.timestamp } -Descending | Select-Object -First 5)) {
    $msg = if ($e.error_message) { $e.error_message } else { '' }
    if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) + '...' }
    Write-Host ("  {0}  {1,-22}  {2}" -f ([datetime]$e.timestamp).ToString('yyyy-MM-dd HH:mm'), $e.error_type, $msg)
}

# The decision criterion, deliberately explicit: the log exists to decide whether the action layer
# (retry/backoff/notify) is worth building, and "worth it" needs a number, not an impression.
$days = [Math]::Max(1, $Days)
$perDay = [Math]::Round($window.Count / $days, 2)
Write-Host ""
Write-Host "Average: $perDay event(s)/day in the window." -ForegroundColor Cyan
if ($perDay -ge 1) {
    Write-Host "  Verdict: an action layer IS justified (>= 1/day) -- the lost turn is recurring." -ForegroundColor Yellow
} else {
    Write-Host "  Verdict: an action layer is not justified yet (< 1/day); keep measuring." -ForegroundColor Green
}
