<#
.SYNOPSIS
    Lists recent session endings and reopens a dead session by RESUMING the conversation
    (`claude --resume <session_id>`) rather than starting a fresh session on the same demand.

.DESCRIPTION
    Why it exists: when several sessions die at once, hook_session_end.ps1 RUNS in all of them --
    each removes its own ticket from active_demands.txt (the guard there only protects a ticket
    claimed by ANOTHER session, and distinct tickets do not protect each other), and
    last_demand.txt, single-valued by design, keeps only the last one. Measured upstream on
    2026-08-11: three live sessions died at 10:34 and two of the three demands left no trace at all
    in the worklog state, so recovery had to come out of Claude Code's own transcripts, which are
    not an actor of this system. The logs/sessions_ended.jsonl record written by the SessionEnd hook
    closes that gap, and this script is its consumer.

    Why it is NOT a `-Resume` switch on open-parallel.ps1: that script's delivery is a reservation
    for a NEW window, and a resume already knows its identity (the session_id). Delivery here is the
    resumed session's own demand file (claude_demand_<sid>.txt), which is fallback 1 of
    hook_context_inject.ps1 and wins over everything else. Routing a resume through any
    first-come-first-served channel lets another live session consume it and walk off with the
    ticket -- a real cross-up, measured on the first manual recovery.

.PARAMETER Sid
    session_id(s) to reopen. Accepts the full UUID or a unique prefix.

.PARAMETER LastCrash
    Reopens every session in the most recent "burst" of endings -- those that ended within
    -WindowSeconds of the most recent one. This is the "the system closed every claude" case.

.PARAMETER WindowSeconds
    Width of the burst (default 60). Manual exits in quick succession also form a burst: the script
    prints each `reason` so the decision is yours instead of guessed by a heuristic.

.PARAMETER Last
    How many endings to list (default 10).

.PARAMETER DryRun
    Shows what it would do (resolved ticket, command, state) without opening a window or writing
    any state.

.EXAMPLE
    .\resume-sessions.ps1                       # list recent endings
    .\resume-sessions.ps1 -LastCrash -DryRun    # check what would be reopened
    .\resume-sessions.ps1 -LastCrash
    .\resume-sessions.ps1 -Sid 644cefa4,647359d2
#>
param(
    [string[]]$Sid,
    [switch]$LastCrash,
    [int]$WindowSeconds = 60,
    [int]$Last = 10,
    [switch]$DryRun
)

$worklogRoot = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { $PSScriptRoot | Split-Path -Parent }
$activeFile  = "$worklogRoot\active_demands.txt"
$recordFile  = "$worklogRoot\logs\sessions_ended.jsonl"
. "$PSScriptRoot\active_demands_lib.ps1"
. "$PSScriptRoot\session_lib.ps1"   # Read-DemandFile / Test-SessionAlive / Get-SessionName / Get-RenamePrompt

# ---------------------------------------------------------------------------------------------
# Candidate sources
# ---------------------------------------------------------------------------------------------

# Claude Code's transcript folder for this project. The name is the cwd path with `:`, `\` and `.`
# replaced by `-`. Derived and then VERIFIED, not assumed: if the folder does not exist, the
# transcript source simply contributes nothing instead of breaking the script.
function Get-TranscriptFolder {
    $slug = ($worklogRoot -replace '[:\\.]', '-')
    $p = Join-Path $env:USERPROFILE ".claude\projects\$slug"
    if (Test-Path $p) { return $p }
    return $null
}

