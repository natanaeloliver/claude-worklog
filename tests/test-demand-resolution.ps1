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
Copy-Item "$real\scripts\session_lib.ps1" "$sandbox\scripts\"
Copy-Item "$real\scripts\sync_lib.ps1" "$sandbox\scripts\"
# new-demand.ps1 scaffolds from the templates folder under $WORKLOG_PATH, so the sandbox needs it.
New-Item -ItemType Directory -Force -Path "$sandbox\templates" | Out-Null
Copy-Item "$real\templates\CONTEXT_template.md" "$sandbox\templates\"
# PROJ-AAAA uses an EM DASH, like the real template ("# Demand {TICKET_ID} - {NAME}" ships with one):
# a plain hyphen here would not catch a mangled dash class in day-report.ps1.
$em = [char]0x2014
Set-Content "$sandbox\worklogs\PROJ-AAAA\CONTEXT.md" "# Demand PROJ-AAAA $em Test demand A`n`nContext for A." -Encoding utf8
Set-Content "$sandbox\worklogs\PROJ-BBBB\CONTEXT.md" "# Demand PROJ-BBBB - Test demand B`n`nContext for B." -Encoding utf8
Set-Content "$sandbox\repos.conf" "# alias=path`n" -Encoding utf8

# The sandbox must be a git repo: the hooks run git config/status/add/commit against the root.
# With no remote configured, pull/push fail and the output is discarded -- what matters here is the
# effect on the state files and on session_log.md.
# -b main pins the branch name: the hooks sync only while HEAD is the branch WORKLOG_BRANCH names,
# whose default is `main`, and `init` alone would follow this machine's init.defaultBranch (often
# `master`) -- which would make every commit check below measure the guard instead of the commit.
Invoke-Git -C $sandbox init -q -b main | Out-Null
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
# C21: session identity is PID *plus* creation instant. Known-bad case: an orphan demand file whose
#      recorded PID belongs to a process that is alive but is NOT claude.exe -- a PID Windows
#      recycled -- with an expired heartbeat. The old check was `Get-Process -Id`, which finds that
#      process and declares the dead session alive forever: its entry never leaves
#      active_demands.txt, the demand is never handed to anyone, and the conflict warning fires for
#      nothing. This test's own powershell.exe is exactly such a live non-claude process.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
$ownCreated = "$((Get-CimInstance Win32_Process -Filter "ProcessId=$PID").CreationDate.Ticks)"
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile '' -Encoding utf8
Set-Content "$sandTmp\claude_demand_sidGhost21.txt" "PROJ-AAAA`n$PID`n$ownCreated" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_active_sidGhost21.flag" -Force | Out-Null
(Get-Item "$sandTmp\claude_active_sidGhost21.flag").LastWriteTime = (Get-Date).AddHours(-3)

Invoke-Hook 'hook_context_inject.ps1' 'sid21b' | Out-Null
Check 'C21 recycled PID declared dead' 'False' ([string](Test-Path "$sandTmp\claude_demand_sidGhost21.txt"))
Check 'C21 its entry pruned'           ''      ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C22: positive control for C21 -- the SAME orphan, the same non-claude PID, but a FRESH heartbeat.
#      It must still count as alive. Without this control, "declare everything dead" would pass C21.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile '' -Encoding utf8
Set-Content "$sandTmp\claude_demand_sidGhost22.txt" "PROJ-AAAA`n$PID`n$ownCreated" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_active_sidGhost22.flag" -Force | Out-Null

Invoke-Hook 'hook_context_inject.ps1' 'sid22' | Out-Null
Check 'C22 fresh heartbeat still alive' 'True'      ([string](Test-Path "$sandTmp\claude_demand_sidGhost22.txt"))
Check 'C22 its entry kept'              'PROJ-AAAA' ((Get-ActiveDemands -Path $activeFile -WorklogsDir "$sandbox\worklogs") -join ',')

# ---------------------------------------------------------------------------
# C23/C24: the Stop hook commits with a per-TURN message, and leaves the sync stamp.
#      C23 -- the message used to say "auto-commit on close" in a hook that fires every turn, and
#      carried a leftover "identify:" instruction. `[TICKET]` must stay: day-report.ps1 groups
#      commits from monitored repos by that token.
#      C24 -- the stamp is what lets the next turn's inject hook skip its own pull. Without it the
#      inject pulls on every single turn, which is the second round trip this removed.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content "$sandTmp\claude_demand_sid23.txt" "PROJ-AAAA`n0`n" -Encoding utf8
Set-Content "$sandbox\worklogs\PROJ-AAAA\scratch23.txt" "work" -Encoding utf8
Invoke-Hook 'hook_session_log.ps1' 'sid23' | Out-Null

