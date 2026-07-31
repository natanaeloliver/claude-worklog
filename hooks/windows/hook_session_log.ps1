<#
.SYNOPSIS
    Stop hook -- records the active demand's uncommitted files in its session_log.md, then syncs
    git. Fires after EVERY assistant response (Stop event, once per turn), so it is idempotent
    (see the "replace -- do not accumulate" block). It does NOT touch any session state (demand
    file, markers, heartbeat, active_demands.txt): that cleanup is the exclusive responsibility of
    hook_session_end.ps1 (SessionEnd event), which fires once when the session truly ends. Before
    this split, Stop tried to distinguish mid-turn from /exit by checking activeFlag presence and
    cleaned up state itself -- that caused a false-dead-session bug (the flag looked "gone" during
    any normal gap between turns of a live session), fixed 2026-07-14.
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
# confirmed to cause cross-session state corruption (2026-07-01). Failing safe (skip logging
# for this call) is preferable to silently guessing the wrong identity.

# Session file keyed by session_id -- stable and identical across all hooks
$demandFile = if ($sessionId) { "$env:TEMP\claude_demand_$sessionId.txt" } else { $null }

# Ticket: demand file by session_id (written by inject hook)
$ticket = $null
if ($demandFile -and (Test-Path $demandFile)) {
    $ticket = @(Get-Content $demandFile -Encoding utf8 | Where-Object { $_.Trim() })[0]
    if ($ticket) { $ticket = $ticket.Trim() }
}

# NO shared-file fallback -- deliberate.
# Until 2026-07-28 there was a fallback to current_demand.txt here. Since that file was written by
# new-demand.ps1 and never updated on demand switches, a session with NO demand (stand-by, or after
# standby.ps1) appended its uncommitted files to the session_log.md of some old demand -- silently
# corrupting the audit trail. It was unobservable in practice because the file was usually empty;
# introducing last_demand.txt (a resume point that is always populated) would have made the
# fallback wrong in every stand-by session.
# Rule: the audit trail is never inferred. With no demand file for this session, there is nothing
# to record.
if (-not $ticket) { exit 0 }

$ticketDir  = "$worklogRoot\worklogs\$ticket"
$sessionLog = "$ticketDir\session_log.md"
if (-not (Test-Path $ticketDir)) { exit 0 }

$gitUser = (git -C $worklogRoot config user.name 2>$null)
if ($gitUser) { $gitUser = $gitUser.Trim() }
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

# --- Collecting uncommitted files: ATTRIBUTION BY EVIDENCE ------------------------------------
# Until 2026-07-28 this block scanned every repo in repos.conf and appended the result to THIS
# session's demand log. With parallel sessions sharing those working trees, one demand's work showed
# up in the other demands' logs -- corrupting the very source of truth of the audit trail (real
# case: files from one demand recorded in two other demands' logs).
#
# Now only work with evidence of belonging to this demand is included:
#   1. a git worktree under worklogs/<TICKET>/ -- the path itself identifies the demand;
#   2. a monitored repo whose current branch is "<TICKET>" or ends with "/<TICKET>".
# A monitored repo sitting on main/dev or on another demand's branch is NOT included: it is not
# this demand's work.
#
# CONSEQUENCE, on purpose: if you work without a per-demand branch and without a per-demand
# worktree, there is no evidence to attribute, so no uncommitted-files block is written. Silence is
# correct here -- the previous behavior filled the log with other demands' files.
$repos = Read-ReposConf "$worklogRoot\repos.conf"

# Sources to inspect: @{ Label; Path }
$sources = [System.Collections.Generic.List[object]]::new()

# 1. Worktrees of this demand
foreach ($d in @(Get-ChildItem $ticketDir -Directory -EA SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName ".git")) {
        $sources.Add([pscustomobject]@{ Label = $d.Name; Path = $d.FullName })
    }
}

# 2. Monitored repos checked out on this demand's branch
foreach ($entry in $repos.GetEnumerator()) {
    if (-not (Test-Path $entry.Value)) { continue }
    $branch = (git -C $entry.Value branch --show-current 2>$null)
    if ($branch) { $branch = $branch.Trim() }
    if ($branch -and ($branch -eq $ticket -or $branch.EndsWith("/$ticket"))) {
        $sources.Add([pscustomobject]@{ Label = "$($entry.Key):main-copy"; Path = $entry.Value })
    }
}