# A session's ticket read from its own transcript: the inject hook writes the header
# `=== ACTIVE DEMAND: PROJ-001 ===`. The `===` on both sides is NOT decoration -- without it the
# pattern matches any mention of the phrase in the conversation (documentation, this script's own
# source, test output) and labels the session with whatever example ticket it found. Measured on the
# first real run.
# The LAST occurrence wins, not the first: a session with a re-injection has more than one.
# Known limit of this source: a mid-session demand switch does not print that header, so the
# transcript returns the demand that was INJECTED, not the one active at the end. The record
# (logs/sessions_ended.jsonl) is what knows the final one, because it reads the demand file at exit.
function Get-TicketFromTranscript {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $m = @(Select-String -Path $Path -Pattern '=== ACTIVE DEMAND: ([\w.-]+) ===' -AllMatches -EA SilentlyContinue |
           ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
    if ($m.Count -gt 0) { return $m[-1] }
    return $null
}

# A session is alive if its claude.exe is still running with the same creation instant, or the
# heartbeat is under 30 minutes -- the same rule the hooks use (see session_lib.ps1).
function Test-SessionStillRunning {
    param([string]$SessionId)
    $df = "$env:TEMP\claude_demand_$SessionId.txt"
    if (-not (Test-Path $df)) { return $false }
    $d = Read-DemandFile $df
    return (Test-SessionAlive $d.Pid $d.Created "$env:TEMP\claude_active_$SessionId.flag")
}

# Known endings, most recent first. The record is the primary source (it has `reason` and the
# ticket); transcripts are a fallback for sessions that predate the record existing -- which was
# exactly the case for the crash that produced this script.
function Get-Endings {
    $items = @{}

    if (Test-Path $recordFile) {
        foreach ($line in @(Get-Content $recordFile -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })) {
            try { $r = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { continue }
            if (-not $r.session_id) { continue }
            # try/catch is a statement, not an expression: on PowerShell 5.1 it cannot be a hashtable value.
            $ended = [datetime]::MinValue
            try { $ended = [datetime]::Parse($r.ts) } catch { }
            $items[$r.session_id] = [pscustomobject]@{
                SessionId = $r.session_id
                Ticket    = $r.ticket
                Reason    = $r.reason
                Ended     = $ended
                Source    = 'record'
            }
        }
    }

    $folder = Get-TranscriptFolder
    if ($folder) {
        foreach ($f in @(Get-ChildItem $folder -Filter *.jsonl -EA SilentlyContinue)) {
            $sid = $f.BaseName
            if ($items.ContainsKey($sid)) {
                # the record does not know the ticket (stand-by session, or a payload without one)
                if (-not $items[$sid].Ticket) { $items[$sid].Ticket = Get-TicketFromTranscript $f.FullName }
                continue
            }
            $items[$sid] = [pscustomobject]@{
                SessionId = $sid
                Ticket    = (Get-TicketFromTranscript $f.FullName)
                Reason    = 'no record'
                Ended     = $f.LastWriteTime
                Source    = 'transcript'
            }
        }
    }

    # A LIVE session is not an ending and drops out of the list. This is not cosmetic: -LastCrash
    # anchors the burst window on the most recent item, and a live session's transcript is by
    # definition the most recent file in the folder, because it is being written right now. Without
    # this filter the burst anchored on live sessions and the two genuinely dead ones, 23 minutes
    # earlier, fell OUTSIDE the window -- the command reopened nothing and did not say why.
    return @($items.Values | Where-Object { -not (Test-SessionStillRunning $_.SessionId) } | Sort-Object Ended -Descending)
}

# ---------------------------------------------------------------------------------------------
# Reopening
# ---------------------------------------------------------------------------------------------

function Invoke-Resume {
    param([pscustomobject]$Item)

    $sid    = $Item.SessionId
    $ticket = $Item.Ticket

    if (Test-SessionStillRunning $sid) {
        Write-Host "  $sid already has a live session -- skipping." -ForegroundColor Yellow
        return
    }
    if ($ticket -and -not (Test-Path "$worklogRoot\worklogs\$ticket")) {
        Write-Host "  WARNING: $ticket does not exist under worklogs\ -- resuming without registering a demand." -ForegroundColor Yellow
        $ticket = $null
    }

    # `/rename` as the initial prompt works with `--resume` too, so the resumed window comes back with
    # the demand in the tab title instead of the automatic summary. Local command, no API turn.
    $sessionName = if ($ticket) { Get-SessionName -Ticket $ticket -WorklogsDir "$worklogRoot\worklogs" } else { '' }
    $command = "claude --resume $sid$(Get-RenamePrompt $sessionName)"

    if ($DryRun) {
        Write-Host ("  [dry-run] {0}   (demand: {1})" -f $command, $(if ($ticket) { $ticket } else { '<none>' })) -ForegroundColor DarkGray
        return
    }

    if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
        Write-Host "  Windows Terminal (wt) not found. Open a window and run:" -ForegroundColor Red
        Write-Host "    cd `"$worklogRoot`"; $command" -ForegroundColor Yellow
        return
    }

    $pidsBefore = @(Get-Process claude -EA SilentlyContinue | Select-Object -ExpandProperty Id)

    # Clean environment in the child window: Claude Code injects runtime markers into its subprocesses
    # (NO_COLOR, AI_AGENT, CLAUDECODE, CLAUDE_CODE_*) and wt propagates them, so the child Claude comes
    # up degraded (washed-out logo, no plan/auto mode). CLAUDE_CONFIG_DIR is preserved on purpose:
    # it is configuration, not a runtime marker.
    $env:NO_COLOR = $null; $env:AI_AGENT = $null; $env:CLAUDECODE = $null
    $env:CLAUDE_PID = $null; $env:GIT_EDITOR = $null; $env:GIT_TERMINAL_PROMPT = $null
    foreach ($e in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' })) {
        Remove-Item "Env:$($e.Name)" -ErrorAction SilentlyContinue
    }

    # `-w new new-tab`, with the subcommand spelled out and the path quoted -- same reasoning as
    # open-parallel.ps1: `new-tab` is what OWNS `--startingDirectory` (it is not a global wt option,
    # and without the subcommand wt can answer with the usage dialog on screen), and an unquoted path
    # breaks silently on a clone under "C:\Users\Jane Doe\...". Always a new window: one demand per
    # window, and `-w new` is the only token that decides it.
    & wt -w new new-tab --startingDirectory "$worklogRoot" powershell.exe -NoLogo -NoExit -Command $command

    # Identity of the new claude.exe: PID plus creation instant, both needed by the liveness check.
    # Without them the resumed session would only look alive while the heartbeat stayed fresh (30
    # min), and an open, idle window does not touch the heartbeat.
    $newSession = @{ Pid = 0; Created = '' }
    for ($i = 0; $i -lt 20 -and $newSession.Pid -eq 0; $i++) {
        Start-Sleep -Milliseconds 700
        $fresh = @(Get-Process claude -EA SilentlyContinue | Where-Object { $_.Id -notin $pidsBefore })
        if ($fresh.Count -gt 0) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($fresh[0].Id)" -EA SilentlyContinue
            if ($proc) { $newSession = @{ Pid = [int]$fresh[0].Id; Created = "$($proc.CreationDate.Ticks)" } }
        }
    }

    if (-not $ticket) {
        Write-Host "  $sid resumed (no known demand; the hook resolves it through the fallback chain)." -ForegroundColor Cyan
        return
    }

    # Same global mutex as the hooks/open-parallel/switch-demand: without it a concurrent write to
    # active_demands.txt duplicates or drops entries.
    $mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeWorklogStateLock")
    $ok = $false
    try {
        try { $ok = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $ok = $true }

        Write-DemandFile -Path "$env:TEMP\claude_demand_$sid.txt" -Ticket $ticket -Session $newSession
        # Initial heartbeat: covers the case where the PID found is not the process the hook considers
        # this session's (e.g. a wrapper). Good for 30 minutes, far more than the first message needs.
        Set-Content "$env:TEMP\claude_active_$sid.flag" -Value "" -Encoding utf8 -NoNewline

        $lines = Get-ActiveDemands -Path $activeFile -WorklogsDir "$worklogRoot\worklogs"
        Set-ActiveDemands -Path $activeFile -Tickets (@($lines | Where-Object { $_.Trim() -ne $ticket }) + @($ticket))
    } finally {
        if ($ok) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    Write-Host "  $ticket resumed in $sid (claude.exe $($newSession.Pid))." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------------------------
# Flow
# ---------------------------------------------------------------------------------------------

$endings = Get-Endings
if ($endings.Count -eq 0) {
    Write-Host "No known endings (no $recordFile and no transcripts)." -ForegroundColor Yellow
    exit 0
}

$targets = @()

if ($Sid) {
    foreach ($s in $Sid) {
        $found = @($endings | Where-Object { $_.SessionId -eq $s -or $_.SessionId.StartsWith($s) })
        if ($found.Count -eq 0) { Write-Host "WARNING: no session matches '$s'." -ForegroundColor Yellow; continue }
        if ($found.Count -gt 1) {
            Write-Host "WARNING: '$s' is ambiguous ($($found.Count) sessions). Use the full UUID." -ForegroundColor Yellow
            $found | Select-Object SessionId, Ticket, Ended | Format-Table -AutoSize | Out-Host
            continue
        }
        $targets += $found[0]
    }
}
elseif ($LastCrash) {
    $mostRecent = $endings[0].Ended
    $targets = @($endings | Where-Object { ($mostRecent - $_.Ended).TotalSeconds -le $WindowSeconds })
    Write-Host ("Burst of {0} session(s) within {1}s of {2:HH:mm:ss}:" -f $targets.Count, $WindowSeconds, $mostRecent) -ForegroundColor Cyan
    if ($targets.Count -eq 1) {
        Write-Host "  Only one session in the window -- this may not have been a crash. Check the Reason column first." -ForegroundColor Yellow
    }
}

if ($targets.Count -eq 0) {
    # Listing mode (the default): show, do not act.
    $endings | Select-Object -First $Last |
        Select-Object @{n='Ended';e={$_.Ended.ToString('yyyy-MM-dd HH:mm:ss')}},
                      @{n='SessionId';e={$_.SessionId}},
                      @{n='Ticket';e={if ($_.Ticket) { $_.Ticket } else { '-' }}},
                      @{n='Reason';e={$_.Reason}},
                      @{n='Source';e={$_.Source}} |
        Format-Table -AutoSize
    Write-Host "Live sessions do not appear here (they are not endings). Source 'transcript' means it predates the record; there the Ticket is the INJECTED one, not the final one." -ForegroundColor DarkGray
    Write-Host "To reopen: -LastCrash (the most recent burst) or -Sid <session_id>. Add -DryRun to check first." -ForegroundColor DarkGray
    exit 0
}

foreach ($target in $targets) {
    Write-Host ("{0} | {1} | ended {2:yyyy-MM-dd HH:mm:ss} | reason {3}" -f
        $target.SessionId, $(if ($target.Ticket) { $target.Ticket } else { '<no demand>' }), $target.Ended, $target.Reason)
    Invoke-Resume $target
}
