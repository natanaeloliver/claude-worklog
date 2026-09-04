# CLAUDE.md — claude-worklog

This is the worklog hub. It is not a production codebase — it contains demand tracking,
session logs, hooks, and management scripts.

## Active Demand Context

The `UserPromptSubmit` hook injects the active demand's context automatically on the first
message of each session. If the hook did not inject (stand-by or failure), read manually:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
$t  = (Get-Content "$wl\active_demands.txt" -EA Stop | Select-Object -First 1).Trim()
Get-Content "$wl\worklogs\$t\CONTEXT.md"
```

**State files** — both gitignored, per-user, one meaning each:

| File | Answers |
|---|---|
| `active_demands.txt` | which demands have a live session **right now** (multi-valued, ephemeral) |
| `last_demand.txt` | where to **resume** from (single-valued, survives the end of the day) |

They do not substitute for each other. The old `current_demand.txt` was retired because it carried
both meanings at once and had no writer in the multi-session model. Always read and write
`active_demands.txt` through `scripts/active_demands_lib.ps1` (self-healing read, atomic write).

**Stand-by:** if both files are empty, no context is injected — Claude works normally without demand
context. `standby.ps1` clears both, so stand-by survives the end of the session.

**Creating a demand does NOT activate it.** `new-demand.ps1` writes the folder and `CONTEXT.md` and
nothing else -- no `last_demand.txt`, no `active_demands.txt`, no session file, so it is safe to run
while another session is live. It used to write the resume point, which meant scaffolding a new
ticket stole that point from whoever was working, and the next session without a window reservation
came up on the freshly created demand. To work on a demand, open a window for it
(`open-parallel.ps1`, which guarantees the structure) or switch into it (`switch-demand.ps1`).

**Work attribution:** the audit trail is never inferred from shared state. The `Stop` hook logs only
what it can prove belongs to the session's demand (worktree under `worklogs/<TICKET>/`, or a
monitored repo on branch `<TICKET>`), and it does not create the day's section in `session_log.md` --
that section is yours to write.

**Tab title:** when a window is opened by a script the tab is renamed automatically (`/rename` as
Claude's initial prompt). On a demand switch or on stand-by it cannot be: the session is already
running, and no tool executes a CLI built-in. `switch-demand.ps1` and `standby.ps1` print the exact
`/rename` line instead -- **relay that line to the user**, it is a human step.

## Working in Other Repositories

The hooks in this repo are project-level (`.claude/settings.json`) — they only fire when
Claude is opened here, in the hub. Code work in another repository happens via absolute path
(Read/Edit/Bash), always from this hub session — never by opening `claude` physically inside
that other repository. `repos.conf` maps aliases to absolute paths; use those paths directly.

(If the user has set up `-Global` mode instead, the hooks also run inside their other repos
directly — see README.md for that mode. Default assumption is hub-only unless told otherwise.)

## Token Efficiency

Rules from [claude-token-efficient](https://github.com/drona23/claude-token-efficient) — applied by default in every session:

- **Read before write** — always read the full file before editing; do not re-read unless content changed
- **Targeted edits** — prefer Edit over rewriting entire files
- **No preamble or closing** — no "Sure!", "Great question!", "Let me know if you need anything else!"
- **Concise output** — direct answer; details only when requested
- **No over-engineering** — simplest solution that solves the problem; no unsolicited abstractions
- **No multi-line comment blocks** — one short line max; never write docstrings that explain what the code does
- **User instructions prevail** — if the user asks for detail, provide it without questioning
- **Stop at first error** — report with full traceback; do not silently retry or fix around the issue

**RTK (Rust Token Killer)** — optional but recommended. Compresses terminal output (git, npm, cargo…)
before it reaches Claude — 76–98% reduction per command. See ONBOARDING.md for setup.

---

## Session Conventions

### At the end of each session

1. Update `## Next Steps` in the active demand's `CONTEXT.md`
2. Record technical decisions in `## Technical Decisions`
3. Write the day's entry in `session_log.md`:

