# claude-worklog

A session context hub for Claude Code — automatically injects demand context, logs sessions,
and tracks work across multiple repositories.

## The Problem

When working with Claude Code across multiple repositories, context resets every session.
You spend the first few minutes re-explaining what you're working on, what was done last
session, and what the next steps are. In a multi-repo team (e.g., backend + frontend +
data pipeline), this adds up fast.

## The Solution

`claude-worklog` is a central hub that:

- **Injects context automatically** — the `UserPromptSubmit` hook injects the active
  demand's `CONTEXT.md` at the start of every session, so Claude knows exactly where you
  left off
- **Logs sessions automatically** — the `Stop` hook records the demand's uncommitted files in
  an audit trail and syncs git, once per turn
- **Tracks demands as structured files** — each demand has a `CONTEXT.md` (current state)
  and `session_log.md` (audit trail), committed to a shared git repository
- **Supports parallel sessions** — multiple team members can work simultaneously on
  different demands without conflicts

## How It Works

```
claude-worklog (this repo)
    │
    ├── worklogs/TICKET-123/CONTEXT.md     ← Claude reads at session start
    └── worklogs/TICKET-123/session_log.md ← hooks write during the session

UserPromptSubmit hook (fires on first message)
    └── resolves the demand → injects CONTEXT.md as context into the session

Stop hook (fires once per turn)
    └── records this demand's uncommitted files in session_log.md → git sync

SessionEnd hook (fires once, at the true /exit)
    └── clears session state → writes last_demand.txt (the resume point)
```

### Demand resolution order

The inject hook resolves which demand belongs to the session, in this order:

