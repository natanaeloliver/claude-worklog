<#
.SYNOPSIS
    Session identity and liveness for Claude Code sessions, plus the tab name used by `/rename`.
    Shared by the inject hook and by every script that has to decide whether another session is
    still alive (open-parallel, switch-demand, resume-sessions).

    IDENTITY -- why the PID alone is not enough. Line 2 of the demand file used to hold the
    ParentProcessId of the hook's own powershell process, which is NOT claude.exe: it is an
    intermediate process that dies moments later. Measured upstream on 2026-08-29 across the two
    live sessions of that machine: one recorded PID no longer existed at all, and the other had
    been recycled by Windows onto an svchost.exe. The liveness check broke in both directions:
      - PID recycled onto another process: Get-Process finds someone, so a dead session looks ALIVE
        forever. Its entry never leaves active_demands.txt, the demand is never handed to anyone
        (fallbacks 3 and 4 treat it as claimed) and the conflict warning fires for nothing.
      - PID dead: the session only looks alive while the heartbeat is under 30 minutes, so a real
        session idle for longer has its state wiped by another session.

    Fix: resolve the real claude.exe by walking up the ancestor chain, and record the process
    CREATION INSTANT alongside the PID -- that is what tells "the same claude.exe" apart from "some
    other process that inherited the number".

    The demand file therefore has 3 lines: ticket, claude.exe pid, creation ticks. A 2-line file
    from an older version is still read, with the PID IGNORED: without the creation instant there
    is no way to distinguish the original process from a namesake, and falling back to the
    heartbeat is the safe behavior.
#>

function Get-ClaudeSession {
    # Walks up the ancestor chain to the first claude.exe. No fixed hop count is assumed: Claude
    # Code may insert intermediate processes between itself and the hook.
    $session = @{ Pid = 0; Created = '' }
    try {
        $walkPid = $PID
        for ($i = 0; $i -lt 12 -and $walkPid -gt 0; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$walkPid" -EA Stop
            if (-not $proc) { break }
            if ($proc.Name -like 'claude*') {
                $session = @{ Pid = [int]$walkPid; Created = "$($proc.CreationDate.Ticks)" }
                break
            }
            $walkPid = [int]$proc.ParentProcessId
        }
    } catch { }
    return $session
}

function Read-DemandFile {
    param([string]$Path)
    $lines = @(Get-Content $Path -Encoding utf8 -EA SilentlyContinue | Where-Object { $_.Trim() })
    @{
        Ticket  = if ($lines.Count -gt 0) { $lines[0].Trim() } else { '' }
        Pid     = if ($lines.Count -gt 1) { try { [int]$lines[1].Trim() } catch { 0 } } else { 0 }
        Created = if ($lines.Count -gt 2) { $lines[2].Trim() } else { '' }
    }
}

function Write-DemandFile {
    param([string]$Path, [string]$Ticket, [hashtable]$Session)
    Set-Content $Path -Value "$Ticket`n$($Session.Pid)`n$($Session.Created)" -Encoding utf8
}

function Test-SessionAlive {
    param([int]$TargetPid, [string]$Created, [string]$FlagPath)

    # The PID only counts as a sign of life together with the creation instant. Without it there is
    # no way to tell the original claude.exe from whatever process inherited the number -- Windows
    # recycles PIDs within minutes, and that is exactly how a dead session became "alive forever".
    if ($TargetPid -gt 0 -and $Created) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -EA Stop
            if ($proc -and ($proc.Name -like 'claude*') -and ("$($proc.CreationDate.Ticks)" -eq $Created)) { return $true }
        } catch { }
    }

    # Heartbeat: touched on every message by the inject hook, removed only at SessionEnd.
    # Retry on Test-Path: a single read can fail transiently under heavy concurrent I/O (several
    # sessions touching the same %TEMP% files), concluding "dead" for a live session.
    if (Test-Path $FlagPath) { return ((Get-Date) - (Get-Item $FlagPath).LastWriteTime).TotalMinutes -lt 30 }
    Start-Sleep -Milliseconds 150
    if (Test-Path $FlagPath) { return ((Get-Date) - (Get-Item $FlagPath).LastWriteTime).TotalMinutes -lt 30 }
    return $false
}