$allFiles = @()

foreach ($source in $sources) {
    Push-Location $source.Path
    try {
        # @() is mandatory on each call: git returns a String when the output has ONE line and an
        # Object[] when it has two or more. With a String on the left-hand side, PowerShell's "+"
        # concatenates TEXT instead of adding collections, gluing two paths into a single entry
        # ("notes.md" + "todo.md" -> "notes.mdtodo.md"). Real bug found 2026-07-28 -- it only shows
        # up when each command returns 0 or 1 file, which is why it stayed invisible for months.
        $files = (@(git diff --name-only 2>$null) +
                  @(git diff --name-only --cached 2>$null) +
                  @(git ls-files --others --exclude-standard 2>$null)) |
            Where-Object { $_ } |
            Sort-Object -Unique

        if ($files) {
            $allFiles += @($files | ForEach-Object { "[$($source.Label)] $_" })
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
    $newBlock    = "Uncommitted files:`n- $list"
    $todayHeader = "## $today $gitUser"

    # The hook does NOT create the day's section -- deliberate.
    # Until 2026-07-28 it Add-Content'ed a "## date user / (no description)" section just to record
    # open files. That polluted the audit trail with empty entries and leaked outside the worklog for
    # anyone mirroring the day's section into an external sprint tool.
    # The day's section is the record of what was done -- the responsibility of whoever did the work,
    # not of a hook. Without the section the block is simply not written; day-report.ps1 already
    # flags the absence under "Commits with no session_log entry".
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
        }
        # No section for today: nothing to do (see the comment above).
    }
    # No session_log.md at all: same -- the file is created when the first session is recorded,
    # not by the hook.
}

# Sync with the team on every Stop: local commit -> pull --rebase -> push.
# It lives here (not in SessionEnd) because Stop fires every turn and is reliable; SessionEnd is
# hard-killed on /exit (anthropics/claude-code#70465), so it was never a safe place for a git sync.
# Commit everything before the pull -- prevents rebase failure from uncommitted files.
# On conflict with a teammate (someone edited a file also modified here), ABORT the rebase and defer
# the push to the next Stop -- never leave a rebase stuck, which breaks every subsequent hook in the
# session.
#
# The WHOLE block runs under the global mutex (Global\ClaudeWorklogStateLock -- the same one used for
# active_demands and for the inject hook's pull): several sessions on this machine share ONE working
# tree, and two concurrent `git` processes on the same .git produce index.lock / rejected push /
# stuck rebase. The mutex serializes add/commit/pull/push across sessions. High timeout (a push can
# be slow); if it cannot acquire, proceed anyway -- better to sync without the lock than never.
$syncMutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
$syncMutexAcquired = $false
try {
    try { $syncMutexAcquired = $syncMutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $syncMutexAcquired = $true }

    Push-Location $worklogRoot
    try {
        $pending = @(git status --porcelain 2>$null | Where-Object { $_ })
        if ($pending.Count -gt 0) {
            # Strip the double quotes --porcelain wraps around names containing spaces: embedded in
            # the commit message, PowerShell 5.1 mangled them while passing -m to the native git
            # (message split -> "pathspec did not match" -> commit failed -> files stayed staged ->
            # pull --rebase failed -> nothing was ever pushed). Writing the message to a file and
            # using `git commit -F` removes the quoting problem entirely.
            $list = ($pending | Select-Object -First 10 | ForEach-Object { $_.TrimStart() -replace '"', '' }) -join ', '
            if ($pending.Count -gt 10) { $list += " ... and $($pending.Count - 10) more" }
            git add -A
            $commitMsg = "auto-commit on close [$ticket] - identify: $list"
            $msgFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($msgFile, $commitMsg, (New-Object System.Text.UTF8Encoding $false))
            git commit -F $msgFile
            Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        }

        git pull --rebase origin main
        if ($LASTEXITCODE -eq 0) {
            git push origin main
        } else {
            git rebase --abort   # conflict with a teammate -- push waits for the next Stop
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($syncMutexAcquired) { $syncMutex.ReleaseMutex() }
    $syncMutex.Dispose()
}