```markdown
## YYYY-MM-DD username

What was done this session (1-3 objective lines).

Repos: repo1, repo2
```

> If an entry already exists for today and the current user, **append** to it.

### session_log.md — required detail level

Each entry must cover:
- **Tests performed and results** — what was tested, values returned, success/failure
- **Files consulted** — scripts, models, queries read or analyzed
- **Logic understood** — business rules, data structures, discovered behaviors
- **Files created or modified** — scripts, models, queries, configs
- **Conclusions** — technical decisions made and rationale

### CONTEXT.md vs session_log.md

| Goes in CONTEXT.md | Goes in session_log.md |
|---|---|
| Conclusion of an analysis | Details of tests that led to the conclusion |
| Technical decision and brief rationale | Query results, returned values |
| Next steps | Files consulted during investigation |
| Artifact status by repository | Approaches that didn't work and why |

## Worktree per demand — optional, decided per repository

Before making the **first change** to a registered repository for the current demand, check that
repository's preference:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\repo-worktree.ps1" -Alias "backend"    # -> yes | no | ask
```

| Answer | What to do |
|---|---|
| `yes` | create/use a worktree at `worklogs/<TICKET>/<alias>/`, branch named after the demand |
| `no` | work in the main copy, on a branch named after the demand |
| `ask` | **ask the user once**, then record the answer (below) and follow it |

When the answer is `ask`, put the question to the user in terms of cost, not preference — something
like: *"does `backend` use a worktree per demand, or should I work in the main copy on a demand
branch? A fresh worktree starts empty, so anything git does not track has to be rebuilt there
(dependencies, local `.env`, generated clients, seeded database)."* Then record it:

```powershell
& "$wl\scripts\repo-worktree.ps1" -Alias "backend" -Use no
```

Recording is what stops the question from repeating — never ask twice for the same repository, and
never assume a default when the answer is `ask`. The answer is stored in `repos.conf`, which is
gitignored and per-user, because the cost of a fresh worktree depends on the machine as much as on
the repository.

## Switching Demands

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\switch-demand.ps1" -ticket "TICKET-123" -sessionId "SESSION_ID_FROM_SCRATCHPAD"
```

**Always pass `-sessionId`** with the UUID from your own scratchpad directory (shown in your
system prompt). Without it, the script falls back to a heuristic that can match a DIFFERENT,
unrelated Claude session running on the same machine, silently switching the wrong session's
demand (confirmed via live debugging, 2026-07-01).

## Management Commands

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }

# Create a demand's structure (does NOT activate it, safe with other sessions live)
& "$wl\scripts\new-demand.ps1" -ticket "PROJ-001" -name "Demand name" -sprint "Sprint2026.S11"

# Stand-by (no active demand) -- always pass -sessionId, same reason as switch-demand
& "$wl\scripts\standby.ps1" -sessionId "SESSION_ID_FROM_SCRATCHPAD"

# View all demands
Get-ChildItem "$wl\worklogs\" -Directory | Select-Object Name

# View active demands
Get-Content "$wl\active_demands.txt"
```

## Parallel Sessions

```powershell
& "$wl\scripts\open-parallel.ps1" -ticket "PROJ-456"
& "$wl\scripts\open-parallel.ps1" -ticket "PROJ-789" -name "New ticket with no folder yet"
```

Each session tracks its own active demand independently. Claude warns when two sessions
open the same demand simultaneously. The script guarantees the demand's structure before reserving
it -- the inject hook only accepts a reservation for a demand that has a folder, so a ticket without
one would silently fall through to another session's demand.

## Recovering After a Crash

If several sessions died at once (Windows Terminal crash, machine restart), all but one demand can
vanish from the state files. `logs/sessions_ended.jsonl` is what survives that:

```powershell
& "$wl\scripts\resume-sessions.ps1"                     # list recent endings
& "$wl\scripts\resume-sessions.ps1" -LastCrash -DryRun  # check before acting
& "$wl\scripts\resume-sessions.ps1" -LastCrash
```

It reopens each dead session with `claude --resume <session_id>`, so the conversation comes back
instead of a fresh session on the same demand.
