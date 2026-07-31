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
Copy-Item "$real\scripts\active_demands_lib.ps1" "$sandbox\scripts\"
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