$msg23 = (Invoke-Git -C $sandbox log -1 --pretty=%s) -join ''
Check 'C23 message is per-turn'     'True'  ([string]($msg23 -like 'auto-commit for turn `[PROJ-AAAA`]*'))
Check 'C23 no leftover instruction' 'False' ([string]($msg23 -like '*identify:*'))
Check 'C24 sync stamp written'      'True'  ([string](Test-Path "$sandTmp\claude_worklog_sync.stamp"))

# ---------------------------------------------------------------------------
# C25: new-demand.ps1 creates STRUCTURE only. It must not touch last_demand.txt: writing there meant
#      that creating a folder for a new ticket stole the resume point from whoever was working, and
#      the next session without a window reservation came up on the freshly created demand. It must
#      also be non-interactive on an existing demand -- open-parallel.ps1 calls it unattended.
# ---------------------------------------------------------------------------
Set-Content $lastFile 'PROJ-BBBB' -Encoding utf8
# EAP back to Continue around these calls: new-demand.ps1 runs `git pull` in a sandbox with no
# remote, and on PowerShell 5.1 a native command's stderr becomes a terminating ErrorRecord under
# EAP='Stop' -- the same reason Invoke-Git exists at the top of this file.
$eap25 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell.exe -NoProfile -NonInteractive -File "$real\scripts\new-demand.ps1" -ticket 'PROJ-CCCC' -name 'Created by the suite' 2>&1 | Out-Null
Check 'C25 structure created'      'True'      ([string](Test-Path "$sandbox\worklogs\PROJ-CCCC\CONTEXT.md"))
Check 'C25 resume point untouched' 'PROJ-BBBB' (Get-FileText $lastFile)

& powershell.exe -NoProfile -NonInteractive -File "$real\scripts\new-demand.ps1" -ticket 'PROJ-CCCC' -name 'Created by the suite' 2>&1 | Out-Null
Check 'C25 second run is a no-op'  'PROJ-BBBB' (Get-FileText $lastFile)
$ErrorActionPreference = $eap25

# ---------------------------------------------------------------------------
# C26: the hook's stdout must be pure ASCII and valid JSON. ConvertTo-Json on PowerShell 5.1 emits
#      non-ASCII literally, and Write-Output encodes with [Console]::OutputEncoding, which in a fresh
#      terminal window is a legacy OEM code page -- the harness reads it as UTF-8, so every non-ASCII
#      character came through corrupted, silently, until a sequence the decoder could not close
#      turned it into "JSON Parse error: Unterminated string". PROJ-AAAA's H1 carries an em dash on
#      purpose, so this check exercises the real path.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @()
Set-Content $lastFile 'PROJ-AAAA' -Encoding utf8

$out26 = Invoke-Hook 'hook_context_inject.ps1' 'sid26'
Check 'C26 stdout is pure ASCII' 'True' ([string]($out26 -notmatch '[^\x20-\x7E\r\n\t]'))
$parsed26 = $null
try { $parsed26 = $out26 | ConvertFrom-Json } catch { }
Check 'C26 stdout parses as JSON' 'True' ([string]($null -ne $parsed26))
$emDash = [char]0x2014
Check 'C26 em dash reconstructed' 'True' ([string]($null -ne $parsed26 -and $parsed26.hookSpecificOutput.additionalContext.Contains($emDash)))

# ---------------------------------------------------------------------------
# C27: repos_lib resolves paths -- %VAR% expanded, and <ALIAS>_PATH overriding the file. Without the
#      expansion a repos.conf written with %USERPROFILE% silently resolves to a directory that does
#      not exist, and the repository is skipped with no message anywhere.
# ---------------------------------------------------------------------------
$conf27 = "$sandbox\repos27.conf"
Set-Content $conf27 "gamma=%USERPROFILE%\gamma`ndelta=$sandbox\delta`n" -Encoding utf8
$r27 = @(Get-Repos -ConfPath $conf27)
Check 'C27 %VAR% expanded' "$env:USERPROFILE\gamma" (($r27 | Where-Object { $_.Alias -eq 'gamma' }).Path)

