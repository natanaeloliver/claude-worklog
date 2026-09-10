<#
.SYNOPSIS
    Resilient read/write for active_demands.txt, shared by every script and hook that touches the
    file (open-parallel, switch-demand, standby, hook_context_inject, hook_session_end).

    Why: concurrent or interrupted writes corrupt the file, gluing every ticket onto a single line
    with no separator (observed in production as "PROJ-1PROJ-2PROJ-2PROJ-3..."). The consequence is
    silent and total: no line parses as a valid demand, so the UserPromptSubmit hook injects no
    context at all. Two real triggers: (1) $mutex.WaitOne(timeout) can return $false and the write
    happened anyway, without the lock; (2) the SessionEnd hook is hard-killed on exit
    (anthropics/claude-code#70465) and can die mid Set-Content, leaving a partial file.

    Defenses:
    - Get-ActiveDemands: tolerant read -- splits on \r?\n and, when a "token" is not a valid demand
      directory on its own, greedily separates it using the known directory names. Self-healing.
    - Set-ActiveDemands: ATOMIC write (writes a .tmp on the same volume, then renames via
      File.Replace/File.Move). A hard kill mid-write can never leave the final file partial.
#>

function Get-ActiveDemands {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$WorklogsDir
    )
    if (-not (Test-Path $Path)) { return @() }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($Path) } catch { return @() }
    if (-not $raw) { return @() }

    # Known demand directories (longest first) so a separator-less blob can be split back apart.
    $known = @()
    if ($WorklogsDir -and (Test-Path $WorklogsDir)) {
        $known = @(Get-ChildItem -LiteralPath $WorklogsDir -Directory -EA SilentlyContinue |
            ForEach-Object { $_.Name } | Sort-Object { $_.Length } -Descending)
    }

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($raw -split "\r?\n")) {
        $t = $line.Trim().TrimStart([char]0xFEFF)
        if (-not $t) { continue }

        if (($known.Count -gt 0) -and ($known -notcontains $t)) {
            # Not a valid demand on its own -- may be several glued together. Split greedily.
            $rest = $t
            while ($rest) {
                $match = $known | Where-Object { $rest.StartsWith($_) } | Select-Object -First 1
                if ($match) {
                    $result.Add($match)
                    $rest = $rest.Substring($match.Length)
                } else {
                    # Token outside the known set: try a ticket-shaped prefix (ABC-123 or digits),
                    # otherwise keep the remainder whole -- consumers drop what has no directory.
                    $m = [regex]::Match($rest, '^([A-Za-z][A-Za-z0-9]*-\d+|\d+)')
                    if ($m.Success) { $result.Add($m.Value); $rest = $rest.Substring($m.Length) }
                    else { $result.Add($rest); $rest = '' }
                }
            }
        } else {
            $result.Add($t)
        }
    }
    return @($result | Select-Object -Unique)
}

function Set-ActiveDemands {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Tickets
    )
    $clean = @($Tickets | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $text = if ($clean.Count -gt 0) { ($clean -join "`r`n") + "`r`n" } else { '' }

    $enc = New-Object System.Text.UTF8Encoding($true)
    $tmp = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $text, $enc)

    # Atomic rename on the same volume. File.Replace keeps atomicity on NTFS when the destination
    # exists; File.Move otherwise. Small retry: a brief reader may hold the file open at that instant.
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if (Test-Path $Path) { [System.IO.File]::Replace($tmp, $Path, $null) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        } catch {
            Start-Sleep -Milliseconds 80
        }
    }
    # Last resort: direct (non-atomic) write rather than losing the state.
    [System.IO.File]::WriteAllText($Path, $text, $enc)
    Remove-Item $tmp -Force -EA SilentlyContinue
}
