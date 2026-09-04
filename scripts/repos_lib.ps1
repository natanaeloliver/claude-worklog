<#
.SYNOPSIS
    Reading and writing repos.conf, shared by every script and hook that needs the registered
    repositories (hook_session_log, day-report, repo-worktree).

    Beyond alias=path, repos.conf also stores per-repository preferences as "<alias>.<key>=value".
    The only key today is "worktree", answering: does this repository use a git worktree per demand,
    or does the work happen in the main copy on a demand branch?

    Why it is per repository and not a global convention: creating a fresh worktree means an empty
    working directory, so anything not tracked by git has to be rebuilt there -- dependencies
    (node_modules, virtualenv), local .env files, generated clients, seeded local databases. For a
    small repo that costs seconds; for an application repo it is a full reinstall and reconfiguration
    on every demand, which is pure rework. The answer depends on the repository, and often on the
    machine, so it lives in repos.conf (gitignored, per-user) and is asked only once.
#>

function Get-Repos {
    param([Parameter(Mandatory)][string]$ConfPath)

    $repos = [ordered]@{}
    $prefs = @{}
    if (-not (Test-Path $ConfPath)) { return @() }

    foreach ($line in (Get-Content $ConfPath -Encoding utf8)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $key   = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        if (-not $key -or -not $value) { continue }

        # "<alias>.<pref>" is a preference, not a repository. Matched on the LAST dot so an alias
        # containing dots still works.
        $dot = $key.LastIndexOf('.')
        if ($dot -gt 0) {
            $prefKey = $key.Substring($dot + 1).ToLower()
            if ($prefKey -in @('worktree')) {
                $prefs["$($key.Substring(0, $dot))|$prefKey"] = $value
                continue
            }
        }
        $repos[$key] = $value
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $repos.GetEnumerator()) {
        $alias = $entry.Key
        # Path resolution, in order: the <ALIAS>_PATH environment variable (a per-machine override,
        # which always wins) -> the repos.conf value with %VAR% expanded. The override is what lets
        # the same repos.conf work on two machines whose checkouts live in different places, and the
        # expansion is what lets a path be written as %USERPROFILE%\Projects\backend instead of
        # hard-coding one user's name. Without either, a %VAR% in repos.conf silently resolves to a
        # directory that does not exist, and the repo is skipped with no message.
        $envName = ($alias.ToUpper() -replace '[^A-Z0-9]', '_') + '_PATH'
        $envPath = [System.Environment]::GetEnvironmentVariable($envName)
        $path = if ($envPath) { $envPath } else { [System.Environment]::ExpandEnvironmentVariables($entry.Value) }

        $raw = $prefs["$alias|worktree"]
        # Normalized to yes / no / ask. "ask" is also what an absent or unrecognized value means:
        # never assume a default here, or the whole point of asking once is lost.
        $worktree = switch -Regex ("$raw".Trim().ToLower()) {
            '^(yes|y|true|1)$'  { 'yes' }
            '^(no|n|false|0)$'  { 'no' }
            default             { 'ask' }
        }
        $result.Add([pscustomobject]@{
            Alias    = $alias
            Path     = $path
            Worktree = $worktree
        })
    }
    return @($result)
}

function Get-RepoWorktreePreference {
    param(
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$Alias
    )
    $repo = @(Get-Repos -ConfPath $ConfPath | Where-Object { $_.Alias -eq $Alias })
    if ($repo.Count -eq 0) { return $null }   # unknown alias: caller must distinguish this from 'ask'
    return $repo[0].Worktree
}

function Set-RepoWorktreePreference {
    param(
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$Value
    )
    if (-not (Test-Path $ConfPath)) { throw "repos.conf not found: $ConfPath" }
    if (@(Get-Repos -ConfPath $ConfPath | Where-Object { $_.Alias -eq $Alias }).Count -eq 0) {
        throw "Alias '$Alias' is not registered in $ConfPath"
    }

    $prefLine = "$Alias.worktree=$Value"
    $lines    = @(Get-Content $ConfPath -Encoding utf8)
    $replaced = $false
    $out      = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('#')) {
            $idx = $trimmed.IndexOf('=')
            if ($idx -gt 0 -and $trimmed.Substring(0, $idx).Trim().ToLower() -eq "$Alias.worktree".ToLower()) {
                if (-not $replaced) { $out.Add($prefLine); $replaced = $true }
                continue   # drops duplicates of the same preference
            }
        }
        $out.Add($line)
    }
    if (-not $replaced) { $out.Add($prefLine) }

    # Atomic write, same reasoning as active_demands_lib.ps1: repos.conf is hand-edited config, and a
    # process killed mid-write would leave it truncated -- which silently unregisters repositories.
    $text = ($out -join "`r`n") + "`r`n"
    $enc  = New-Object System.Text.UTF8Encoding($false)
    $tmp  = "$ConfPath.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $text, $enc)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            [System.IO.File]::Replace($tmp, $ConfPath, $null)
            return
        } catch {
            Start-Sleep -Milliseconds 80
        }
    }
    [System.IO.File]::WriteAllText($ConfPath, $text, $enc)
    Remove-Item $tmp -Force -EA SilentlyContinue
}