$env:DELTA_PATH = "$sandbox\override-delta"
$r27b = @(Get-Repos -ConfPath $conf27)
$env:DELTA_PATH = $null
Check 'C27 <ALIAS>_PATH wins' "$sandbox\override-delta" (($r27b | Where-Object { $_.Alias -eq 'delta' }).Path)

# ---------------------------------------------------------------------------
# C28/C29/C30: WORKLOG_BRANCH -- the hub syncs only while HEAD is the branch it names.
#      Hardcoding `origin main` was wrong in two ways anywhere else: the pull rebased the CURRENT
#      branch onto origin/main, and the push shipped the stale local `main` ref instead of HEAD, so
#      the commit never left the machine. C28 is the mismatch (the variable pointed at a branch that
#      is not checked out): no commit, no sync stamp. C29 is the same refusal with the variable
#      UNSET, which is the pre-existing bug -- a session on a feature branch must not sync either.
#      C30 is the positive control that keeps C28/C29 honest: pointed at the branch actually checked
#      out, the commit happens again, and on that branch.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content "$sandTmp\claude_demand_sid28.txt" "PROJ-AAAA`n0`n" -Encoding utf8
Set-Content "$sandbox\worklogs\PROJ-AAAA\scratch28.txt" "work" -Encoding utf8
$head28 = (Invoke-Git -C $sandbox rev-parse HEAD) -join ''
$env:WORKLOG_BRANCH = 'branch-that-is-not-checked-out'
Invoke-Hook 'hook_session_log.ps1' 'sid28' | Out-Null
Check 'C28 mismatch commits nothing' 'True'  ([string](((Invoke-Git -C $sandbox rev-parse HEAD) -join '') -eq $head28))
Check 'C28 no sync stamp'            'False' ([string](Test-Path "$sandTmp\claude_worklog_sync.stamp"))
$env:WORKLOG_BRANCH = $null

Invoke-Git -C $sandbox checkout -q -b side29 | Out-Null
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content "$sandTmp\claude_demand_sid29.txt" "PROJ-AAAA`n0`n" -Encoding utf8
$head29 = (Invoke-Git -C $sandbox rev-parse HEAD) -join ''
Invoke-Hook 'hook_session_log.ps1' 'sid29' | Out-Null
Check 'C29 default target refuses another branch' 'True' ([string](((Invoke-Git -C $sandbox rev-parse HEAD) -join '') -eq $head29))

$env:WORKLOG_BRANCH = 'side29'
Invoke-Hook 'hook_session_log.ps1' 'sid29' | Out-Null
Check 'C30 configured branch commits' 'True'   ([string](((Invoke-Git -C $sandbox rev-parse HEAD) -join '') -ne $head29))
Check 'C30 commit landed there'       'side29' ((Invoke-Git -C $sandbox branch --show-current) -join '')
$env:WORKLOG_BRANCH = $null
Invoke-Git -C $sandbox checkout -q main | Out-Null

# ---------------------------------------------------------------------------
# C31: the refusal is ANNOUNCED. A guard that silently stops committing is the failure mode it was
#      meant to prevent, only quieter: the session would work a whole day and push nothing. The
#      inject hook carries the notice in the same slot as the parallel-session conflict warning,
#      which is first-message-only -- the right granularity, since the answer does not change
#      mid-session. Paired with the control: with the variable unset there must be no warning at
#      all, or the notice would become noise nobody reads.
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @()
Set-Content $lastFile 'PROJ-AAAA' -Encoding utf8
$env:WORKLOG_BRANCH = 'branch-that-is-not-checked-out'
$out31 = Invoke-Hook 'hook_context_inject.ps1' 'sid31'
$env:WORKLOG_BRANCH = $null
Check 'C31 sync-off warning injected' 'True' ([string]($out31 -like '*worklog sync is OFF*'))

Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content $lastFile 'PROJ-AAAA' -Encoding utf8
$out31b = Invoke-Hook 'hook_context_inject.ps1' 'sid31b'
Check 'C31 silent when branches match' 'False' ([string]($out31b -like '*worklog sync is OFF*'))