# ---------------------------------------------------------------------------------------------
# Session name for `/rename` -- the text that becomes the tab title and the `/resume` entry.
#
# Why it exists: without it the tab title is the automatic summary Claude Code writes, which does
# not say which demand that window is serving -- and with parallel sessions that is exactly the
# missing information. `/rename` is a LOCAL CLI command: passed as the INITIAL PROMPT of `claude`
# it writes custom-title + agent-name into the session file and costs no API turn (measured
# upstream 2026-08-11; it works with `--resume <sid>` too).
#
# It can be automated when the window is opened (open-parallel.ps1, resume-sessions.ps1). It cannot
# on a demand switch or on stand-by: the session is already running, and neither a script nor
# Claude itself can execute a CLI built-in (there is no tool for it; anthropics/claude-code#33181
# asks for that API). In those two cases the script prints the ready-made line and the step is human.
#
# Deliberately accent-free: the name crosses `wt` -> `powershell -Command` -> `claude`, and a
# non-ASCII character on that path is read through the console code page and comes out mangled.
# ---------------------------------------------------------------------------------------------

function Remove-Accents {
    param([string]$Text)
    if (-not $Text) { return '' }
    $d = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function Get-SessionName {
    <#
    .SYNOPSIS
        "PROJ-001 Implement user auth" from the H1 of the demand's CONTEXT.md. With no CONTEXT.md
        and no H1 it returns the ticket alone -- a short name always beats a wrong one.
    #>
    param(
        [Parameter(Mandatory)][string]$Ticket,
        [string]$WorklogsDir,
        [int]$MaxLen = 30
    )

    $ticket = $Ticket.Trim()
    if (-not $WorklogsDir) { return $ticket }

    $ctx = Join-Path (Join-Path $WorklogsDir $ticket) 'CONTEXT.md'
    if (-not (Test-Path $ctx)) { return $ticket }

    $top = $null
    try { $top = @(Get-Content $ctx -Encoding utf8 -TotalCount 5 -EA Stop) } catch { return $ticket }

    # A CONTEXT.md written by an editor may start with a BOM, which sticks to the first line and
    # would stop `^#` from matching. The character is built with [char]: this .ps1 has no BOM, and
    # PowerShell 5.1 reads a BOM-less file as ANSI, so a literal non-ASCII byte would arrive mangled.
    $bom = [char]0xFEFF
    $h1 = @($top | ForEach-Object { $_ -replace "^$bom", '' } | Where-Object { $_ -match '^#\s+\S' })[0]
    if (-not $h1) { return $ticket }

    # "# Demand PROJ-001 - Implement user auth" -> "Implement user auth"
    $t = $h1 -replace '^#\s+', ''
    $t = $t -replace '^Demand\s+', ''
    $t = $t -replace ([regex]::Escape($ticket) + '\b'), ''
    # separator between ticket and title: colon, hyphen or en/em dash, spaces on either side
    $t = $t -replace ('^\s*[:' + [char]0x2013 + [char]0x2014 + '\-]\s*'), ''
    # cut at the first subtitle separator -- the short title is what fits in a tab
    $t = ($t -split ('\s*[:,;|]\s*|\s+[' + [char]0x2013 + [char]0x2014 + ']\s+|\s+-\s+'))[0]

    $t = (Remove-Accents $t).Trim()
    # quoting: the name goes inside '...' in powershell's -Command; a quote would break the line
    $t = $t -replace "['`"]", ''
    # control/non-printable characters do not belong in a tab title
    $t = ($t -replace '[^\x20-\x7E]', '').Trim()

    if (-not $t) { return $ticket }

    if ($t.Length -gt $MaxLen) {
        $cut  = $t.Substring(0, $MaxLen)
        $last = $cut.LastIndexOf(' ')
        $t = if ($last -ge 12) { $cut.Substring(0, $last) } else { $cut }
        $t = $t.TrimEnd()
        # a preposition or article left dangling by the cut reads worse than cutting one word
        # earlier -- cosmetic only, but a tab title is glanced at dozens of times
        $t = $t -replace '\s+(of|the|a|an|to|for|in|on|and|with)$', ''
        # an opening parenthesis the cut never closed reads as an error, not as a truncation
        if ($t.Contains('(') -and -not $t.Contains(')')) { $t = ($t -split '\s*\(')[0].TrimEnd() }
    }

    return "$ticket $t"
}

function Get-RenamePrompt {
    <#
    .SYNOPSIS
        The initial `claude` prompt that renames the session. Empty when there is no name, so
        callers can concatenate without a conditional.
    #>
    param([string]$Name)
    if (-not $Name) { return '' }
    return " '/rename $Name'"
}
