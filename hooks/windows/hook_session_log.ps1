<#
.SYNOPSIS
    Stop hook -- logs session end to session_log.md of the active demand.
    Detects uncommitted files across monitored repos and appends them to the current day's entry.
    Claude writes the description before closing; this hook appends files and syncs git.
#>

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

# Read session_id from stdin (JSON sent by Claude Code) -- stable and identical to inject hook.
# Do NOT gate on [Console]::In.Peek() -- confirmed via live debugging (2026-07-01) that Peek()
# can return -1 even when Claude Code does send JSON over stdin on this host.
$sessionId = $null
try {
    $stdinContent = [Console]::In.ReadToEnd()
    if ($stdinContent) {
        $hookInput = $stdinContent | ConvertFrom-Json
        $sessionId = $hookInput.session_id
    }
} catch {}

# No JSONL-based fallback: with multiple sessions sharing the same Claude project directory,
# "most recently modified jsonl" can belong to ANY active session, not just the caller --
# confirmed to cause cross-session state corruption (2026-07-01). Failing safe (skip cleanup
# for this call) is preferable to silently guessing the wrong identity.

# Session files keyed by session_id -- stable and identical in inject and Stop hooks
$demandFile    = if ($sessionId) { "$env:TEMP\claude_demand_$sessionId.txt"  } else { $null }
$activeFlag    = if ($sessionId) { "$env:TEMP\claude_active_$sessionId.flag" } else { $null }
$sessionMarker = if ($sessionId) { "$env:TEMP\claude_ctx_$sessionId.marker"  } else { $null }

# Ticket: demand file by session_id (written by inject hook)
$ticket = $null
if ($demandFile -and (Test-Path $demandFile)) {
    $ticket = @(Get-Content $demandFile -Encoding utf8 | Where-Object { $_.Trim() })[0]
    if ($ticket) { $ticket = $ticket.Trim() }
}

# Legacy fallback: current_demand.txt
if (-not $ticket) {
    $currentFile = "$worklogRoot\current_demand.txt"
    if (Test-Path $currentFile) {
        $ticket = (Get-Content $currentFile -Raw -Encoding utf8).Trim()
    }
}

if (-not $ticket) { exit 0 }

$ticketDir  = "$worklogRoot\worklogs\$ticket"
$sessionLog = "$ticketDir\session_log.md"
if (-not (Test-Path $ticketDir)) { exit 0 }

$gitUser = (git -C $worklogRoot config user.name 2>$null).Trim()
if (-not $gitUser) { $gitUser = $env:USERNAME }

# Read monitored repos from repos.conf
function Read-ReposConf {
    param([string]$confPath)
    $result = [ordered]@{}
    if (-not (Test-Path $confPath)) { return $result }
    foreach ($line in Get-Content $confPath -Encoding utf8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $alias = $line.Substring(0, $idx).Trim()
        $path  = $line.Substring($idx + 1).Trim()
        if ($alias -and $path) { $result[$alias] = $path }
    }
    return $result
}

$repos = Read-ReposConf "$worklogRoot\repos.conf"

$modifiedRepos = @()
$allFiles      = @()

foreach ($entry in $repos.GetEnumerator()) {
    $repoPath = $entry.Value
    if (-not (Test-Path $repoPath)) { continue }

    Push-Location $repoPath
    try {
        $unstaged  = git diff --name-only 2>$null
        $staged    = git diff --name-only --cached 2>$null
        $untracked = git ls-files --others --exclude-standard 2>$null

        $files = ($unstaged + $staged + $untracked) |
            Where-Object { $_ } |
            Sort-Object -Unique

        if ($files) {
            $modifiedRepos += $entry.Key
            $allFiles += $files | ForEach-Object { "[$($entry.Key)] $_" }
        }
    } finally {
        Pop-Location
    }
}