# ---------------------------------------------------------------------------
# C32: adding a ticket to an active_demands.txt that holds exactly ONE must leave TWO lines.
#      Get-ActiveDemands returns @(...), but PowerShell unwraps a single-element array on return,
#      so with one ticket in the file the caller got a String and `+` concatenated TEXT:
#      "PROJ-AAAAPROJ-BBBB" on one line. Read RAW here, never through Get-ActiveDemands -- the
#      self-healing read splits the blob back apart and would report success over a corrupt file,
#      which is exactly why this went unnoticed until two live sessions hit it (2026-09-10).
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-ActiveDemands -Path $activeFile -Tickets @('PROJ-AAAA')
Set-Content $lastFile 'PROJ-BBBB' -Encoding utf8
Set-Content "$sandTmp\claude_demand_sidGhost32.txt" "PROJ-AAAA`n$PID`n$ownCreated" -Encoding utf8
New-Item -ItemType File -Path "$sandTmp\claude_active_sidGhost32.flag" -Force | Out-Null

Invoke-Hook 'hook_context_inject.ps1' 'sid32' | Out-Null

# Bounded retry, and the BOM comes off before comparing. Two separate reasons:
#   1. The FIRST read right after the hook can still return the pre-write content. File.Replace
#      is atomic -- no torn file ever -- but cross-process visibility of the replaced content is
#      not instantaneous here: measured 3 runs out of 3 reading the stale content, and 3 out of 3
#      reading the new one with a 300ms sleep or with a single discarded read in front
#      (2026-09-10). Waiting cannot hide the defect this case exists for: with the tickets glued
#      the file stays at ONE line forever, so the loop only stops measuring the wrong instant.
#   2. Set-ActiveDemands writes UTF8 WITH BOM, so the first entry reads as "<BOM>PROJ-AAAA".
#      Untrimmed, the glued form arrives as "<BOM>PROJ-AAAAPROJ-BBBB" and `-contains` never
#      matches -- the second check would pass over a corrupt file, which is the one thing it is
#      here to catch.
$raw32 = @()
for ($i = 0; $i -lt 20; $i++) {
    $raw32 = @(([System.IO.File]::ReadAllText($activeFile) -split "\r?\n") |
        ForEach-Object { $_.Trim([char]0xFEFF).Trim() } | Where-Object { $_ })
    if ($raw32.Count -ge 2) { break }
    Start-Sleep -Milliseconds 50
}
Check 'C32 two separate lines' '2'     ([string]$raw32.Count)
Check 'C32 nothing glued'      'False' ([string]($raw32 -contains 'PROJ-AAAAPROJ-BBBB'))

# ---------------------------------------------------------------------------
# C33: the branch comparison is CASE-SENSITIVE, because git is and PowerShell's -eq is not.
#      WORKLOG_BRANCH='MAIN' over a checkout of 'main' used to pass the guard: the commit was made
#      locally and then `pull --rebase origin MAIN` failed ("couldn't find remote ref MAIN"), so the
#      push never ran. A commit stuck on one machine with no message is worse than a refusal, which
#      at least announces itself. Paired with the exact-case control right after it, so the fix
#      cannot be "refuse everything".
# ---------------------------------------------------------------------------
Remove-Item "$sandTmp\claude_*" -Force -EA SilentlyContinue
Set-Content "$sandTmp\claude_demand_sid33.txt" "PROJ-AAAA`n0`n" -Encoding utf8
Set-Content "$sandbox\worklogs\PROJ-AAAA\scratch33.txt" "work" -Encoding utf8
$head33 = (Invoke-Git -C $sandbox rev-parse HEAD) -join ''

$env:WORKLOG_BRANCH = 'MAIN'
Invoke-Hook 'hook_session_log.ps1' 'sid33' | Out-Null
Check 'C33 wrong case commits nothing' 'True' ([string](((Invoke-Git -C $sandbox rev-parse HEAD) -join '') -eq $head33))

$env:WORKLOG_BRANCH = 'main'
Invoke-Hook 'hook_session_log.ps1' 'sid33' | Out-Null
Check 'C33 exact case commits'        'True' ([string](((Invoke-Git -C $sandbox rev-parse HEAD) -join '') -ne $head33))
$env:WORKLOG_BRANCH = $null

# ---------------------------------------------------------------------------
$env:WORKLOG_PATH = $null
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
# Failures also as a list: Format-Table truncates Expected/Actual to the console width, and when
# the output is redirected to a file that width is 120 -- which hid exactly the columns needed to
# tell what went wrong.
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "--- FAILURES ---" -ForegroundColor Red
    $failed | Format-List Case, Expected, Actual
}
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL $($results.Count) CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failed.Count) OF $($results.Count) CHECKS FAILED" -ForegroundColor Red
    exit 1
}
