# Isolated test for demand resolution, session-log attribution and active_demands.txt handling.
# Full isolation: WORKLOG_PATH and TEMP point at a throwaway sandbox, so nothing touches real state
# (active_demands.txt / last_demand.txt / the FIFO queue on this machine).
#
# Usage: powershell -NoProfile -File tests/test-demand-resolution.ps1

$ErrorActionPreference = 'Stop'

# On PowerShell 5.1 a native executable's stderr becomes an ErrorRecord, and with EAP='Stop' that
# aborts the script -- git writes routine warnings to stderr (CRLF conversion, "no commits yet").
# Every git call in this test goes through here.
function Invoke-Git {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& git @args 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) }
    finally { $ErrorActionPreference = $eap }
}

$real    = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path $env:TEMP 'claude_worklog_test_sandbox'   # $env:TEMP captured BEFORE being overridden
$sandTmp = Join-Path $sandbox 'tmp'

if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$sandbox\scripts", "$sandbox\worklogs\PROJ-AAAA", "$sandbox\worklogs\PROJ-BBBB", $sandTmp | Out-Null
# The hooks dot-source the libs from $WORKLOG_PATH\scripts\, so the sandbox needs them too.
Copy-Item "$real\scripts\active_demands_lib.ps1" "$sandbox\scripts\"
Copy-Item "$real\scripts\repos_lib.ps1" "$sandbox\scripts\"
# PROJ-AAAA uses an EM DASH, like the real template ("# Demand {TICKET_ID} - {NAME}" ships with one):
# a plain hyphen here would not catch a mangled dash class in day-report.ps1.
$em = [char]0x2014
Set-Content "$sandbox\worklogs\PROJ-AAAA\CONTEXT.md" "# Demand PROJ-AAAA $em Test demand A`n`nContext for A." -Encoding utf8
Set-Content "$sandbox\worklogs\PROJ-BBBB\CONTEXT.md" "# Demand PROJ-BBBB - Test demand B`n`nContext for B." -Encoding utf8
Set-Content "$sandbox\repos.conf" "# alias=path`n" -Encoding utf8

# The sandbox must be a git repo: the hooks run git config/status/add/commit against the root.
# With no remote configured, pull/push fail and the output is discarded -- what matters here is the
# effect on the state files and on session_log.md.
Invoke-Git -C $sandbox init -q | Out-Null
Invoke-Git -C $sandbox config user.email "test@local" | Out-Null
Invoke-Git -C $sandbox config user.name "test" | Out-Null
Invoke-Git -C $sandbox add -A | Out-Null
Invoke-Git -C $sandbox commit -qm "base" | Out-Null

$env:WORKLOG_PATH = $sandbox
$env:TEMP = $sandTmp
$env:TMP  = $sandTmp
# Inherited by every child hook: a leftover token would hand a reservation to checks that must not
# have one. C17 sets it deliberately and clears it right after.
$env:WORKLOG_DEMAND_TOKEN = $null

# -NoProfile is MANDATORY in the child calls: -NonInteractive does not stop the profile from
# loading, and a user profile may define WORKLOG_PATH -- without -NoProfile the child hook would run
# against the REAL repository. Safety guard: abort if the sandbox is not actually isolated.
$sanity = & powershell.exe -NoProfile -NonInteractive -Command '$env:WORKLOG_PATH'
if ($sanity.Trim() -ne $sandbox) { throw "Sandbox not isolated: child sees '$($sanity.Trim())'" }