1. the session's own demand file (survives restarting Claude in the same tab)
2. the reservation bound to this window, made by `open-parallel.ps1` (see [Parallel
   Sessions](#parallel-sessions)), consumed once and then gone
3. the legacy FIFO queue, kept only to drain a reservation still in flight from an older version;
   nothing writes to it any more
4. `active_demands.txt` — first ticket that is neither claimed by another live session nor reserved
   for a window that has not sent its first message yet
5. `last_demand.txt` — the resume point, if it is not already open elsewhere

Step 5 is what makes the first session of the day open with context instead of stand-by:
`active_demands.txt` is ephemeral by design ("who has a live session right now"), so without a
separate resume point, ending the last session erased every trace of the demand.

Before resolving, the hook cleans up state left behind by sessions that ended without `SessionEnd`:
orphan demand files, reservations older than 24h, and `active_demands.txt` entries with no session
behind them at all. It runs **before** resolution on purpose. Running it afterwards fixed the file
for the sessions that came next and never for the one that had just been handed the residue.

### Which work gets logged (attribution by evidence)

The `Stop` hook only records uncommitted files it can prove belong to the active demand:

- a git worktree under `worklogs/<TICKET>/`, or
- a monitored repo whose current branch is `<TICKET>` or ends with `/<TICKET>`

A monitored repo sitting on `main` or on another demand's branch is not recorded. This matters with
parallel sessions: those working trees are shared, so a global scan credited one demand's work to
another and corrupted the audit trail. The trade-off is explicit — **if you work without a
per-demand branch or worktree, no uncommitted-files block is written**. The hook also never creates
the day's section in `session_log.md`; that section is the record of what was done, written by you,
and `day-report.ps1` flags demands that have commits but no entry.

### Worktree per demand is optional, per repository

Using a git worktree per demand lets you work on several demands in parallel without stashing, and
keeps the main copy on a stable branch. But a fresh worktree is an empty working directory:
everything git does not track has to be rebuilt there — dependencies, local `.env` files, generated
clients, seeded local databases. For a small repository that costs seconds; for an application
repository it is a full reinstall and reconfiguration on every demand, which is rework.

So the choice belongs to each repository. Claude asks once, the first time it needs to change a given
repository for a demand, and records the answer in `repos.conf`:

```powershell
.\scripts\repo-worktree.ps1                        # list every repo and its preference
.\scripts\repo-worktree.ps1 -Alias backend         # -> yes | no | ask
.\scripts\repo-worktree.ps1 -Alias backend -Use no # record it (stops the question repeating)
```

`ask` means not answered yet. `no` means work happens in the main copy on a branch named after the
demand — which the `Stop` hook recognizes as evidence just as well as a worktree, so the audit trail
works either way.

## Quick Start

**Prerequisites:** [Claude Code](https://code.claude.com), PowerShell 5.1+, Git

**1. Clone and run setup:**
```powershell
git clone https://github.com/natanaeloliver/claude-worklog.git
cd claude-worklog
.\setup.ps1
```

**2. Restart your terminal** to load `WORKLOG_PATH`, then configure your repositories:
```powershell
# Edit repos.conf and add your project repos (see repos.conf.example)
code repos.conf
```

**3. Create your first demand:**
```powershell
.\scripts\new-demand.ps1 -ticket "PROJ-001" -name "My first demand"
```

**4. Open Claude** inside this directory (the hub) — not inside your other repos:
```powershell
cd C:\path\to\claude-worklog
claude
```

Claude will automatically read the demand context, and reaches your other repositories via
absolute paths (from `repos.conf`) using its normal Read/Edit/Bash tools — no need to `cd`
into them yourself. See [Optional: multi-repo direct mode](#optional-multi-repo-direct-mode)
if you'd rather open Claude directly inside each repo instead.

## Repository Structure

```
claude-worklog/
├── hooks/
│   ├── windows/
│   │   ├── hook_context_inject.ps1   # UserPromptSubmit hook
│   │   └── hook_session_log.ps1      # Stop hook
│   └── bash/                         # Bash hooks (PRs welcome)
├── scripts/
│   ├── new-demand.ps1                # Create a new demand
│   ├── switch-demand.ps1             # Switch active demand mid-session
│   ├── open-parallel.ps1             # Open parallel session in new window
│   ├── standby.ps1                   # Clear active demand
│   ├── day-report.ps1                # Daily activity summary
│   ├── repo-worktree.ps1             # Per-repo worktree preference (asked once)
│   ├── active_demands_lib.ps1        # Shared state read/write (self-healing + atomic)
│   └── repos_lib.ps1                 # repos.conf read/write (paths + preferences)
├── tests/
│   └── test-demand-resolution.ps1    # 25 checks in an isolated sandbox
├── templates/
│   ├── CONTEXT_template.md           # Demand context scaffold
│   └── CLAUDE.md.template            # CLAUDE.md template for team repos
├── examples/
│   └── CONTEXT_example.md            # Example filled-in context
├── .claude/
│   ├── settings.json                  # Hook configuration (project-level)
│   └── commands/                      # Slash command skills
│       ├── new-demand.md              # /new-demand
│       ├── switch-demand.md           # /switch-demand
│       ├── day-report.md              # /day-report
│       └── standby.md                 # /standby
├── repos.conf.example                 # Repository configuration template
├── setup.ps1                          # Automated setup
└── ONBOARDING.md                      # Detailed setup guide
```

## Demand Structure

Each demand lives in `worklogs/{TICKET}/` and has two files:

**`CONTEXT.md`** — What Claude reads at session start. Contains:
- Current status (phases and completion)
- Description and business context
- Architecture / data flow
- Artifacts by repository with status
- Next steps (updated each session)
- Technical decisions (date-stamped)

**`session_log.md`** — The audit trail. Each day's entry covers:
- Tests performed and results
- Files consulted
- Logic understood
- Files created or modified
- Conclusions

See [`examples/CONTEXT_example.md`](examples/CONTEXT_example.md) for a complete example.

## Slash Commands (Skills)

Once set up, these commands are available in any Claude session opened in this directory.
To make them global (available in all repos), copy `.claude/commands/` to `~/.claude/commands/`.

| Command | Description |
|---------|-------------|
| `/new-demand` | Create a new demand |
| `/switch-demand` | Switch active demand without restarting |
| `/day-report` | Show today's activity summary |
| `/standby` | Clear active demand (no context injection) |

## Parallel Sessions

For more efficient work, you can open different demands simultaneously in separate terminal windows:

```powershell
.\scripts\open-parallel.ps1 -ticket "PROJ-456"
```

Each session independently tracks its active demand. Claude warns if two sessions open
the same demand, preventing accidental concurrent edits to `CONTEXT.md` and `session_log.md`.

The demand is handed to the new window by a reservation bound to that window, not by its position in
`active_demands.txt` and not by a shared queue. `open-parallel.ps1` generates a token, writes the
ticket into a reservation file keyed by it, and exports the token into the environment that Windows
Terminal propagates to the new window and to no other. The first message of that window consumes the
reservation, once.

A queue cannot do this job: it is global, and the hook pops the first item on `UserPromptSubmit`.
The initial prompt does not fire that event, so the pop waits for the human to type, and what pairs
ticket with window becomes the order of typing rather than the order of opening. Since a new window
comes to the front, the first thing typed lands in the last window opened and consumes the first
reservation, so two windows opened back-to-back get swapped, systematically rather than by luck.

## Tests

```powershell
powershell -NoProfile -File tests\test-demand-resolution.ps1
```

53 checks in a throwaway sandbox (`WORKLOG_PATH` and `TEMP` are redirected, so your real state is
never touched): the demand resolution chain, the guard against reopening a demand that is already
live, `Stop` refusing to log without a demand file, attribution by evidence, self-healing of a
corrupted `active_demands.txt`, pruning of orphan entries, and the window-bound reservation. Run it
after changing any hook or script.

## Configuration

### repos.conf

After running `setup.ps1`, edit `repos.conf` to list the repositories you want monitored:

```
# repos.conf
backend=C:\Users\yourname\Projects\my-backend
frontend=C:\Users\yourname\Projects\my-frontend
```

These repos appear in session logs and the day report — that's their only job. They're read
via absolute path (`git diff`/`git log` against `$repoPath`), not opened as Claude sessions.

## Optional: multi-repo direct mode

By default, `claude-worklog` only configures project-level hooks (already shipped in
`.claude/settings.json`), which fire when you open `claude` inside this directory. Claude then
reads/edits your other repos via absolute paths from `repos.conf`, using its normal tools.

If you'd rather open `claude` directly inside each of your repos instead (no need to stay in
the hub), run:

```powershell
.\setup.ps1 -Global
```

This additionally registers the hooks in `~/.claude/settings.json`, so context injection
fires no matter which repo you open Claude in. **Trade-off:** that's a global setting — it
applies to every Claude Code project on the machine, not just this one, and can interact with
hooks or settings other projects already have configured at the user level. Keep it project-level
unless you specifically need to open Claude inside each repo.

If you do use `-Global`, copy `templates/CLAUDE.md.template` to each of your team's
repositories as `CLAUDE.md` and fill in the project overview — it tells Claude how to read the
demand context manually if the hook doesn't fire, since it's no longer guaranteed to be running
from inside the hub.

## Token Efficiency

`claude-worklog` ships with two token efficiency layers out of the box:

| Tool | What it does | Savings | Setup |
|------|-------------|---------|-------|
| [claude-token-efficient](https://github.com/drona23/claude-token-efficient) | Rules in `CLAUDE.md` that keep Claude's responses concise and direct | ~63% | Zero — rules are in `CLAUDE.md` |
| [RTK](https://github.com/rtk-ai/rtk) | Compresses terminal output (git, npm…) before it reaches Claude | 76–98% per command | Optional — see ONBOARDING.md Step 0 |

The `CLAUDE.md` rules apply automatically. RTK is optional but recommended for heavy git workflows.

## Platform Support

| Platform | Status |
|----------|--------|
| Windows (PowerShell 5.1+) | Fully supported |
| Linux / macOS (Bash) | Planned — see `hooks/bash/README.md` |

## License

MIT