# Update uncommitted files block in session_log.md (replace -- do not accumulate)
if ($allFiles.Count -gt 0) {
    $today = Get-Date -Format 'yyyy-MM-dd'

    $list = ($allFiles | Select-Object -First 10) -join "`n- "
    if ($allFiles.Count -gt 10) {
        $list += "`n- ... and $($allFiles.Count - 10) more file(s)"
    }
    $reposStr    = $modifiedRepos -join ', '
    $newBlock    = "Uncommitted files:`n- $list"
    $todayHeader = "## $today $gitUser"

    if (Test-Path $sessionLog) {
        $lines    = Get-Content $sessionLog -Encoding utf8
        $todayIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq $todayHeader) { $todayIdx = $i; break }
        }

        if ($todayIdx -ge 0) {
            $sectionEnd = $lines.Count
            for ($i = $todayIdx + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^## ') { $sectionEnd = $i; break }
            }

            $blockStart = -1
            for ($i = $todayIdx + 1; $i -lt $sectionEnd; $i++) {
                if ($lines[$i] -match '^Uncommitted files') { $blockStart = $i; break }
            }

            if ($blockStart -ge 0) {
                $blockEnd = $blockStart + 1
                while ($blockEnd -lt $sectionEnd -and $lines[$blockEnd] -match '^- ') { $blockEnd++ }

                $existingFiles = if ($blockEnd -gt $blockStart + 1) {
                    $lines[($blockStart+1)..($blockEnd-1)] | ForEach-Object { $_.TrimStart('- ') }
                } else { @() }
                $existingStr = ($existingFiles | Sort-Object) -join "`n"
                $currentStr  = ($allFiles | Sort-Object) -join "`n"

                if ($existingStr -ne $currentStr) {
                    $before = if ($blockStart -gt 0) { $lines[0..($blockStart-1)] } else { @() }
                    $after  = if ($blockEnd -lt $lines.Count) { $lines[$blockEnd..($lines.Count-1)] } else { @() }
                    ($before + $newBlock.Split("`n") + $after) | Set-Content $sessionLog -Encoding utf8
                }
            } else {
                $before = $lines[0..($sectionEnd-1)]
                $after  = if ($sectionEnd -lt $lines.Count) { $lines[$sectionEnd..($lines.Count-1)] } else { @() }
                ($before + "" + $newBlock.Split("`n") + $after) | Set-Content $sessionLog -Encoding utf8
            }
        } else {
            $newSection = "`n## $today $gitUser`n`n(no description)`n`nRepos: $reposStr`n`n$newBlock"
            Add-Content -Path $sessionLog -Value $newSection -Encoding utf8
        }
    } else {
        $content = "# $ticket`n`n## $today $gitUser`n`n(no description)`n`nRepos: $reposStr`n`n$newBlock"
        Set-Content -Path $sessionLog -Value $content -Encoding utf8
    }
}

# Detect mid-turn vs /exit:
# The inject hook creates/updates claude_active_{session_id}.flag on every message.
# If the flag exists: Stop fired after a normal response (mid-turn) -- remove flag, skip cleanup.
# If the flag does not exist: Stop fired by /exit -- clean up markers and active_demands.txt.

# Retry before concluding absence: confirmed (2026-07-01, live debugging) that Test-Path can
# fail transiently under heavy concurrent I/O in %TEMP% (multiple Claude sessions touching the
# same files), making this hook treat mid-turn as /exit by mistake.
$activeFlagExists = $activeFlag -and (Test-Path $activeFlag)
if (-not $activeFlagExists -and $activeFlag) {
    Start-Sleep -Milliseconds 150
    $activeFlagExists = Test-Path $activeFlag
}

if ($activeFlagExists) {
    Remove-Item $activeFlag -Force -ErrorAction SilentlyContinue
} else {
    $activeFile = "$worklogRoot\active_demands.txt"

    # Same lock used by hook_context_inject.ps1 -- protects active_demands.txt and the
    # claude_demand_*/claude_ctx_*/claude_active_* files against races between concurrent
    # sessions (confirmed to cause real state corruption/loss, live debugging 2026-07-01).
    $worklogMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
    $worklogMutexAcquired = $false
    try {
        try {
            $worklogMutexAcquired = $worklogMutex.WaitOne(10000)
        } catch [System.Threading.AbandonedMutexException] {
            $worklogMutexAcquired = $true
        }

        if ((Test-Path $activeFile) -and $ticket) {
            $lines = @(Get-Content $activeFile -Encoding utf8 | Where-Object { $_.Trim() })
            if ($lines.Count -gt 1) {
                ($lines | Where-Object { $_.Trim() -ne $ticket }) | Set-Content $activeFile -Encoding utf8
            }
        }
        if ($sessionMarker) { Remove-Item $sessionMarker -Force -EA SilentlyContinue }
        if ($demandFile)    { Remove-Item $demandFile    -Force -EA SilentlyContinue }
        if ($activeFlag)    { Remove-Item $activeFlag    -Force -EA SilentlyContinue }
    } finally {
        if ($worklogMutexAcquired) { $worklogMutex.ReleaseMutex() }
        $worklogMutex.Dispose()
    }
}

# Commit everything before pull -- prevents rebase failure from uncommitted files
Push-Location $worklogRoot
try {
    $pending = @(git status --porcelain 2>$null) | Where-Object { $_ }
    if ($pending.Count -gt 0) {
        $list = ($pending | Select-Object -First 10 | ForEach-Object { $_.TrimStart() }) -join ', '
        if ($pending.Count -gt 10) { $list += " ... and $($pending.Count - 10) more" }
        git add -A
        git commit -m "auto-commit on close [$ticket] - identify: $list"
    }
} finally {
    Pop-Location
}

# Sync
git -C $worklogRoot pull --rebase origin main
if ($LASTEXITCODE -eq 0) {
    git -C $worklogRoot add $ticketDir
    git -C $worklogRoot commit -m "log: $ticket $(Get-Date -Format 'yyyy-MM-dd') [$gitUser]" 2>$null
    git -C $worklogRoot push origin main
}