$results = [System.Collections.Generic.List[object]]::new()
function Check {
    param([string]$Case, [string]$Expected, [string]$Actual)
    $results.Add([pscustomobject]@{ Case = $Case; Expected = $Expected; Actual = $Actual; Status = if ($Expected -eq $Actual) { 'PASS' } else { 'FAIL' } })
}
function Invoke-Hook {
    param([string]$Script, [string]$Sid)
    $json = (@{ session_id = $Sid; reason = 'prompt_input_exit' } | ConvertTo-Json -Compress)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $json | powershell.exe -NoProfile -NonInteractive -File "$real\hooks\windows\$Script" 2>&1
    } finally { $ErrorActionPreference = $eap }
    return ((@($out) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n")
}
function Get-FileText {
    param([string]$P)
    if (-not (Test-Path $P)) { return '<missing>' }
    $raw = Get-Content $P -Raw -Encoding utf8 -EA SilentlyContinue   # empty file -> $null
    if ($null -eq $raw) { return '' }
    return $raw.Trim()
}

$activeFile = "$sandbox\active_demands.txt"
$lastFile   = "$sandbox\last_demand.txt"
$today      = Get-Date -Format 'yyyy-MM-dd'

# ---------------------------------------------------------------------------
# C1: SessionEnd of the LAST session of the day -> clears active_demands AND writes last_demand
# ---------------------------------------------------------------------------
Set-Content $activeFile "PROJ-AAAA" -Encoding utf8
Set-Content "$sandTmp\claude_demand_sid1.txt" "PROJ-AAAA`n0" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_ctx_sid1.marker" -Force | Out-Null
New-Item -ItemType File -Path "$sandTmp\claude_active_sid1.flag" -Force | Out-Null

Invoke-Hook 'hook_session_end.ps1' 'sid1' | Out-Null

Check 'C1 active_demands cleared'      ''           (Get-FileText $activeFile)
Check 'C1 last_demand written'         'PROJ-AAAA'  (Get-FileText $lastFile)
Check 'C1 demand file removed'         'False'      ([string](Test-Path "$sandTmp\claude_demand_sid1.txt"))
Check 'C1 marker removed'              'False'      ([string](Test-Path "$sandTmp\claude_ctx_sid1.marker"))

# ---------------------------------------------------------------------------
# C2: next session -- everything empty except last_demand -> injects PROJ-AAAA
#     (this is exactly the reported bug; before last_demand.txt the result was stand-by)
# ---------------------------------------------------------------------------
$out2 = Invoke-Hook 'hook_context_inject.ps1' 'sid2'
$injected2 = if ($out2 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }

Check 'C2 injected the last demand'    'PROJ-AAAA' $injected2
Check 'C2 session demand file created' 'PROJ-AAAA' ((Get-FileText "$sandTmp\claude_demand_sid2.txt") -split "`n")[0]
Check 'C2 back in active_demands'      'PROJ-AAAA' (Get-FileText $activeFile)
Check 'C2 last_demand preserved'       'PROJ-AAAA' (Get-FileText $lastFile)

# ---------------------------------------------------------------------------
# C3: claim guard -- last_demand already open in another LIVE session
#     (this process's PID is genuinely alive). Expected: stand-by, not a duplicate.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content $activeFile '' -Encoding utf8
Set-Content $lastFile "PROJ-BBBB" -Encoding utf8
Set-Content "$sandTmp\claude_demand_sidLive.txt" "PROJ-BBBB`n$PID" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_active_sidLive.flag" -Force | Out-Null

$out3 = Invoke-Hook 'hook_context_inject.ps1' 'sid3'
$injected3 = if ($out3 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C3 did not duplicate live demand' '<stand-by>' $injected3

# ---------------------------------------------------------------------------
# C4: Stop hook with NO demand file must not infer the demand from shared state.
#     last_demand populated + no session -> no commit may be created.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content $lastFile "PROJ-AAAA" -Encoding utf8
Set-Content "$sandbox\scratch.txt" "some content" -Encoding utf8
$commitsBefore = [string](@(Invoke-Git -C $sandbox log --oneline).Count)
Invoke-Hook 'hook_session_log.ps1' 'sid4' | Out-Null
$commitsAfter = [string](@(Invoke-Git -C $sandbox log --oneline).Count)
Check 'C4 Stop without demand did not commit' $commitsBefore $commitsAfter

# ---------------------------------------------------------------------------
# C5: standby.ps1 clears the resume point (explicit stand-by wins)
# ---------------------------------------------------------------------------
Set-Content $activeFile "PROJ-AAAA" -Encoding utf8
Set-Content $lastFile "PROJ-AAAA" -Encoding utf8
Set-Content "$sandTmp\claude_demand_sid5.txt" "PROJ-AAAA`n0" -Encoding utf8
& powershell.exe -NoProfile -NonInteractive -File "$real\scripts\standby.ps1" -sessionId 'sid5' 2>$null | Out-Null
Check 'C5 last_demand cleared by standby' '' (Get-FileText $lastFile)
Check 'C5 removed from active_demands'    '' (Get-FileText $activeFile)

# ---------------------------------------------------------------------------
# C6: current_demand.txt is retired -- recreating the old file must not influence anything
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content $activeFile '' -Encoding utf8
Set-Content $lastFile '' -Encoding utf8
Set-Content "$sandbox\current_demand.txt" "PROJ-BBBB" -Encoding utf8
$out6 = Invoke-Hook 'hook_context_inject.ps1' 'sid6'
$injected6 = if ($out6 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C6 current_demand.txt ignored'     '<stand-by>' $injected6
Remove-Item "$sandbox\current_demand.txt" -Force

# ---------------------------------------------------------------------------
# C7: the Stop hook does NOT create a day section. With an existing session_log but no
#     "## <date> <user>" section, nothing may be written -- not even "(no description)".
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
$logAAAA = "$sandbox\worklogs\PROJ-AAAA\session_log.md"
Set-Content $logAAAA "# PROJ-AAAA`r`n`r`n## 2020-01-01 someone.else`r`n`r`nold session.`r`n" -Encoding utf8
Set-Content "$sandTmp\claude_demand_sid7.txt" "PROJ-AAAA`n0" -Encoding utf8

# Fake worktree of the demand, with 1 modified and 1 new file (triggers the String+String bug)
$fakeWt = "$sandbox\worklogs\PROJ-AAAA\fake-repo"
New-Item -ItemType Directory -Force -Path $fakeWt | Out-Null
Invoke-Git -C $fakeWt init -q | Out-Null
Invoke-Git -C $fakeWt config user.email "t@t" | Out-Null
Invoke-Git -C $fakeWt config user.name "t" | Out-Null
Set-Content "$fakeWt\one.md" "content" -Encoding utf8
Invoke-Git -C $fakeWt add -A | Out-Null
Invoke-Git -C $fakeWt commit -qm "base" | Out-Null
Add-Content "$fakeWt\one.md" "changed" -Encoding utf8      # 1 modified -> git returns a String
Set-Content "$fakeWt\two.md" "new" -Encoding utf8          # 1 untracked -> git returns a String

$before7 = Get-FileText $logAAAA
Invoke-Hook 'hook_session_log.ps1' 'sid7' | Out-Null
$after7 = Get-FileText $logAAAA
Check 'C7 log unchanged without day section' $before7 $after7
Check 'C7 did not create (no description)'   'False' ([string]($after7 -match 'no description'))

# ---------------------------------------------------------------------------
# C8: with the day section present the block is written -- and BOTH files appear on separate
#     lines (regression for the String + String text-concatenation bug).
# ---------------------------------------------------------------------------
Add-Content $logAAAA "`r`n## $today test`r`n`r`ntoday's session.`r`n" -Encoding utf8
Invoke-Hook 'hook_session_log.ps1' 'sid7' | Out-Null

$lines8 = @(Get-Content $logAAAA -Encoding utf8)
$block8 = @($lines8 | Where-Object { $_ -match '^- \[fake-repo\]' })
Check 'C8 block written in the day section' 'True'  ([string](@($lines8 | Where-Object { $_ -match '^Uncommitted files' }).Count -gt 0))
Check 'C8 two files on two lines'           '2'     ([string]$block8.Count)
Check 'C8 no glued filenames'               'False' ([string](($block8 -join '') -match 'one\.md\S*two'))

# ---------------------------------------------------------------------------
# C9: a monitored repo on ANOTHER demand's branch is not attributed to this one
# ---------------------------------------------------------------------------
$otherRepo = "$sandbox\other-demand-repo"
New-Item -ItemType Directory -Force -Path $otherRepo | Out-Null
Invoke-Git -C $otherRepo init -q | Out-Null
Invoke-Git -C $otherRepo config user.email "t@t" | Out-Null
Invoke-Git -C $otherRepo config user.name "t" | Out-Null
Set-Content "$otherRepo\x.md" "a" -Encoding utf8
Invoke-Git -C $otherRepo add -A | Out-Null
Invoke-Git -C $otherRepo commit -qm "base" | Out-Null
Invoke-Git -C $otherRepo checkout -qb "test/PROJ-BBBB" | Out-Null
Set-Content "$otherRepo\pollution.md" "should not show up" -Encoding utf8
Set-Content "$sandbox\repos.conf" "other=$otherRepo`n" -Encoding utf8

Invoke-Hook 'hook_session_log.ps1' 'sid7' | Out-Null
Check 'C9 other demand branch ignored' 'False' ([string]((Get-FileText $logAAAA) -match 'pollution'))

# ---------------------------------------------------------------------------
# C10: active_demands_lib -- self-healing read of the glued blob and atomic one-per-line write
# ---------------------------------------------------------------------------
. "$real\scripts\active_demands_lib.ps1"
[System.IO.File]::WriteAllText($activeFile, "PROJ-AAAAPROJ-BBBB`r`n")
$read = Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs"
Check 'C10 blob split into 2 tickets'  'PROJ-AAAA,PROJ-BBBB' (@($read) -join ',')

Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA', 'PROJ-BBBB', 'PROJ-BBBB')
$rawC10 = [System.IO.File]::ReadAllText($activeFile)
Check 'C10 written with line breaks'   'True' ([string]($rawC10 -match "PROJ-AAAA\r\nPROJ-BBBB\r\n$"))
Check 'C10 duplicate dropped'          'PROJ-AAAA,PROJ-BBBB' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C11: an entry with no demand file is residue from a session that died without SessionEnd and must
#      be pruned; a reservation still in the FIFO queue must survive.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content $lastFile '' -Encoding utf8
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA', 'PROJ-BBBB')
Set-Content "$sandTmp\claude_pending_open.txt" "PROJ-BBBB" -Encoding utf8   # BBBB reserved, AAAA orphan

$out11 = Invoke-Hook 'hook_context_inject.ps1' 'sid11'
$injected11 = if ($out11 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C11 consumed the queued reservation' 'PROJ-BBBB' $injected11
Check 'C11 orphan pruned, reservation kept' 'PROJ-BBBB' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C12: day-report renders the demand title from CONTEXT.md without eating it at the ticket's hyphen
# ---------------------------------------------------------------------------
$out12 = & powershell.exe -NoProfile -NonInteractive -File "$real\scripts\day-report.ps1" 2>$null
$titleLine = @($out12 | Where-Object { $_ -match '^\[PROJ-AAAA' })
Check 'C12 full title rendered' 'True' ([string](@($titleLine | Where-Object { $_ -match 'Test demand A' }).Count -gt 0))

# ---------------------------------------------------------------------------
# C13: repos_lib -- per-repository worktree preference. Absent means 'ask' (never a default), the
#      value round-trips, a rewrite replaces instead of duplicating, and an old-format repos.conf
#      with no preference lines still parses.
# ---------------------------------------------------------------------------
. "$real\scripts\repos_lib.ps1"
$conf = "$sandbox\repos.conf"
Set-Content $conf "# comment`nalpha=$sandbox\alpha`nbeta=$sandbox\beta`n" -Encoding utf8

$parsed = @(Get-Repos -ConfPath $conf)
Check 'C13 old format still parses'     'alpha,beta' (($parsed | ForEach-Object { $_.Alias }) -join ',')
Check 'C13 absent preference is ask'    'ask,ask'    (($parsed | ForEach-Object { $_.Worktree }) -join ',')

Set-RepoWorktreePreference -ConfPath $conf -Alias 'alpha' -Value 'no'
Check 'C13 preference recorded'         'no'  (Get-RepoWorktreePreference -ConfPath $conf -Alias 'alpha')
Check 'C13 other repo untouched'        'ask' (Get-RepoWorktreePreference -ConfPath $conf -Alias 'beta')

Set-RepoWorktreePreference -ConfPath $conf -Alias 'alpha' -Value 'yes'
$prefLines = @(Get-Content $conf | Where-Object { $_ -match '^alpha\.worktree=' })
Check 'C13 rewrite replaces, no dupe'   '1'   ([string]$prefLines.Count)
Check 'C13 new value read back'         'yes' (Get-RepoWorktreePreference -ConfPath $conf -Alias 'alpha')
Check 'C13 paths preserved'             "$sandbox\alpha" (@(Get-Repos -ConfPath $conf | Where-Object { $_.Alias -eq 'alpha' })[0].Path)
Check 'C13 comment preserved'           'True' ([string](@(Get-Content $conf | Where-Object { $_ -eq '# comment' }).Count -eq 1))

# Unknown alias must be distinguishable from 'ask', and must not be silently registered
Check 'C13 unknown alias returns null'  'True' ([string]($null -eq (Get-RepoWorktreePreference -ConfPath $conf -Alias 'nope')))
$threw = $false
try { Set-RepoWorktreePreference -ConfPath $conf -Alias 'nope' -Value 'yes' } catch { $threw = $true }
Check 'C13 refuses unknown alias'       'True' ([string]$threw)

# ---------------------------------------------------------------------------
# C14: the Stop hook keeps attributing by branch after the repos.conf refactor (a repo on this
#      demand's branch is logged; the preference is not a filter on evidence).
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Remove-Item $fakeWt -Recurse -Force -EA SilentlyContinue     # isolate: only the branch evidence left
Invoke-Git -C $otherRepo checkout -q -b "test/PROJ-AAAA" | Out-Null
Set-Content "$otherRepo\on-branch.md" "belongs to AAAA" -Encoding utf8
Set-Content $conf "other=$otherRepo`nother.worktree=no`n" -Encoding utf8
Set-Content "$sandTmp\claude_demand_sid14.txt" "PROJ-AAAA`n0" -Encoding utf8

Invoke-Hook 'hook_session_log.ps1' 'sid14' | Out-Null
Check 'C14 branch evidence still logged' 'True' ([string]((Get-FileText $logAAAA) -match 'on-branch\.md'))

# ---------------------------------------------------------------------------
# C15: the state cleanup runs BEFORE demand resolution. Known-bad case: active_demands.txt holds
#      residue from a session that died without SessionEnd (no demand file at all) and the resume
#      point names a different demand. While the prune ran after resolution, fallback 3 handed the
#      residue over, and the prune then saw the fresh demand file and kept the entry as legitimate --
#      the one session the cleanup never fixed was the one that inherited the residue.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile "PROJ-BBBB" -Encoding utf8

$out15 = Invoke-Hook 'hook_context_inject.ps1' 'sid15'
$injected15 = if ($out15 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C15 residue not handed over'   'PROJ-BBBB' $injected15
Check 'C15 residue pruned before use' 'PROJ-BBBB' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C16: negative control for the prune -- an entry backed by a LIVE session must survive it (and
#      still must not be handed to the new session). Without this, "prune everything" would pass C15.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile '' -Encoding utf8
Set-Content "$sandTmp\claude_demand_sidLive16.txt" "PROJ-AAAA`n$PID" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_active_sidLive16.flag" -Force | Out-Null

$out16 = Invoke-Hook 'hook_context_inject.ps1' 'sid16'
$injected16 = if ($out16 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C16 live entry not handed over' '<stand-by>' $injected16
Check 'C16 live entry survives prune'  'PROJ-AAAA'  ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C17: reservation bound to the window. Known-bad case: two reservations made back-to-back and the
#      window that types first is the SECOND one -- which is the normal case, since a new terminal
#      window comes to the front. The FIFO pop returned the FIRST ticket there, swapping the two
#      windows systematically. With the token each window gets its own, and the reservation file is
#      consumed exactly once so a later `claude` in the same window does not silently reopen it.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA', 'PROJ-BBBB')
Set-Content $lastFile '' -Encoding utf8
$noBom  = New-Object System.Text.UTF8Encoding $false
$resvA  = "$sandTmp\claude_reserva_tokenA.txt"
$resvB  = "$sandTmp\claude_reserva_tokenB.txt"
[System.IO.File]::WriteAllText($resvA, 'PROJ-AAAA', $noBom)   # first window opened
[System.IO.File]::WriteAllText($resvB, 'PROJ-BBBB', $noBom)   # second window opened, types first

$env:WORKLOG_DEMAND_TOKEN = 'tokenB'
$out17 = Invoke-Hook 'hook_context_inject.ps1' 'sid17'
$env:WORKLOG_DEMAND_TOKEN = $null
$injected17 = if ($out17 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C17 window got its own ticket'    'PROJ-BBBB' $injected17
Check 'C17 own reservation consumed'     'False'     ([string](Test-Path $resvB))
Check 'C17 other reservation untouched'  'True'      ([string](Test-Path $resvA))

# ---------------------------------------------------------------------------
# C18: negative control for the reservation -- a session with NO token (a `claude` opened by hand)
#      must not walk off with a reservation made for another window, must not prune it from
#      active_demands.txt either, and must land in stand-by rather than duplicating the demand.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile '' -Encoding utf8
$resvC = "$sandTmp\claude_reserva_tokenC.txt"
[System.IO.File]::WriteAllText($resvC, 'PROJ-AAAA', $noBom)

$out18 = Invoke-Hook 'hook_context_inject.ps1' 'sid18'
$injected18 = if ($out18 -match 'ACTIVE DEMAND: (PROJ-\w+)') { $Matches[1] } else { '<stand-by>' }
Check 'C18 reserved ticket not handed to a stranger' '<stand-by>' $injected18
Check 'C18 reservation survives'                     'True'       ([string](Test-Path $resvC))
Check 'C18 reserved entry kept in active_demands'    'PROJ-AAAA'  ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C19: the cleanup no longer rides on the re-injection guard. On a LATER turn of the same session
#      (fresh marker) residue must still be pruned, and nothing may be re-injected. Negative control
#      at the end: with a fresh cleanup stamp the grace period must SKIP the work, otherwise every
#      turn of every parallel session would serialize on the global mutex.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @()
Set-Content $lastFile "PROJ-AAAA" -Encoding utf8
Invoke-Hook 'hook_context_inject.ps1' 'sid19' | Out-Null      # first message: marker created

Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA', 'PROJ-BBBB')   # PROJ-BBBB = residue
Remove-Item "$sandTmp\claude_cleanup.stamp" -Force -EA SilentlyContinue
$out19 = Invoke-Hook 'hook_context_inject.ps1' 'sid19'
Check 'C19 later turn injects nothing' ''           $out19
Check 'C19 later turn still prunes'    'PROJ-AAAA'  ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA', 'PROJ-BBBB')
Set-Content "$sandTmp\claude_cleanup.stamp" -Value (Get-Date -Format 'o') -Encoding utf8
Invoke-Hook 'hook_context_inject.ps1' 'sid19' | Out-Null
Check 'C19 grace period skips the work' 'PROJ-AAAA,PROJ-BBBB' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C20: TTL on reservations. A window that never sent its first message (user closed it, or `wt`
#      failed) leaves a reservation behind, and the prune preserves whatever is reserved -- so
#      without a TTL that ticket would sit in active_demands.txt forever. Known-bad case: a
#      reservation older than 24h. Negative control right after: the same setup one hour old, which
#      must survive, otherwise "always expire" would pass the first half.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile '' -Encoding utf8
$resvOld = "$sandTmp\claude_reserva_tokenOld.txt"
[System.IO.File]::WriteAllText($resvOld, 'PROJ-AAAA', $noBom)
(Get-Item $resvOld).LastWriteTime = (Get-Date).AddHours(-25)

Invoke-Hook 'hook_context_inject.ps1' 'sid20' | Out-Null
Check 'C20 stale reservation dropped' 'False' ([string](Test-Path $resvOld))
Check 'C20 its entry pruned too'      ''      ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
$resvNew = "$sandTmp\claude_reserva_tokenNew.txt"
[System.IO.File]::WriteAllText($resvNew, 'PROJ-AAAA', $noBom)
(Get-Item $resvNew).LastWriteTime = (Get-Date).AddHours(-1)

Invoke-Hook 'hook_context_inject.ps1' 'sid21' | Out-Null
Check 'C20 fresh reservation survives' 'True'      ([string](Test-Path $resvNew))
Check 'C20 its entry kept'             'PROJ-AAAA' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
$env:WORKLOG_PATH = $null
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL $($results.Count) CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failed.Count) OF $($results.Count) CHECKS FAILED" -ForegroundColor Red
    exit 1
}
