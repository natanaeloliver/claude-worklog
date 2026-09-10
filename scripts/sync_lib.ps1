<#
.SYNOPSIS
    Which branch the hub synchronizes with, and the refusal to sync from any other one.

    The pull/push pair used to be hardcoded to `origin main` in three places (the inject hook, the
    Stop hook and new-demand.ps1), and that was wrong in two different ways the moment the checkout
    sat anywhere else: `pull --rebase origin main` rebases the CURRENT branch onto origin/main, and
    `push origin main` ships the local `main` ref rather than HEAD -- so the commit the Stop hook had
    just made never left the machine, silently.

    WORKLOG_BRANCH names the branch instead, defaulting to `main`. Whoever develops the tool itself
    points it at a throwaway branch, so that the auto-commits produced while testing never reach the
    public `main`: a Stop hook once pushed a test commit straight to it (29aa332), which is why that
    branch is protected today.

    One guard covers every case: sync only while HEAD IS the configured branch. Any mismatch -- a
    different branch, a branch that does not exist, a detached HEAD -- skips commit, pull and push
    alike. Failing closed is the whole point. Falling back to `main` would reintroduce exactly what
    the variable exists to prevent, and having the hook `checkout` the branch itself would be worse:
    parallel sessions share ONE working tree, so one of them moving HEAD breaks the others mid-turn.
#>

function Get-SyncTarget {
    param([Parameter(Mandatory)][string]$RepoPath)

    $branch = if ($env:WORKLOG_BRANCH) { $env:WORKLOG_BRANCH.Trim() } else { 'main' }
    # --show-current prints nothing on a detached HEAD, which therefore never matches -- deliberate.
    $head = (git -C $RepoPath branch --show-current 2>$null)
    if ($head) { $head = $head.Trim() }

    # -ceq, not -eq: PowerShell compares strings case-insensitively and git does not. On Windows
    # a loose ref resolves either way (NTFS), so WORKLOG_BRANCH='DEV' over a checkout of 'dev'
    # passed the guard and the local commit happened -- and then `pull --rebase origin DEV` failed
    # with "couldn't find remote ref DEV", so the push never ran and the commit stayed on the
    # machine with nothing said. The wrong case must land in the refusal, which is announced.
    return [pscustomobject]@{
        Branch  = $branch
        Head    = $head
        Matches = ($head -ceq $branch)
    }
}
