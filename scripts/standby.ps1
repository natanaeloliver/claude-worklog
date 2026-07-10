<#
.SYNOPSIS
    Puts Claude Code in stand-by mode (no active demand).
    No demand context will be injected in the next session.
    To resume: create or switch to a demand and reopen Claude.
#>

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }

# Locate session_id by walking the process tree (same approach as switch-demand.ps1)
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

$previous = $null

if ($sessionId) {
    $demandFile = "$env:TEMP\claude_demand_$sessionId.txt"
    if (Test-Path $demandFile) {
        $previous = @(Get-Content $demandFile -Encoding utf8 | Where-Object { $_.Trim() })[0]

        # Remove from active_demands.txt
        $activeFile = "$worklogRoot\active_demands.txt"
        if (Test-Path $activeFile) {
            $lines = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
            if ($lines.Count -gt 1) {
                ($lines | Where-Object { $_.Trim() -ne $previous }) | Set-Content $activeFile -Encoding utf8
            } else {
                Set-Content $activeFile -Value "" -Encoding utf8
            }
        }

        Remove-Item $demandFile -Force -ErrorAction SilentlyContinue
    }
}

# Legacy compatibility
$currentFile = "$worklogRoot\current_demand.txt"
Set-Content -Path $currentFile -Value "" -Encoding utf8

if ($previous) {
    Write-Host "Stand-by activated (was: $previous)." -ForegroundColor Cyan
} else {
    Write-Host "Stand-by activated." -ForegroundColor Cyan
}
Write-Host "To resume: use 'switch demand' in Claude or open a new window." -ForegroundColor Gray
